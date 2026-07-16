import Foundation
import Observation

struct DirectConnectRequest: Identifiable {
    let id = UUID()
    let target: ParsedSSHTarget
}

/// ⌘K 面板与临时直连 sheet 的全局状态
@MainActor
@Observable
final class QuickConnectController {
    static let shared = QuickConnectController()

    var isPresented = false
    var directConnectRequest: DirectConnectRequest?

    func toggle() {
        isPresented.toggle()
    }

    func dismiss() {
        isPresented = false
    }
}
