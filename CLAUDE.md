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
老式服务器/堡垒机兼容(issue #12):RSA host key(rsa-sha2-512/256 + ssh-rsa)验签、
DH group14 KEX、aes128-ctr 均已启用(`SSHAlgorithms.berthCompatibility`),现代算法仍优先;
协商失败错误会带双方算法列表诊断。回归:`./docker/test-sshd/up-legacy.sh`(2224)。

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
known_hosts 弹窗在自动化下由测试代码自动信任。验收 harness(`Berth/Debug/`)整体 `#if DEBUG`,
**只存在于 Debug 构建**;带任何 `BERTH_` 环境变量启动时 defaults 持久域会被快照并在退出时
恢复(`AcceptanceDefaults`),验收里写的 requireTouchIDForKeys/aiAutoRunCommands 不会留在真机上。

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
- 安全边界(远端服务器视为敌对):主机密钥首次连接必须核对指纹(Mac/iOS 一致),已知主机换
  密钥类型按「变更」级警告,证书形式主机密钥一律拒绝;认证失败不自动重连、仪表盘不重试;
  AI 自动执行只放行 `AICommandPolicy` 白名单里的只读命令,命令输出落盘/送模型前过
  `SecretRedactor`;远端命名的文件不交给 LaunchServices 默认程序(本地编辑固定用文本编辑器),
  `LSFileQuarantineEnabled` 已开;终端不回应 OSC 52 读剪贴板,链接只放行 http/https/mailto(+Mac file);
  私钥门禁(Touch ID)按「本次运行 + 主机 + 认证材料」记一次(`KeyUseGrants`,issue #29):存活会话
  期间不失效,断开后空闲 15 分钟失效,换密钥/跳板机重验,退出即清;仪表盘的后台授权独立
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
  - [x] SFTP 侧边文件面板 + 拖拽上传下载(复用会话连接;`BERTH_SFTP_AUTOTEST` 真机跑通往返)。
    issue #33:子通道被杀/挂住(20s 看门狗)/断线后自愈重开回原目录,失败态有「重试」;
    Finder 式多选(⌘/⇧)批量下载到文件夹/批量删除;验收含三种恢复场景。
    issue #34:本地编辑 md/html 时相对引用的资源随主文件按远端绝对路径镜像下载(直接引用、有上限),
    VS Code 预览里的图片能显示;资源落在文档目录之外(`../`)时,对声明能开文件夹的编辑器
    (VS Code 一类)把共同祖先目录当工作区一起打开,否则 VS Code 预览会拦掉;`BERTH_SFTPEDIT_AUTOTEST` 覆盖
    issue #38(PR #40):上传/下载与列目录共用子通道,看门狗探活也无回应但有传输在途时推迟关通道
    (最多再等 2 轮,轮次用尽照旧自愈);`BERTH_SFTP_NAV_AUTOTEST` 覆盖(SIGSTOP sftp → 上传卡 open →
    切目录 → 定时 SIGCONT → 导航经推迟路径完成、上传字节完整)
  - [x] 本地 Shell(issue #3):SwiftTerm LocalProcess 本地 PTY 会话,复用标签/分屏/主题/广播/AI 面板(本地 exec 走 Process)。入口:⇧⌘T、⌘K、⌘P、标签条「+」、空状态按钮;设置可自定义 shell 路径(留空=登录 shell);⌥⌘L 在任意会话旁混合分屏本地 Shell;拖文件到本地 pane 插入转义路径(SSH pane 仍走 SFTP 上传)。SSH 专属面板(SFTP/Docker/⌘I)对本地会话隐藏。`BERTH_LOCAL_AUTOTEST=1` 自动化验收;`BERTH_WINDOW_SNAPSHOT` 免录屏权限窗口自截图。标题栏整行给标签(会话信息/生产警戒移到底部状态栏,点按开 ⌘I),标签双击/右键重命名
  - [x] CloudKit 同步(已并入 main):单库镜像 iCloud 私有库(容器 iCloud.com.berthssh.app,Team 99LYH6FNPS)。模型去 unique/关系 optional 化;ssh_config 镜像主机改内存态(不入库不同步,id 按 alias 决定性派生);机密走 iCloud 钥匙串共享访问组 `<team>.com.berthssh.shared` + 数据保护钥匙串同步(密码/密钥库私钥端到端加密,任一设备录入后两端直连),`kSecUseDataProtectionKeychain`;`BERTH_DISABLE_SYNC=1` 调试关闭。设置页同步状态(CloudSyncMonitor:同步中/上次同步/立即同步)。Mac+iPhone 真机双端验收通过:主机/密码同步直连、指纹确认、缺凭据补录引导、私钥文件主机转密钥库后 iOS 可连。⚠️ bundle id 为 com.berthssh.app/.ios(早期开发构建的机密已一次性迁移完毕,旧 service 迁移代码已移除)
  - [x] keyboard-interactive 认证(issue #12 堡垒机 MFA):vendor nio-ssh 补 RFC 4256
    (INFO_REQUEST/60 与 PK_OK 复用按内容判别)+ Citadel 多轮认证修复,详见 `vendor/PATCHES.md`。
    password 失败自动转 kbd-int,首个不回显提示用存储密码自动作答,MFA 码弹 sheet。
    验收:`docker/test-sshd/up-kbdint.sh`(2223)+ `BERTH_KBDINT_AUTOTEST=1` 双路径通过
  - [x] issue #11 批次:本地 Shell PTY 初始尺寸(fork 后 child 设 TIOCSWINSZ,折行修复)、
    分屏拖分割线调比例(双击复位)、SFTP 初始目录跟随 pane(OSC 7)、侧栏 ⌘点按/右键
    对同主机再开连接(复用 SSH 连接)
  - [x] issue #11 二批:失败卡片 × 立即关闭;卡片进编辑后「保存」即用新配置重连(不再
    杵着旧 spec);跨主机分屏(侧栏右键「在分屏中连接」+ 终端右键「分屏连接主机」子菜单,
    `splitFocused(axis:spec:)` 同主机仍复用连接)
  - [x] issue #12 二批(堡垒机 KEX 兼容):老式算法协商失败修复 —— DH group14
    sha256/sha1 KEX、aes128-ctr、RSA host key(rsa-sha2-512/256+ssh-rsa 验签,vendor
    补丁)via `SSHAlgorithms.berthCompatibility`(Mac+iOS);协商失败错误带双方算法列表。
    验收:`docker/test-sshd/up-legacy.sh`(2224)四组合 + M1 autotest ALL_DONE
  - [x] 服务器仪表盘(⌘0 主窗口内切换 / 侧栏 📊 / ⌘P;「仪表盘(新窗口)」可撕成独立窗口
    常驻第二块屏,两种形态共用同一个采集引擎,按观察者计数启停):所有主机的 CPU/内存/磁盘/
    交换/网络速率/负载/进程/温度/运行时长一屏看完,每卡片带 CPU 走势 sparkline。
    拨号逻辑抽成 `Core/SSH/SSHDialer.swift`(终端会话与监控共用,交互回调可注入);
    采集脚本+解析在 `Core/SSH/ServerMetrics.swift`(Linux 走 /proc 原始计数器,跨两次
    采样求 CPU 占用与网络速率;macOS/BSD 用 sysctl/vm_stat/netstat 兜底);轮询引擎
    `Core/Services/ServerMonitor.swift`(已有终端会话则借其连接,否则自建**不开 PTY**
    的常驻连接;并发拨号封顶 4、失败指数退避;**后台绝不弹窗** —— 未确认的主机密钥/
    MFA/Touch ID 门禁分别落到「需确认/需授权」卡片,授权按钮过一次 Touch ID 解锁本次运行)。
    验收:`BERTH_DASHBOARD_AUTOTEST=1`(菜单接线 → 内嵌可见 → 在线卡片有真实 CPU/内存/磁盘
    → 借用终端连接 → 关掉会话后自建连接 → 离线原因 → 撕成独立窗口后采集不断 → 两种形态自截图)
  - [x] issue #41:本地 Shell 书签(`Host.isLocalShell` + `localDirectory`,侧栏新建选「本地 Shell」类型,
    起始目录/启动命令;iOS/仪表盘/可达性/跳板候选过滤掉;本地标签右键「将当前目录存为侧栏书签」);
    临时本地标签标题跟随 shell 当前目录(`proc_pidinfo` 查 cwd —— 系统 zsh 不对非 Apple_Terminal 发 OSC 7),
    ⌘T/分屏继承当前目录;设置「标签字号」11–18pt;切标签后终端焦点修复(视图挂回窗口才
    makeFirstResponder,`BerthTerminalView.requestFocus`)。`BERTH_LOCAL_AUTOTEST` 覆盖
  - [ ] 本地回显(predictive echo)完整版 —— 触及 SwiftTerm 渲染,需交互测延迟,暂缓
  - [x] 外部 PR #43/#44/#45(wsldl123292,2026-10-09 合入):侧栏主机行双击再开一条同主机连接
    (设置「标签页」可关;首击已拨号则双击第二击不补开,⌘ 点按同样打点);断线态任意按键即重连
    (卡片提示「按回车也可重连」,按键不转发给远端);AI 模型列表从接入点 `GET /models` 拉取
    (`AIModelCatalog`,只打用户配置的 API 地址、用同一把 Key,结果按「格式|地址」缓存到
    UserDefaults `ai.modelCatalog`;404/405 当「不支持列表」灰提示),面板输入框底部模型胶囊可切换/
    手填/刷新;设置页「获取模型列表」行,模型不在列表时落「自定义…」。附带 `scripts/package_dmg.sh`
    (贡献者的本地打包脚本,非正式发布流程)。验收:mock `/v1/models` 网关 + docker sshd 真机点过
- [~] M6 — iOS 版(`BerthiOS` target,`xcodegen generate` 后用
  `xcodebuildmcp simulator build-and-run --project-path Berth.xcodeproj --scheme BerthiOS --simulator-name "iPhone 17 Pro Max"`):
  - [x] 共享核心:Models/Storage/Parsing/SSH 层(HostSpec、KnownHosts、ProxyConnector、PortForwardService、KeyStore、TerminalTheme 已跨平台化,iOS 上 `typealias NSColor = UIColor`)
  - [x] 已具备:主机列表(分组/标签色/生产警戒)、完整主机编辑器(密码/密钥库认证、跳板机、HTTP/SOCKS5 代理、端口转发、启动命令)、SwiftTerm 终端(含按键条)、known_hosts 指纹确认、⚡ 快速连接(ssh 命令解析)、密钥管理(生成/导入)、Snippets({{变量}})、服务器信息面板、20 套主题、中英本地化
  - [x] 模拟器真机验收:连 127.0.0.1:2222 test sshd,建主机→指纹信任→shell 命令回显→信息面板全通
  - [x] SFTP 面板(`SFTPSheetIOS`,与 Mac 共用 `SFTPBrowser` 核心——已跨平台化并加入 iOS
    编译源):浏览/上传(Files app)/下载分享/重命名/删除/新建目录/路径跳转/文本预览/传输进度。
    终端工具栏 📁 入口,复用会话连接开子通道。模拟器验收:连接→列目录→进目录→预览全通
  - [x] 自动重连:连上过的会话网络掉线(reset/timeout 等关键词)指数退避重连(≤8 次、封顶
    30s,与 Mac 同参);服务器干净关闭不自动重连;回前台立即重试(iOS 后台掐 socket);
    断线卡片带「立即重连/关闭」,scrollback 原地保留。模拟器验收:重启 sshd → 卡片 → 重连成功
  - [x] 私钥文件导入:密钥导入 sheet 增加「从『文件』选择私钥…」(fileImporter,
    安全作用域读取,64KB 上限,文件名自动作密钥名),解析仍走共用 KeyStore/PrivateKeyFormat
  - [ ] 待补:TestFlight 分发签名
- [x] M5 — 布局与体验大改(已并入 main):
  - 布局:双栏(统一平铺主机列表侧栏 + 全宽终端),标题栏会话胶囊 + 标签 chips + 面板按钮组一行;应用图标(系缆桩)
  - 连接稳定性:分屏/⌘T **连接复用**(引用计数 SSHConnection,不新建 TCP);Citadel 补丁 #4(握手失败关 channel);频率惩罚(PerSourcePenalties)人话化;Keychain 稳定签名修复
  - 终端:**无限嵌套分屏**(PaneNode 树 + 焦点 + 塌缩);右键菜单;`exit` 关 pane;悬浮状态栏(CPU/内存/磁盘/时钟/退出码);光标样式;20 主题+配色面板
  - 一批高价值功能(自动化+真机验证,35 单测绿):生产警戒+按主机配色、连接后自动执行命令、连接后 su 切换用户(issue #35:等到密码提示再从钥匙串填,不盲发;`BERTH_SWITCHUSER_AUTOTEST`)、⌘P 命令面板、智能选择/⌘点击链接/选中即复制/中键粘贴、多会话广播输入(⌘⌥B)、命令集成(OSC 133 退出码)、Snippets 片段库({{变量}})、断线恢复工作目录(OSC 7)、SFTP chmod/预览/书签、远端文件本地编辑回传+传输进度、命令高亮一键装+切 zsh(⌘P 也有直达入口,issue #32)
