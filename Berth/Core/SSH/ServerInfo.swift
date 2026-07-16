import Foundation

/// 服务器信息快照(通过 SSH 跑命令取回,inspector 展示)。
struct ServerInfo: Equatable {
    var hostname = ""
    var kernel = ""
    var os = ""
    var uptime = ""
    var load = ""
    var cpus = ""
    var memory = ""
    var disk = ""

    init() {}

    /// 解析 key=value 行
    init(parsing text: String) {
        for line in text.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "HOSTNAME": hostname = value
            case "KERNEL": kernel = value
            case "OS": os = value
            case "UPTIME": uptime = value
            case "LOAD": load = value
            case "CPUS": cpus = value
            case "MEM": memory = value
            case "DISK": disk = value
            default: break
            }
        }
    }

    /// 展示用键值对(过滤空值)
    var rows: [(String, String)] {
        var result: [(String, String)] = []
        func add(_ label: String, _ value: String) {
            if !value.isEmpty { result.append((label, value)) }
        }
        add("系统", os)
        add("内核", kernel)
        add("运行时间", uptime)
        add("负载", load)
        add("CPU", cpus.isEmpty ? "" : "\(cpus) 核")
        add("内存", memory)
        add("磁盘 /", disk)
        return result
    }
}
