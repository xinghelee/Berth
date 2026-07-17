import SwiftTerm
import SwiftUI
import UIKit

/// 终端页:SwiftTerm 视图(主题化)+ 连接状态覆盖层 + 主机密钥确认 + 片段/信息入口。
struct TerminalScreen: View {
    let spec: HostSpec
    let transientPassword: String?

    @State private var session: IOSTerminalSession?
    @State private var theme = ThemeStore.shared
    @State private var showSnippets = false
    @State private var showServerInfo = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            theme.current.chromeBackground.ignoresSafeArea()
            if let session {
                TerminalHostingView(session: session)
                    .ignoresSafeArea(.container, edges: .bottom)
                overlay(for: session)
            }
        }
        .navigationTitle(spec.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(theme.current.elevatedBackground, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if spec.isProduction {
                    Text(String(localized: "生产环境"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.2), in: Capsule())
                        .foregroundStyle(.red)
                }
                Button { showSnippets = true } label: { Image(systemName: "curlybraces") }
                Button { showServerInfo = true } label: { Image(systemName: "info.circle") }
            }
        }
        .sheet(isPresented: $showSnippets) {
            SnippetsViewIOS { command in
                session?.sendText(command + "\n")
            }
        }
        .sheet(isPresented: $showServerInfo) {
            if let session {
                ServerInfoSheetIOS(session: session)
            }
        }
        .task {
            if session == nil {
                let created = IOSTerminalSession(spec: spec)
                created.transientPassword = transientPassword
                session = created
            }
        }
        .onDisappear {
            session?.close()
        }
    }

    @ViewBuilder
    private func overlay(for session: IOSTerminalSession) -> some View {
        switch session.state {
        case .connecting(let detail):
            VStack(spacing: 10) {
                ProgressView()
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(theme.current.secondaryText)
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.largeTitle)
                    .foregroundStyle(theme.current.secondaryText)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.current.secondaryText)
                Button(String(localized: "关闭")) { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

        case .idle, .connected, .closed:
            EmptyView()
        }
        if let prompt = session.hostKeyPrompt {
            hostKeySheet(prompt, session: session)
        }
    }

    private func hostKeySheet(_ prompt: HostKeyPrompt, session: IOSTerminalSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.isKeyChange ? String(localized: "主机密钥已变更!") : String(localized: "首次连接此主机"))
                .font(.headline)
                .foregroundStyle(prompt.isKeyChange ? .red : .primary)
            Text("\(prompt.hostname):\(String(prompt.port)) · \(prompt.keyType)")
                .font(.caption)
                .monospaced()
            Text(prompt.fingerprint)
                .font(.caption2)
                .monospaced()
                .foregroundStyle(theme.current.secondaryText)
                .textSelection(.enabled)
            if prompt.isKeyChange {
                Text(String(localized: "原记录指纹"))
                    .font(.caption2)
                    .foregroundStyle(.red)
                ForEach(prompt.knownFingerprints, id: \.self) { fingerprint in
                    Text(fingerprint)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(theme.current.secondaryText)
                }
            }
            HStack {
                Button(String(localized: "取消连接"), role: .cancel) {
                    session.resolveHostKey(trusted: false)
                }
                Spacer()
                Button(prompt.isKeyChange ? String(localized: "我已核实,更新并连接") : String(localized: "信任并连接")) {
                    session.resolveHostKey(trusted: true)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
}

/// 服务器信息面板(⌘I 的 iOS 对应)
struct ServerInfoSheetIOS: View {
    let session: IOSTerminalSession

    @Environment(\.dismiss) private var dismiss
    @State private var theme = ThemeStore.shared
    @State private var info: ServerInfo?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "连接")) {
                    LabeledContent(String(localized: "主机"), value: session.spec.hostname)
                    LabeledContent(String(localized: "端口"), value: String(session.spec.port))
                    LabeledContent(String(localized: "用户"), value: session.spec.username)
                    if let connectedAt = session.connectedAt {
                        LabeledContent(String(localized: "已连接"), value: connectedAt.formatted(date: .omitted, time: .standard))
                    }
                }
                .listRowBackground(theme.current.panelBackground)

                if !session.forwardStates.isEmpty {
                    Section(String(localized: "端口转发")) {
                        ForEach(session.spec.forwards, id: \.id) { forward in
                            LabeledContent(forward.summary, value: forwardStateLabel(forward.id))
                                .font(.caption)
                                .monospaced()
                        }
                    }
                    .listRowBackground(theme.current.panelBackground)
                }

                Section(String(localized: "服务器")) {
                    if let info {
                        ForEach(info.textRows, id: \.0) { row in
                            LabeledContent(row.0, value: row.1)
                        }
                        if !info.load.isEmpty { LabeledContent(String(localized: "负载"), value: info.load) }
                        if !info.memory.isEmpty { LabeledContent(String(localized: "内存"), value: info.memory) }
                        if !info.disk.isEmpty { LabeledContent(String(localized: "磁盘 /"), value: info.disk) }
                    } else if loaded {
                        Text(String(localized: "无法读取服务器信息"))
                            .foregroundStyle(theme.current.secondaryText)
                    } else {
                        HStack {
                            ProgressView()
                            Text(String(localized: "读取中…"))
                                .foregroundStyle(theme.current.secondaryText)
                        }
                    }
                }
                .listRowBackground(theme.current.panelBackground)
            }
            .scrollContentBackground(.hidden)
            .background(theme.current.sidebarBackground)
            .navigationTitle(String(localized: "信息"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
            .task {
                info = await session.fetchServerInfo()
                loaded = true
            }
        }
        .tint(theme.current.accentColor)
        .preferredColorScheme(theme.current.isDark ? .dark : .light)
    }

    private func forwardStateLabel(_ id: UUID) -> String {
        switch session.forwardStates[id] {
        case .active(let port): return String(localized: "运行中 · 端口 \(String(port))")
        case .starting: return String(localized: "启动中…")
        case .failed(let reason): return String(localized: "失败:\(reason)")
        case .none: return String(localized: "未启动")
        }
    }
}

/// SwiftTerm 的 UIKit TerminalView 封装:主题配色、输出 feed、按键回传、尺寸同步。
private struct TerminalHostingView: UIViewRepresentable {
    let session: IOSTerminalSession

    func makeUIView(context: Context) -> SwiftTerm.TerminalView {
        let view = SwiftTerm.TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        ThemeStore.shared.apply(to: view)
        view.backgroundColor = ThemeStore.shared.current.backgroundNSColor

        session.onOutput = { [weak view] bytes in
            view?.feed(byteArray: bytes[...])
        }
        let term = view.getTerminal()
        session.start(cols: term.cols, rows: term.rows)
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: SwiftTerm.TerminalView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let session: IOSTerminalSession

        init(session: IOSTerminalSession) {
            self.session = session
        }

        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
            Task { @MainActor in self.session.send(data) }
        }

        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            Task { @MainActor in self.session.resize(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
        }
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                UIPasteboard.general.string = text
            }
        }
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? {
            UIPasteboard.general.string.flatMap { $0.data(using: .utf8) }
        }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}
