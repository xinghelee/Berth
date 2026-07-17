import SwiftData
import SwiftUI

/// 触发器管理(独立窗口):列出规则,增删改 + 启用开关。正则匹配终端输出即发通知。
struct TriggersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trigger.sortOrder) private var triggers: [Trigger]
    @State private var theme = ThemeStore.shared
    @State private var editing: Trigger?
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("输出触发器")
                    .font(.headline)
                Spacer()
                Button {
                    isCreating = true
                } label: {
                    Label("新建触发器", systemImage: "plus")
                }
            }
            .padding(12)

            Divider()

            if triggers.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(triggers) { trigger in
                        row(trigger)
                            .listRowBackground(theme.current.panelBackground)
                    }
                    .onDelete(perform: delete)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.current.panelBackground)
        .tint(theme.current.accentColor)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 320, idealHeight: 420)
        .sheet(isPresented: $isCreating) { TriggerEditor(trigger: nil) }
        .sheet(item: $editing) { trigger in TriggerEditor(trigger: trigger) }
    }

    private func row(_ trigger: Trigger) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { trigger.isEnabled },
                set: { trigger.isEnabled = $0; try? modelContext.save(); TriggerEngine.shared.reload() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            VStack(alignment: .leading, spacing: 2) {
                Text(trigger.name)
                    .fontWeight(.medium)
                    .foregroundStyle(trigger.isEnabled ? .primary : .secondary)
                Text(trigger.pattern)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if trigger.playSound {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Button("编辑…") { editing = trigger }
                .controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("还没有触发器")
                .foregroundStyle(.secondary)
            Text("匹配终端输出的正则,命中即发系统通知(如日志出现 ERROR)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(triggers[index]) }
        try? modelContext.save()
        TriggerEngine.shared.reload()
    }
}

/// 触发器编辑
struct TriggerEditor: View {
    let trigger: Trigger?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trigger.sortOrder) private var allTriggers: [Trigger]
    @State private var theme = ThemeStore.shared

    @State private var name = ""
    @State private var pattern = ""
    @State private var playSound = true
    @State private var patternError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("规则") {
                    TextField("名称", text: $name)
                    TextField("正则(如:ERROR|错误|panic)", text: $pattern)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .onChange(of: pattern) { _, _ in validate() }
                    if let patternError {
                        Text(patternError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Toggle("命中时响铃", isOn: $playSound)
                }
                Section {
                    Text("对所有会话的终端输出逐行(忽略大小写)匹配;命中即发系统通知,同一触发器 3 秒内不重复。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(trigger == nil ? "创建" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(pattern.trimmingCharacters(in: .whitespaces).isEmpty || patternError != nil)
            }
            .padding(12)
        }
        .background(theme.current.panelBackground)
        .tint(theme.current.accentColor)
        .frame(width: 440, height: 320)
        .onAppear {
            if let trigger {
                name = trigger.name
                pattern = trigger.pattern
                playSound = trigger.playSound
            }
        }
    }

    private func validate() {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { patternError = nil; return }
        if (try? NSRegularExpression(pattern: trimmed)) == nil {
            patternError = String(localized: "正则表达式无效")
        } else {
            patternError = nil
        }
    }

    private func save() {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespaces)
        let displayName = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedPattern : name
        if let trigger {
            trigger.name = displayName
            trigger.pattern = trimmedPattern
            trigger.playSound = playSound
        } else {
            let created = Trigger(
                name: displayName,
                pattern: trimmedPattern,
                playSound: playSound,
                sortOrder: (allTriggers.map(\.sortOrder).max() ?? 0) + 1
            )
            modelContext.insert(created)
        }
        try? modelContext.save()
        TriggerEngine.shared.reload()
        dismiss()
    }
}
