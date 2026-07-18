import CloudKit
import SwiftUI

/// iOS 设置:主题(与 Mac 版共用 20 套)+ iCloud 同步 + 关于。
struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var theme = ThemeStore.shared
    @State private var syncAccountStatus: CKAccountStatus?
    @State private var syncMonitor = CloudSyncMonitor.shared
    @State private var syncNote: String?
    @AppStorage(SettingsKeys.probeReachability) private var probeReachability = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "外观")) {
                    NavigationLink {
                        IOSThemePickerView()
                    } label: {
                        HStack {
                            Text(String(localized: "终端配色"))
                            Spacer()
                            Text(theme.current.name)
                                .foregroundStyle(theme.current.secondaryText)
                        }
                    }
                    .listRowBackground(theme.current.panelBackground)
                }
                Section(String(localized: "主机列表")) {
                    Toggle(String(localized: "探测主机是否在线(列表状态条着色)"), isOn: $probeReachability)
                        .onChange(of: probeReachability) { _, _ in HostReachability.shared.settingsChanged() }
                    Text(String(localized: "每 30 秒对直连主机做一次 TCP 测活;跳板机/代理主机不探测。"))
                        .font(.caption)
                        .foregroundStyle(theme.current.secondaryText)
                }
                .listRowBackground(theme.current.panelBackground)
                Section(String(localized: "iCloud 同步")) {
                    HStack {
                        Text(String(localized: "状态"))
                        Spacer()
                        if syncMonitor.phase == .syncing {
                            ProgressView().controlSize(.small)
                            Text(String(localized: "同步中…")).foregroundStyle(theme.current.secondaryText)
                        } else {
                            Text(syncStatusLabel).foregroundStyle(theme.current.secondaryText)
                        }
                    }
                    HStack {
                        Text(String(localized: "上次同步"))
                        Spacer()
                        Text(lastSyncLabel).foregroundStyle(theme.current.secondaryText)
                    }
                    HStack {
                        Button(String(localized: "立即同步")) { syncNow() }
                        Spacer()
                        if let syncNote {
                            Text(syncNote).font(.caption).foregroundStyle(theme.current.secondaryText)
                        }
                    }
                    Text(String(localized: "主机、分组、端口转发、片段、模板与触发器经 iCloud 私有库自动同步;密码与私钥只在本机钥匙串,永不上传。「立即同步」推送本地改动;云端改动由系统自动拉取。"))
                        .font(.caption)
                        .foregroundStyle(theme.current.secondaryText)
                }
                .listRowBackground(theme.current.panelBackground)
                Section(String(localized: "关于")) {
                    if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        LabeledContent(String(localized: "版本"), value: version)
                    }
                    Text(String(localized: "私钥只保存在 macOS Keychain 中,不写入磁盘文件。"))
                        .font(.caption)
                        .foregroundStyle(theme.current.secondaryText)
                }
                .listRowBackground(theme.current.panelBackground)
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "设置"))
            .navigationBarTitleDisplayMode(.inline)
            .task { await refreshSyncStatus() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private var syncStatusLabel: String {
        switch syncAccountStatus {
        case .available: return String(localized: "已启用,随 iCloud 自动同步")
        case .noAccount: return String(localized: "未登录 iCloud 账号")
        case .restricted: return String(localized: "iCloud 账号受限")
        case .temporarilyUnavailable: return String(localized: "iCloud 暂不可用,稍后自动重试")
        case .couldNotDetermine, .none: return String(localized: "检查中…")
        @unknown default: return String(localized: "检查中…")
        }
    }

    private var lastSyncLabel: String {
        guard let date = syncMonitor.lastSyncDate else { return String(localized: "尚无记录") }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func refreshSyncStatus() async {
        let container = CKContainer(identifier: "iCloud.com.berthssh.app")
        syncAccountStatus = (try? await container.accountStatus()) ?? .couldNotDetermine
    }

    private func syncNow() {
        let hadChanges = modelContext.hasChanges
        try? modelContext.save()
        Task { await refreshSyncStatus() }
        syncNote = hadChanges ? String(localized: "已推送本地改动") : String(localized: "本地无待同步改动")
        Task {
            try? await Task.sleep(for: .seconds(3))
            syncNote = nil
        }
    }
}

/// 主题选择二级页:20 套内置主题列表
struct IOSThemePickerView: View {
    @State private var theme = ThemeStore.shared

    var body: some View {
        Form {
            ForEach(TerminalTheme.builtIn) { candidate in
                Button {
                    theme.select(id: candidate.id)
                } label: {
                    HStack(spacing: 10) {
                        swatch(candidate)
                        Text(candidate.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if candidate.id == theme.current.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(theme.current.accentColor)
                        }
                    }
                }
                .listRowBackground(theme.current.panelBackground)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.current.sidebarBackground)
        .navigationTitle(String(localized: "终端配色"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(_ candidate: TerminalTheme) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 3)
                .fill(candidate.chromeBackground)
                .frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.gray.opacity(0.3), lineWidth: 0.5))
            RoundedRectangle(cornerRadius: 3)
                .fill(candidate.accentColor)
                .frame(width: 8, height: 18)
        }
    }
}
