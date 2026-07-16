import Foundation

/// 解析用户粘贴的连接目标,支持:
///   user@host / user@host:port / host / host:port / [ipv6]:port
///   ssh user@host -p 2222 -i ~/.ssh/key / ssh -l user host
struct ParsedSSHTarget: Equatable {
    var username: String?
    var hostname: String
    var port: Int?
    var identityFile: String?
}

enum SSHCommandParser {

    static func parse(_ input: String) -> ParsedSSHTarget? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ssh ") || trimmed == "ssh" {
            return parseCommand(trimmed)
        }
        return parseTarget(trimmed)
    }

    /// 形如 user@host:port 的裸目标
    private static func parseTarget(_ text: String) -> ParsedSSHTarget? {
        guard !text.contains(" ") else { return nil }

        var username: String?
        var rest = text
        // 用户名取最后一个 @ 之前(用户名中不允许 @,host 不会含 @)
        if let atIndex = rest.lastIndex(of: "@") {
            let name = String(rest[..<atIndex])
            guard !name.isEmpty else { return nil }
            username = name
            rest = String(rest[rest.index(after: atIndex)...])
        }
        guard !rest.isEmpty else { return nil }

        var hostname = rest
        var port: Int?

        if rest.hasPrefix("[") {
            // [ipv6]:port
            guard let closeIndex = rest.firstIndex(of: "]") else { return nil }
            hostname = String(rest[rest.index(after: rest.startIndex)..<closeIndex])
            let remainder = rest[rest.index(after: closeIndex)...]
            if remainder.hasPrefix(":") {
                guard let value = Int(remainder.dropFirst()), (1...65535).contains(value) else { return nil }
                port = value
            } else if !remainder.isEmpty {
                return nil
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colonIndex = rest.firstIndex(of: ":") {
            // host:port(多个冒号视为裸 IPv6,不拆端口)
            let candidate = rest[rest.index(after: colonIndex)...]
            guard let value = Int(candidate), (1...65535).contains(value) else { return nil }
            hostname = String(rest[..<colonIndex])
            port = value
        }

        guard !hostname.isEmpty else { return nil }
        return ParsedSSHTarget(username: username, hostname: hostname, port: port)
    }

    /// 完整 ssh 命令
    private static func parseCommand(_ text: String) -> ParsedSSHTarget? {
        var tokens = tokenize(text)
        guard !tokens.isEmpty, tokens.removeFirst() == "ssh" else { return nil }

        var username: String?
        var port: Int?
        var identityFile: String?
        var destination: String?

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-p", "-l", "-i":
                guard index + 1 < tokens.count else { return nil }
                let value = tokens[index + 1]
                switch token {
                case "-p":
                    guard let number = Int(value), (1...65535).contains(number) else { return nil }
                    port = number
                case "-l": username = value
                case "-i": identityFile = value
                default: break
                }
                index += 2
            case let flag where flag.hasPrefix("-"):
                // 其余选项:带参数的跳两个,布尔开关跳一个(常见集合)
                let optionsWithArgument: Set<String> = [
                    "-o", "-F", "-J", "-L", "-R", "-D", "-W", "-b", "-c", "-e", "-m", "-B", "-E", "-I", "-Q", "-S",
                ]
                index += optionsWithArgument.contains(flag) ? 2 : 1
            default:
                if destination == nil {
                    destination = token
                    index += 1
                } else {
                    // 目标之后的都是远端命令,忽略
                    index = tokens.count
                }
            }
        }

        guard let destination else { return nil }
        // ssh 也接受 ssh://user@host:port/ 形式
        var target = destination
        if target.hasPrefix("ssh://") {
            target = String(target.dropFirst("ssh://".count))
            if let slash = target.firstIndex(of: "/") {
                target = String(target[..<slash])
            }
        }
        guard var parsed = parseTarget(target) else { return nil }
        if parsed.username == nil { parsed.username = username }
        if parsed.port == nil { parsed.port = port }
        parsed.identityFile = identityFile
        return parsed
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
