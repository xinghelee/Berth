import Foundation
import Observation

/// 接口不提供模型列表(404/405):不是故障,只是提示用户手填模型名
struct AIModelListUnsupported: LocalizedError {
    let errorDescription: String?
}

/// 从接入点拉取可用模型列表(GET /models),按「格式 + 接入点」缓存并持久化到 UserDefaults,重启后仍可用。
/// Anthropic 与 OpenAI 兼容两种格式的响应信封一致:{"data": [{"id": "..."}]}。
@MainActor
@Observable
final class AIModelCatalog {
    static let shared = AIModelCatalog()

    private static let storageKey = "ai.modelCatalog"

    /// 已拉到的模型列表,键为 `storageID(key)`
    private(set) var cache: [String: [String]]
    /// 正在拉取
    private(set) var isLoading = false
    /// 最近一次拉取的失败或提示说明(UI 展示);成功后清空
    private(set) var errorMessage: String?
    /// errorMessage 只是提示(接口不支持列表),不是错误
    private(set) var errorIsNotice = false

    struct ConfigKey: Hashable {
        var baseURL: String
        var format: AISettings.APIFormat
    }

    private init() {
        cache = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    }

    /// 当前配置对应的缓存键(地址去掉首尾空白和末尾斜杠)
    static func key(baseURL: String, format: AISettings.APIFormat) -> ConfigKey {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ConfigKey(baseURL: trimmed, format: format)
    }

    private static func storageID(_ key: ConfigKey) -> String {
        key.format.rawValue + "|" + key.baseURL
    }

    /// 该接入点已拉到的模型(无缓存时为空)
    func models(for key: ConfigKey) -> [String] {
        cache[Self.storageID(key)] ?? []
    }

    func hasCache(for key: ConfigKey) -> Bool {
        !models(for: key).isEmpty
    }

    /// 本地直接给出的提示(如未配置 Key),不经过网络
    func setError(_ message: String) {
        errorMessage = message
        errorIsNotice = false
    }

    /// 拉取模型列表。带缓存时直接返回缓存,force=true 才重新打接口。
    func load(baseURL: String, format: AISettings.APIFormat, apiKey: String, force: Bool = false) async {
        let key = Self.key(baseURL: baseURL, format: format)
        if !force, hasCache(for: key) { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        errorIsNotice = false
        defer { isLoading = false }
        do {
            let fetched = try await Self.fetchModels(baseURL: baseURL, format: format, apiKey: apiKey)
            guard !fetched.isEmpty else {
                throw AIChatError(message: String(localized: "接口没有返回任何模型"))
            }
            cache[Self.storageID(key)] = fetched
            UserDefaults.standard.set(cache, forKey: Self.storageKey)
        } catch let unsupported as AIModelListUnsupported {
            errorMessage = unsupported.errorDescription
            errorIsNotice = true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "获取模型列表失败")
        }
    }

    /// GET /models,返回去重排序后的模型 id。
    /// 路径拼接沿用 AIClientConfig.endpoint 的版本号规则(裸域名补 /v1)。
    static func fetchModels(
        baseURL: String,
        format: AISettings.APIFormat,
        apiKey: String
    ) async throws -> [String] {
        let config = AIClientConfig(apiKey: apiKey, baseURL: URL(string: baseURL) ?? AISettings.baseURL, model: "")
        var request = URLRequest(url: config.endpoint(path: "/models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch format {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIChatError(message: String(localized: "无效的服务器响应"))
        }
        switch http.statusCode {
        case 200:
            break
        case 404, 405:
            throw AIModelListUnsupported(
                errorDescription: String(localized: "该接口不提供模型列表,请手动输入模型名(地址有误也会返回这个结果,请检查 API 地址)。")
            )
        default:
            throw AIChatError(message: Self.errorMessage(status: http.statusCode, body: data))
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = (object?["data"] as? [[String: Any]])
            ?? (object?["models"] as? [[String: Any]])  // 个别网关不用 data 信封
        guard let entries else {
            throw AIChatError(message: String(localized: "响应格式无法解析,请在设置里手填模型"))
        }
        let ids = entries.compactMap { entry -> String? in
            if let id = entry["id"] as? String, !id.isEmpty { return id }
            if let name = entry["name"] as? String, !name.isEmpty { return name }
            return nil
        }
        var seen = Set<String>()
        let unique = ids.filter { seen.insert($0).inserted }
        // Anthropic /models 会返回全部供应商模型,claude 系排前面更好找
        return unique.sorted { Self.priorityDistance($0) < Self.priorityDistance($1) }
    }

    private static func priorityDistance(_ id: String) -> Int {
        id.lowercased().contains("claude") ? 0 : 1
    }

    private static func errorMessage(status: Int, body: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        switch status {
        case 401: return String(localized: "API Key 无效或已失效,请在设置中检查。")
        case 429: return String(localized: "请求过于频繁,请稍后重试。")
        default: return String(localized: "获取模型列表失败(HTTP \(String(status)))")
        }
    }
}
