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

    /// 纯文本行(系统/内核/运行时间)——不适合图形化的信息
    var textRows: [(String, String)] {
        var result: [(String, String)] = []
        func add(_ label: String, _ value: String) {
            if !value.isEmpty { result.append((label, value)) }
        }
        add("系统", os)
        add("内核", kernel)
        add("运行时间", uptime)
        return result
    }

    // MARK: 数值解析(供图形化)

    var cpuCount: Int { Int(cpus.trimmingCharacters(in: .whitespaces)) ?? 0 }

    /// 负载 1/5/15 分钟
    var loadValues: [Double] {
        load.split(separator: " ").compactMap { Double($0) }
    }

    /// 内存 (已用 MB, 总 MB) —— 解析 "2364/7200 MB"
    var memoryUsage: (used: Double, total: Double)? {
        let numbers = memory.split(whereSeparator: { !"0123456789".contains($0) }).compactMap { Double($0) }
        guard numbers.count >= 2, numbers[1] > 0 else { return nil }
        return (numbers[0], numbers[1])
    }

    /// 磁盘占用百分比 —— 解析 "(33%)"
    var diskPercent: Double? {
        guard let range = disk.range(of: #"(\d+)%"#, options: .regularExpression) else { return nil }
        return Double(disk[range].dropLast()).map { $0 / 100 }
    }

    /// 磁盘 "已用/总量"(去掉百分比部分)
    var diskUsage: String {
        disk.replacingOccurrences(of: #"\s*\(\d+%\)"#, with: "", options: .regularExpression)
    }
}
