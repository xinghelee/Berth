# Vendored packages & patches

`vendor/Citadel` 与 `vendor/swift-nio-ssh` 是本地 vendor 的依赖,`project.yml` 通过本地
路径引用(不再走 SPM 远程)。基线:

- **Citadel** 0.12.0(github.com/orlandos-nl/Citadel @ 0.12.0)
- **swift-nio-ssh** 0.3.4(github.com/Joannis/swift-nio-ssh @ b93961a,Citadel 用的 fork)

vendor 后各自删除了 `.git`,`Citadel/Package.swift` 的 nio-ssh 依赖改为 `.package(path: "../swift-nio-ssh")`。

## 补丁:RSA 用 rsa-sha2-512 签名(替代 SHA-1 ssh-rsa)

**动机**:Citadel 原生只用 SHA-1(`ssh-rsa`)给 RSA 密钥签名,OpenSSH 8.8+ 默认拒收,
导致 RSA 密钥连不上现代服务器(报「服务器拒绝了认证」)。RFC 8332 的 `rsa-sha2-256/512`
是替代方案:**密钥 blob 类型仍是 `ssh-rsa`,但签名算法名与签名哈希换成 SHA-2**。

难点:nio-ssh 把「user-auth 广播的签名算法名」和「密钥 blob 类型」共用同一个
`publicKeyPrefix`,无法只改 Citadel。故补丁分布在两个包,均以 `[Berth patch]` 注释标记。

### swift-nio-ssh
- `Keys And Signatures/CustomKeys.swift`:给 `NIOSSHPublicKeyProtocol` 加
  `static var userAuthPrefix`,默认 `= publicKeyPrefix`(对所有现有密钥无影响)。
- `Keys And Signatures/NIOSSHPublicKey.swift`:给 wrapper 加 `userAuthPrefix` 计算属性,
  仅 `.custom` 密钥返回自定义值,其余等于 `keyPrefix`。
- `SSHMessages.swift` `writeUserAuthRequestMessage`:算法名字段改用 `key.userAuthPrefix`。
- `User Authentication/UserAuthSignablePayload.swift`:待签 payload 的算法名改用
  `publicKey.userAuthPrefix`(RFC 8332 §3.3,签名数据里的算法名须与广播一致)。

### Citadel
- `Algorithms/RSA.swift`:
  - `PublicKey.userAuthPrefix = "rsa-sha2-512"`(`publicKeyPrefix` 保持 `"ssh-rsa"`)。
  - `Signature.signaturePrefix = "rsa-sha2-512"`。
  - `PrivateKey.signature(for:)`:`SHA512` + `NID_sha512`(原为 SHA-1 + `NID_sha1`)。

### 影响面与已知边界
- ed25519 / ECDSA / 密码认证:不受影响(`userAuthPrefix` 默认等于原 `keyPrefix`)。
- RSA **验签**(`PublicKey.isValidSignature`)仍是 SHA-1,只在 RSA 作 **host key** 时用;
  连接普遍用 ed25519/ecdsa host key,故未受影响。若将来需连「host key 为 ssh-rsa 且用
  SHA-2 签 KEX」的服务器,需再补验签路径(当前不阻塞)。
- 验证:对 OpenSSH 9.2 真机(192.168.1.111 / .222)用 RSA 密钥连通 OK;ed25519 / 密码 /
  known_hosts 全回归通过;35 项单测通过。

## 补丁:connect(on:settings:) 在 event loop 上加 handler

`Sources/Citadel/ClientSession.swift` 的 `SSHClientSession.addHandlers` 原来直接调
`channel.pipeline.syncOperations.addHandlers(...)`,而 syncOperations 要求在 channel 自身的
event loop 上执行。`SSHClient.connect(on:settings:)`(经代理自建 channel 时用)从任意异步
上下文调用它,触发 `assertInEventLoop` 崩溃。补丁把 addHandlers 包进 `channel.eventLoop.submit { … }`,
使其在正确的 event loop 上运行。标记 `[Berth patch]`。

## 升级 Citadel/nio-ssh 时
本地 vendor 已脱离 SPM 版本管理。若要升级,需重新 vendor 对应版本并重放上述 `[Berth patch]`
改动(`grep -rn "\[Berth patch\]" vendor/` 可列出全部补丁点)。
