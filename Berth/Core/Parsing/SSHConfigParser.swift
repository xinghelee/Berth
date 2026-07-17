import Foundation

/// ~/.ssh/config 中一个可导入的主机(具体别名,非通配模式)
struct SSHConfigHost: Equatable, Identifiable {
    var alias: String
    var hostname: String
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    /// PubkeyAuthentication no 或 PreferredAuthentications 不含 publickey 时为 true
    var prefersPasswordAuth: Bool = false

    var id: String { alias }
}

/// ssh_config 解析器。支持 Host 多别名与通配(*、?、! 取反)、
/// HostName / User / Port / IdentityFile(~ 展开)/ ProxyJump,
/// 参数语义与 ssh 一致:每个参数取「第一次出现」的值。
/// Match 块与 Include 指令暂不支持(跳过)。
enum SSHConfigParser {

    struct Block {
        var patterns: [String]
        var options: [(key: String, value: String)] = []
    }

    static func parse(_ text: String, homeDirectory: String = NSHomeDirectory()) -> [SSHConfigHost] {
        let blocks = parseBlocks(text)

        // 具体别名 = 不含通配符、非取反的 pattern
        var aliases: [String] = []
        var seen = Set<String>()
        for block in blocks {
            for pattern in block.patterns
            where !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!") {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            var host = SSHConfigHost(alias: alias, hostname: alias)
            var assigned = Set<String>()

            for block in blocks where matches(alias: alias, patterns: block.patterns) {
                for (key, value) in block.options where !assigned.contains(key) {
                    assigned.insert(key)
                    switch key {
                    case "hostname":
                        host.hostname = value
                    case "user":
                        host.user = value
                    case "port":
                        host.port = Int(value)
                    case "identityfile":
                        host.identityFile = expandTilde(value, home: homeDirectory)
                    case "proxyjump":
                        host.proxyJump = value
                    case "pubkeyauthentication":
                        if value.lowercased() == "no" { host.prefersPasswordAuth = true }
                    case "preferredauthentications":
                        if !value.lowercased().contains("publickey") { host.prefersPasswordAuth = true }
                    default:
                        break
                    }
                }
            }
            return host
        }
    }

    static func parseFile(at path: String) -> [SSHConfigHost] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text)
    }

    // MARK: - 内部

    private static func parseBlocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var current: Block?
        var inUnsupportedMatchBlock = false

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 行内注释:ssh_config 不支持行内 #,保守起见不剥离(路径可能含 #)

            let (key, value) = splitKeyValue(line)
            guard !key.isEmpty else { continue }

            switch key {
            case "host":
                if let block = current { blocks.append(block) }
                current = Block(patterns: splitPatterns(value))
                inUnsupportedMatchBlock = false
            case "match":
                if let block = current { blocks.append(block) }
                current = nil
                inUnsupportedMatchBlock = true
            default:
                guard !inUnsupportedMatchBlock else { continue }
                if current == nil {
                    // 文件顶部、任何 Host 块之前的全局参数,等价于 Host *
                    current = Block(patterns: ["*"])
                }
                current?.options.append((key, value))
            }
        }
        if let block = current { blocks.append(block) }
        return blocks
    }

    /// `Key Value` 或 `Key=Value`,key 大小写不敏感,value 保留原样(去外层引号)
    private static func splitKeyValue(_ line: String) -> (String, String) {
        let separators = CharacterSet(charactersIn: " \t=")
        guard let range = line.rangeOfCharacter(from: separators) else {
            return (line.lowercased(), "")
        }
        let key = String(line[..<range.lowerBound]).lowercased()
        var value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        if line[range.lowerBound] != "=" , value.hasPrefix("=") {
            value = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, value)
    }

    private static func splitPatterns(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { pattern in
                var text = String(pattern)
                if text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
                    text = String(text.dropFirst().dropLast())
                }
                return text
            }
            .filter { !$0.isEmpty }
    }

    /// ssh 语义:取反 pattern 命中即整块不适用;否则任一正向 pattern 命中即适用
    static func matches(alias: String, patterns: [String]) -> Bool {
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if wildcardMatch(alias, pattern: String(pattern.dropFirst())) {
                    return false
                }
            } else if wildcardMatch(alias, pattern: pattern) {
                matched = true
            }
        }
        return matched
    }

    /// * 匹配任意串,? 匹配单个字符
    static func wildcardMatch(_ text: String, pattern: String) -> Bool {
        let textChars = Array(text)
        let patternChars = Array(pattern)

        var dp = Array(
            repeating: Array(repeating: false, count: patternChars.count + 1),
            count: textChars.count + 1
        )
        dp[0][0] = true
        for p in 1...max(patternChars.count, 1) where patternChars.count >= p {
            if patternChars[p - 1] == "*" { dp[0][p] = dp[0][p - 1] }
        }
        guard !patternChars.isEmpty else { return textChars.isEmpty }

        for t in 1...max(textChars.count, 1) where textChars.count >= t {
            for p in 1...patternChars.count {
                let pc = patternChars[p - 1]
                if pc == "*" {
                    dp[t][p] = dp[t - 1][p] || dp[t][p - 1]
                } else if pc == "?" || pc == textChars[t - 1] {
                    dp[t][p] = dp[t - 1][p - 1]
                }
            }
        }
        return dp[textChars.count][patternChars.count]
    }

    private static func expandTilde(_ path: String, home: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }
}
