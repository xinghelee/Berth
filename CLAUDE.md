# Berth — Mac 原生 SSH 客户端

完整产品与技术方案见 `mac-ssh-client-spec.md`(实施依据,按里程碑推进)。

## 技术栈

- Swift + SwiftUI(AppKit 桥接终端视图),SPM 依赖管理
- SSH: [Citadel](https://github.com/orlandos-nl/Citadel) **已 vendor 到 `vendor/Citadel`(基线 0.12.0)+ 打补丁**;nio-ssh fork 也 vendor 在 `vendor/swift-nio-ssh`。补丁让 RSA 用 rsa-sha2-512 签名,详见 `vendor/PATCHES.md`。升级需重新 vendor 并重放补丁
- 终端模拟: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.14+(含 Metal GPU 渲染后端)
- ⚠️ 最低系统 **macOS 15**(规格原定 14,但 Citadel 的 `withPTY`/`TTYOutput` API 标注 `@available(macOS 15.0+)`)

## RSA 密钥支持(已通过 vendor 补丁解决)

Citadel 原生只用 SHA-1(`ssh-rsa`)签 RSA,OpenSSH 8.8+ 拒收 → RSA 密钥连不上现代服务器。
**已 vendor Citadel + nio-ssh 并打补丁**,改用 `rsa-sha2-512` 签名(RFC 8332),对 OpenSSH 9.2
真机验证通过。补丁点见 `vendor/PATCHES.md`(`grep -rn "\[Berth patch\]" vendor/` 可列全)。
已知边界:RSA 作 host key 且用 SHA-2 签 KEX 的服务器暂未覆盖验签(普遍用 ed25519 host key,不阻塞)。

## 构建

工程由 XcodeGen 生成,`Berth.xcodeproj` 不入库:

```bash
xcodegen generate                 # 修改 project.yml 或增删文件后重新生成
xcodebuildmcp macos build --project-path Berth.xcodeproj --scheme Berth
xcodebuildmcp macos build-and-run --project-path Berth.xcodeproj --scheme Berth
```

SwiftTerm ≥1.12 的 Metal shader 编译需 Xcode Metal 工具链(已安装:`xcodebuild -showComponent metalToolchain` 应为 installed)。若换机重装,用 `xcodebuild -downloadComponent metalToolchain` 补装。

## 测试

单元测试(解析器、Keychain、known_hosts):

```bash
xcodebuildmcp macos test --project-path Berth.xcodeproj --scheme Berth
```

本地测试 sshd(密码 dev/berth-spike + 密钥认证,监听 127.0.0.1:2222):

```bash
./docker/test-sshd/up.sh
docker rm -f berth-test-sshd   # 停止
```

⚠️ 自动化验收必须用 `open -n <app> --env KEY=VAL …` 启动(直接跑二进制不会触发 SwiftUI `.task`)。
known_hosts 弹窗在自动化下由测试代码自动信任。

M1 自动化验收(凭据走环境变量,不进 argv;`BERTH_TRANSIENT_STORE=1` 用内存库):

```bash
BERTH_M1_AUTOTEST=1 BERTH_TRANSIENT_STORE=1 \
  BERTH_TEST_HOST=127.0.0.1 BERTH_TEST_PORT=2222 \
  BERTH_TEST_USER=dev BERTH_TEST_PASSWORD=berth-spike \
  BERTH_TEST_DUMP=/tmp/m1 <app>/Contents/MacOS/Berth
# 流程:Keychain 自检 → 建主机 → 连接 → vim 编辑保存 → 关闭 → 重连
# 结果看 /tmp/m1.log 与 /tmp/m1.{first,second}.{normal,alt} 缓冲区 dump
```

## 工程约定

- 每个里程碑一个 feature branch;提交信息英文,遵循 conventional commits
- 密码/passphrase 只进 Keychain,任何情况下不落盘明文
- 快捷键不得占用 Ctrl 组合键(透传给 shell)
- 发布形态:Developer ID 签名 + 公证 DMG,不走 App Store(沙盒限制 ~/.ssh 读取)

## 里程碑状态

- [x] M0 — 技术验证 spike:Citadel 连接 + 密码/密钥认证 + PTY + SwiftTerm 渲染 + resize(spike 代码已被 M1 正式架构替代)
- [x] M1 — 骨架与连接:SwiftData 模型、Keychain、三栏布局、主机管理、终端标签页(⌘T/⌘W/⌘1-9)、断线横幅重连、基础设置。自动化验收通过(建主机→连接→vim 编辑→关闭重连)
- [x] M2 — 体验完善:⌘K 快速连接、ssh_config 导入+FSEvents 监听、粘贴 ssh 命令解析、密钥管理(生成/导入/Touch ID/storedKey 认证)、known_hosts 校验+指纹确认+变更警告、断线指数退避自动重连、⌘F 搜索、⌘D/⌘⇧D 分屏、4 套主题、中英本地化(zh-Hans 为基准)。单测 35 项 + M2/reconnect 自动化验收全绿
- [ ] M3 — 高级连接:端口转发、跳板机、代理、ssh-agent、备份
- [ ] M4 — 二期:SFTP、CloudKit 同步、本地回显、iTerm2 主题导入
