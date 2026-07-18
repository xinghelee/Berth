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
- 本地化:zh-Hans 基准 + en,`Berth/Resources/Localizable.xcstrings`。新增 UI 文案后:构建 →
  从 DerivedData 的 `Berth.build/**/*.stringsdata` 汇总 key → 给缺失 key 补 en 翻译(SwiftUI
  字面量自动提取;AppKit/动态拼接字符串需手动 `String(localized:)`)。英文验证:
  `open -n <app> --args -AppleLanguages "(en)"`

## 里程碑状态

- [x] M0 — 技术验证 spike:Citadel 连接 + 密码/密钥认证 + PTY + SwiftTerm 渲染 + resize(spike 代码已被 M1 正式架构替代)
- [x] M1 — 骨架与连接:SwiftData 模型、Keychain、三栏布局、主机管理、终端标签页(⌘T/⌘W/⌘1-9)、断线横幅重连、基础设置。自动化验收通过(建主机→连接→vim 编辑→关闭重连)
- [x] M2 — 体验完善:⌘K 快速连接、ssh_config 导入+FSEvents 监听、粘贴 ssh 命令解析、密钥管理(生成/导入/Touch ID/storedKey 认证)、known_hosts 校验+指纹确认+变更警告、断线指数退避自动重连、⌘F 搜索、⌘D/⌘⇧D 分屏、4 套主题、中英本地化(zh-Hans 为基准)。单测 35 项 + M2/reconnect 自动化验收全绿
- [x] M3 — 高级连接(已并入 main):跳板机链式、端口转发(本地/动态 SOCKS5/远程 全部真机验证)、HTTP/SOCKS5 代理、ssh-agent(ed25519+RSA)、服务器信息 inspector(⌘I,含资源图形化)、JSON 备份。均真机验证,35 单测绿
- [~] M4 — 二期(部分已并入 main):
  - [x] ~~iTerm2 主题导入~~ 按用户决定移除,改为 20 套内置主题(含 4 套精选:松烟墨/夜泊琥珀/祖母绿/玉版宣);侧栏底部 🎨 配色面板 + ⚙ 设置入口
  - [x] SFTP 侧边文件面板 + 拖拽上传下载(复用会话连接;`BERTH_SFTP_AUTOTEST` 真机跑通往返)
  - [x] CloudKit 同步(已并入 main):单库镜像 iCloud 私有库(容器 iCloud.com.berthssh.app,Team 99LYH6FNPS)。模型去 unique/关系 optional 化;ssh_config 镜像主机改内存态(不入库不同步,id 按 alias 决定性派生);机密走 iCloud 钥匙串共享访问组 `<team>.com.berthssh.shared` + 数据保护钥匙串同步(密码/密钥库私钥端到端加密,任一设备录入后两端直连),`kSecUseDataProtectionKeychain`;`BERTH_DISABLE_SYNC=1` 调试关闭。设置页同步状态(CloudSyncMonitor:同步中/上次同步/立即同步)。Mac+iPhone 真机双端验收通过:主机/密码同步直连、指纹确认、缺凭据补录引导、私钥文件主机转密钥库后 iOS 可连。⚠️ bundle id 已改名 com.berthssh.app/.ios(旧 com.berthssh.* 机密一次性迁移,含读旧签名项的钥匙串授权弹窗——仅老开发机一次性)
  - [ ] 本地回显(predictive echo)完整版 —— 触及 SwiftTerm 渲染,需交互测延迟,暂缓
- [~] M6 — iOS 版(`BerthiOS` target,`xcodegen generate` 后用
  `xcodebuildmcp simulator build-and-run --project-path Berth.xcodeproj --scheme BerthiOS --simulator-name "iPhone 17 Pro Max"`):
  - [x] 共享核心:Models/Storage/Parsing/SSH 层(HostSpec、KnownHosts、ProxyConnector、PortForwardService、KeyStore、TerminalTheme 已跨平台化,iOS 上 `typealias NSColor = UIColor`)
  - [x] 已具备:主机列表(分组/标签色/生产警戒)、完整主机编辑器(密码/密钥库认证、跳板机、HTTP/SOCKS5 代理、端口转发、启动命令)、SwiftTerm 终端(含按键条)、known_hosts 指纹确认、⚡ 快速连接(ssh 命令解析)、密钥管理(生成/导入)、Snippets({{变量}})、服务器信息面板、20 套主题、中英本地化
  - [x] 模拟器真机验收:连 127.0.0.1:2222 test sshd,建主机→指纹信任→shell 命令回显→信息面板全通
  - [ ] 待补:SFTP 面板、自动重连、私钥文件导入(Files app)、TestFlight 分发签名
- [x] M5 — 布局与体验大改(已并入 main):
  - 布局:双栏(统一平铺主机列表侧栏 + 全宽终端),标题栏会话胶囊 + 标签 chips + 面板按钮组一行;应用图标(系缆桩)
  - 连接稳定性:分屏/⌘T **连接复用**(引用计数 SSHConnection,不新建 TCP);Citadel 补丁 #4(握手失败关 channel);频率惩罚(PerSourcePenalties)人话化;Keychain 稳定签名修复
  - 终端:**无限嵌套分屏**(PaneNode 树 + 焦点 + 塌缩);右键菜单;`exit` 关 pane;悬浮状态栏(CPU/内存/磁盘/时钟/退出码);光标样式;20 主题+配色面板
  - 一批高价值功能(自动化+真机验证,35 单测绿):生产警戒+按主机配色、连接后自动执行命令、⌘P 命令面板、智能选择/⌘点击链接/选中即复制/中键粘贴、多会话广播输入(⌘⌥B)、命令集成(OSC 133 退出码)、Snippets 片段库({{变量}})、断线恢复工作目录(OSC 7)、SFTP chmod/预览/书签、远端文件本地编辑回传+传输进度、命令高亮一键装+切 zsh
