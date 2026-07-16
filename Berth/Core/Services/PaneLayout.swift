import Foundation

/// 分屏方向
enum SplitAxis: Codable, Equatable { case horizontal, vertical }

/// 一个标签页内的分屏布局树:叶子是一个会话,分支是一次二分(可无限嵌套)。
indirect enum PaneNode: Identifiable, Equatable {
    case leaf(UUID)                                              // sessionID(也作节点 id)
    case branch(id: UUID, axis: SplitAxis, first: PaneNode, second: PaneNode)

    var id: UUID {
        switch self {
        case .leaf(let sid): return sid
        case .branch(let id, _, _, _): return id
        }
    }

    /// 所有叶子会话 id(展示顺序)
    func leafIDs() -> [UUID] {
        switch self {
        case .leaf(let sid): return [sid]
        case .branch(_, _, let a, let b): return a.leafIDs() + b.leafIDs()
        }
    }

    var firstLeaf: UUID {
        switch self {
        case .leaf(let sid): return sid
        case .branch(_, _, let a, _): return a.firstLeaf
        }
    }

    /// 把某个叶子替换成「原叶子 + 新叶子」的分支,实现在该 pane 上再分屏(嵌套)
    func splitting(leaf target: UUID, into newID: UUID, axis: SplitAxis, branchID: UUID) -> PaneNode {
        switch self {
        case .leaf(let sid):
            guard sid == target else { return self }
            return .branch(id: branchID, axis: axis, first: .leaf(sid), second: .leaf(newID))
        case .branch(let id, let ax, let a, let b):
            return .branch(id: id, axis: ax,
                           first: a.splitting(leaf: target, into: newID, axis: axis, branchID: branchID),
                           second: b.splitting(leaf: target, into: newID, axis: axis, branchID: branchID))
        }
    }

    /// 移除某个叶子,并把其父分支塌缩为兄弟节点;整棵树空则返回 nil
    func removing(leaf target: UUID) -> PaneNode? {
        switch self {
        case .leaf(let sid):
            return sid == target ? nil : self
        case .branch(let id, let ax, let a, let b):
            let na = a.removing(leaf: target)
            let nb = b.removing(leaf: target)
            switch (na, nb) {
            case (nil, nil): return nil
            case (nil, let x?): return x          // first 空 → 塌缩为 second
            case (let x?, nil): return x          // second 空 → 塌缩为 first
            case (let x?, let y?): return .branch(id: id, axis: ax, first: x, second: y)
            }
        }
    }

    /// 找到某叶子的相邻叶子(关闭后把焦点交给它)
    func neighborLeaf(of target: UUID) -> UUID? {
        let leaves = leafIDs()
        guard let idx = leaves.firstIndex(of: target) else { return nil }
        if idx + 1 < leaves.count { return leaves[idx + 1] }
        if idx - 1 >= 0 { return leaves[idx - 1] }
        return nil
    }
}

/// 标签页:一棵分屏树 + 当前聚焦的 pane
@MainActor
@Observable
final class PaneTab: Identifiable {
    let id = UUID()
    var root: PaneNode
    var focusedID: UUID
    /// 广播输入:开启后当前标签所有分屏 pane 同步接收键入
    var isBroadcasting = false

    init(sessionID: UUID) {
        self.root = .leaf(sessionID)
        self.focusedID = sessionID
    }
}
