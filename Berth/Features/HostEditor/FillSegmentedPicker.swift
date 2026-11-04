import AppKit
import SwiftUI

/// 撑满整行、各段等宽的分段控件(issue #51)。
/// SwiftUI 的 `.pickerStyle(.segmented)` 在 macOS 上只按标签内容取宽,给 `.frame(maxWidth: .infinity)`
/// 也只是居中不拉伸;这里直接用 NSSegmentedControl 的 fillEqually 分布,宽度跟随 Form 行宽。
struct FillSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: options.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.changed(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segmentCount != options.count {
            control.segmentCount = options.count
        }
        for (index, option) in options.enumerated() where control.label(forSegment: index) != option.label {
            control.setLabel(option.label, forSegment: index)
        }
        if let index = options.firstIndex(where: { $0.value == selection }), control.selectedSegment != index {
            control.selectedSegment = index
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        // 有具体宽度就占满;理想尺寸(nil / infinity)回落到内容宽,别把 Form 撑宽
        guard let width = proposal.width, width.isFinite else { return intrinsic }
        return CGSize(width: width, height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject {
        var parent: FillSegmentedPicker

        init(parent: FillSegmentedPicker) { self.parent = parent }

        @MainActor @objc func changed(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}
