import AppKit
import SwiftUI

/// 命令面板/快速连接的搜索输入框(AppKit 背板)。
///
/// 用 NSTextField 而非 SwiftUI TextField:SwiftUI 的 `.focused` 抢不过 SwiftTerm
/// 终端视图(AppKit NSView)持有的 window first responder,导致方向键泄漏到背后终端。
/// 这里在出现时强制成为 first responder,并自己拦截 ↑/↓/回车/Esc 转成回调。
struct PaletteTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusStealingTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 16)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        // 抢过终端的 first responder(SwiftTerm NSView 会一直占着)
        if let window = field.window, window.firstResponder !== field.currentEditor() {
            DispatchQueue.main.async { window.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: PaletteTextField
        init(_ parent: PaletteTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onMoveUp(); return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onMoveDown(); return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel(); return true
            default:
                return false
            }
        }
    }
}

/// 出现即成为 first responder 的文本框
private final class FocusStealingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { window.makeFirstResponder(self) }
    }
}
