import Foundation
import SwiftData

/// 演示模式:开启后所有主机列表 UI(侧栏 / ⌘K / 命令面板 / 菜单栏)
/// 隐藏用户真实主机,改显内置示例主机。录屏、直播、截图时避免泄漏
/// 服务器信息;纯展示层过滤,不改动数据库,关掉即恢复。
enum DemoMode {
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: SettingsKeys.demoMode)
    }

    /// 内置示例主机(不入库、不可真连,仅供展示)
    @MainActor
    static let samples: [Host] = {
        let entries: [(String, String, String, TagColor, Bool, String)] = [
            ("atlas-prod", "atlas.example.com", "deploy", .red, true, "Ubuntu 24.04"),
            ("atlas-staging", "staging.example.com", "deploy", .orange, false, "Ubuntu 24.04"),
            ("edge-gateway", "edge.example.com", "ops", .blue, false, "Debian 12"),
            ("pve-lab", "pve.lab.internal", "root", .green, false, "Proxmox VE"),
            ("build-runner", "runner.lab.internal", "ci", .purple, false, "Alpine Linux"),
        ]
        return entries.enumerated().map { index, entry in
            let host = Host(label: entry.0, hostname: entry.1, port: 22, username: entry.2,
                            tagColor: entry.3, sortOrder: index, isProduction: entry.4)
            host.osName = entry.5
            return host
        }
    }()
}
