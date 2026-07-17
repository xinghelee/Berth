import Foundation
import Network
import Observation

/// 主机可达性探测:对直连主机做轻量 TCP 连接测活,结果供侧栏显示"在线/离线"。
/// 默认关闭(SettingsKeys.probeReachability),开启后仅探测无跳板/无代理的主机,
/// 短超时、慢轮询,避免噪声或触发服务器频率限制。
@MainActor
@Observable
final class HostReachability {
    static let shared = HostReachability()

    enum Status: Equatable { case unknown, reachable, unreachable }

    private(set) var statuses: [UUID: Status] = [:]

    private var hosts: [(id: UUID, host: String, port: Int)] = []
    private var timer: Task<Void, Never>?
    private let queue = DispatchQueue(label: "berth.reachability", qos: .utility)

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: SettingsKeys.probeReachability) as? Bool ?? false
    }

    /// 更新待探测主机集合(仅直连,跳板/代理主机无法本地探测,跳过)
    func updateTargets(_ targets: [(id: UUID, host: String, port: Int, direct: Bool)]) {
        hosts = targets.filter(\.direct).map { ($0.id, $0.host, $0.port) }
        // 清理已删除主机的旧状态
        let ids = Set(hosts.map(\.id))
        statuses = statuses.filter { ids.contains($0.key) }
        restart()
    }

    func restart() {
        timer?.cancel()
        guard enabled, !hosts.isEmpty else {
            timer = nil
            statuses = [:]
            return
        }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeAll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// 设置变更后调用
    func settingsChanged() { restart() }

    private func probeAll() async {
        let targets = hosts
        await withTaskGroup(of: (UUID, Status).self) { group in
            for target in targets {
                group.addTask { [queue] in
                    let ok = await Self.probe(host: target.host, port: target.port, on: queue)
                    return (target.id, ok ? .reachable : .unreachable)
                }
            }
            for await (id, status) in group {
                statuses[id] = status
            }
        }
    }

    /// 单次 TCP 连接探测,3 秒超时
    private static func probe(host: String, port: Int, on queue: DispatchQueue) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)

        return await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Bool) -> Void = { result in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 3) { finish(false) }
            connection.start(queue: queue)
        }
    }
}
