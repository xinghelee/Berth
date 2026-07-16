# Berth — Mac 原生 SSH 客户端

完整产品与技术方案见 `mac-ssh-client-spec.md`(实施依据,按里程碑推进)。

## 技术栈

- Swift + SwiftUI(AppKit 桥接终端视图),SPM 依赖管理
- SSH: [Citadel](https://github.com/orlandos-nl/Citadel) **锁定 0.12.0**(0.12.1 将 swift-nio-ssh 换成了未评估的第三方个人 fork,勿随意升级)
- 终端模拟: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) **锁定 1.11.2**(1.12+ 引入 Metal GPU 渲染,构建需 Metal Toolchain,本机下载被网络阻断;解决后可升级换取渲染性能)
- ⚠️ 最低系统 **macOS 15**(规格原定 14,但 Citadel 的 `withPTY`/`TTYOutput` API 标注 `@available(macOS 15.0+)`)

## 构建

工程由 XcodeGen 生成,`Berth.xcodeproj` 不入库:

```bash
xcodegen generate                 # 修改 project.yml 或增删文件后重新生成
xcodebuildmcp macos build --project-path Berth.xcodeproj --scheme Berth
xcodebuildmcp macos build-and-run --project-path Berth.xcodeproj --scheme Berth
```

若将来升级 SwiftTerm ≥1.12,构建需 Metal 工具链:`xcodebuild -downloadComponent metalToolchain`(需能访问 Apple 资产 CDN)。

## 测试

本地测试 sshd(密码 dev/berth-spike + 密钥认证,监听 127.0.0.1:2222):

```bash
./docker/test-sshd/up.sh
docker rm -f berth-test-sshd   # 停止
```

Spike 自动连接(自动化验证用):

```bash
<app> --host 127.0.0.1 --port 2222 --user dev --password berth-spike --connect --send "ls /"
```

## 工程约定

- 每个里程碑一个 feature branch;提交信息英文,遵循 conventional commits
- 密码/passphrase 只进 Keychain,任何情况下不落盘明文
- 快捷键不得占用 Ctrl 组合键(透传给 shell)
- 发布形态:Developer ID 签名 + 公证 DMG,不走 App Store(沙盒限制 ~/.ssh 读取)

## 里程碑状态

- [x] M0 — 技术验证 spike:Citadel 连接 + 密码/密钥认证 + PTY + SwiftTerm 渲染 + resize(`Berth/Spike/`)
- [ ] M1 — 骨架与连接:数据模型、Keychain、三栏布局、主机管理、终端标签页
- [ ] M2 — 体验完善:⌘K、ssh_config 导入、密钥管理、known_hosts、断线重连、主题、本地化
- [ ] M3 — 高级连接:端口转发、跳板机、代理、ssh-agent、备份
- [ ] M4 — 二期:SFTP、CloudKit 同步、本地回显、iTerm2 主题导入
