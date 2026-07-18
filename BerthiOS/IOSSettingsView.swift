import SwiftUI

/// iOS 设置:主题(与 Mac 版共用 20 套)+ 关于。
struct IOSSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeStore.shared

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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
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
