import Foundation
import NIOCore
import NIOSSH

/// 等待用户决策的主机密钥信息(UI 弹窗数据)
struct HostKeyPrompt: Identifiable, Equatable {
    let id = UUID()
    let hostname: String
    let port: Int
    let keyType: String
    let fingerprint: String
    /// 非空 = 密钥变更(安全警告);空 = 首次连接
    let knownFingerprints: [String]

    var isKeyChange: Bool { !knownFingerprints.isEmpty }
}

struct HostKeyError: LocalizedError, Equatable {
    enum Kind {
        case rejectedByUser
        case changedRejected
    }

    let kind: Kind

    var errorDescription: String? {
        switch kind {
        case .rejectedByUser:
            return String(localized: "已取消连接:你没有信任该服务器的主机密钥。")
        case .changedRejected:
            return String(localized: "已中止连接:服务器主机密钥与 known_hosts 记录不一致,可能存在中间人攻击。确认服务器确实更换过密钥后,可在连接时选择更新。")
        }
    }
}

/// known_hosts 校验:一致放行;未知/变更 → 通过 decisionHandler 请求 UI 决策。
/// 首次信任写入 known_hosts;变更且显式确认后替换旧条目。
final class InteractiveHostKeyValidator: NIOSSHClientServerAuthenticationDelegate {
    private let hostname: String
    private let port: Int
    private let store: KnownHostsStore
    private let decisionHandler: @Sendable (HostKeyPrompt) async -> Bool
    /// 首次连接(未知主机密钥)是否静默信任并记住,不弹确认。
    /// iOS 默认开启(known_hosts 不跨设备同步,逐台确认太扰);密钥变更仍强制确认。
    private let autoTrustUnknown: Bool

    init(
        hostname: String,
        port: Int,
        store: KnownHostsStore = KnownHostsStore(),
        autoTrustUnknown: Bool = false,
        decisionHandler: @escaping @Sendable (HostKeyPrompt) async -> Bool
    ) {
        self.hostname = hostname
        self.port = port
        self.store = store
        self.autoTrustUnknown = autoTrustUnknown
        self.decisionHandler = decisionHandler
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let evaluation = store.evaluate(hostname: hostname, port: port, presentedKey: hostKey)

        switch evaluation {
        case .trusted:
            validationCompletePromise.succeed(())

        case .unknown:
            if autoTrustUnknown {
                // 首次连接静默信任:记住密钥,不打扰。写入失败不阻断本次连接。
                try? store.append(hostname: hostname, port: port, key: hostKey)
                validationCompletePromise.succeed(())
                return
            }
            let prompt = HostKeyPrompt(
                hostname: hostname,
                port: port,
                keyType: KnownHostsStore.keyType(of: hostKey),
                fingerprint: KnownHostsStore.fingerprint(of: hostKey),
                knownFingerprints: []
            )
            resolve(prompt, hostKey: hostKey, promise: validationCompletePromise, rejection: HostKeyError(kind: .rejectedByUser))

        case .mismatch(let knownFingerprints):
            let prompt = HostKeyPrompt(
                hostname: hostname,
                port: port,
                keyType: KnownHostsStore.keyType(of: hostKey),
                fingerprint: KnownHostsStore.fingerprint(of: hostKey),
                knownFingerprints: knownFingerprints
            )
            resolve(prompt, hostKey: hostKey, promise: validationCompletePromise, rejection: HostKeyError(kind: .changedRejected))
        }
    }

    private func resolve(
        _ prompt: HostKeyPrompt,
        hostKey: NIOSSHPublicKey,
        promise: EventLoopPromise<Void>,
        rejection: HostKeyError
    ) {
        let store = store
        let hostname = hostname
        let port = port
        let handler = decisionHandler
        Task {
            if await handler(prompt) {
                do {
                    if prompt.isKeyChange {
                        try store.replace(hostname: hostname, port: port, key: hostKey)
                    } else {
                        try store.append(hostname: hostname, port: port, key: hostKey)
                    }
                } catch {
                    // 写入失败不阻断本次连接,下次仍会再询问
                }
                promise.succeed(())
            } else {
                promise.fail(rejection)
            }
        }
    }
}
