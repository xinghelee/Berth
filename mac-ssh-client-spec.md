# Mac 原生 SSH 客户端 — 产品与技术方案

> 本文档交给 Claude Code 作为项目实施依据。建议按「里程碑」章节分阶段实施,每个阶段单独开一次会话,完成并验证后再进入下一阶段。

---

## 1. 产品定位

**一句话**:Mac 上原生、好看、免费无阉割的 SSH 客户端。

**核心原则**(所有设计决策的判断依据):

1. **无账号** — 不强制注册,不需要登录。数据本地存储,同步走 iCloud(CloudKit),零服务器。
2. **不设付费墙** — 竞品(Termius)被骂最狠的付费功能在本产品中全部免费:代理/跳板机、SFTP、端口转发、多设备同步。
3. **原生性能** — Swift + SwiftUI,启动 < 1 秒,内存占用远低于 Electron 竞品(Tabby/Electerm)。
4. **不破坏用户习惯** — 快捷键不覆盖 bash/zsh 原生行为;自动导入 `~/.ssh/config`,零冷启动。
5. **中英双语** — 第一版即支持简体中文和英文本地化。

**目标用户**:后端开发者、运维、有 VPS 的个人用户。深色模式为默认。

---

## 2. 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 语言 | Swift 5.10+ | 最低支持 macOS 14 |
| UI | SwiftUI 为主,必要处 AppKit 桥接 | 终端视图、菜单等用 NSViewRepresentable |
| 终端模拟 | [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (SPM) | 处理 ANSI/VT 转义、vim/tmux 全屏应用渲染 |
| SSH 协议 | [Citadel](https://github.com/orlandos-nl/Citadel) (基于 SwiftNIO SSH, SPM) | 纯 Swift;若遇到算法支持缺口,fallback 方案为 libssh2 C 桥接,但优先 Citadel |
| 凭据存储 | Keychain Services | 密码、私钥 passphrase 存 Keychain;私钥文件加密存本地 |
| 数据持久化 | SwiftData(或 GRDB,二选一,倾向 SwiftData) | 主机、分组、设置 |
| 同步 | CloudKit(二期) | 私有数据库,端到端由 iCloud 保障 |
| 依赖管理 | Swift Package Manager | 不引入 CocoaPods |

**验证优先**:项目第一步先做一个技术验证 spike——用 Citadel 连接一台真实主机、开 PTY、把输出接到 SwiftTerm 渲染、跑通 vim。确认这条链路可行后再搭正式架构。如 Citadel 有阻塞性问题(如某些 KEX 算法不支持),尽早切换 libssh2。

---

## 3. 架构

```
App
├── Core/
│   ├── SSH/            # 连接层:SSHSession(连接、认证、PTY、通道)、重连管理
│   ├── Models/         # Host, HostGroup, SSHKey, PortForward, AppSettings
│   ├── Storage/        # SwiftData 容器、Keychain 封装、~/.ssh/config 解析器
│   └── Services/       # HostStore, KeyStore, SessionManager(全局活跃会话)
├── Features/
│   ├── Sidebar/        # 分组/标签导航
│   ├── HostList/       # 主机列表 + 搜索
│   ├── HostEditor/     # 新建/编辑主机表单
│   ├── Terminal/       # 终端标签页、SwiftTerm 封装、会话工具栏
│   ├── QuickConnect/   # ⌘K 面板
│   ├── Keys/           # 密钥管理
│   └── Settings/       # 偏好设置
└── Resources/          # 主题、Localizable.xcstrings(zh-Hans, en)
```

**关键设计**:

- `SessionManager` 为单例 actor,持有所有活跃 `SSHSession`;关窗口不等于断连接(可配置)。
- `SSHSession` 状态机:`idle → connecting → authenticating → connected → disconnected(reason)`。UI 只订阅状态,不直接操作连接。
- 所有 SSH I/O 在后台线程/actor,主线程只做渲染。终端数据流:SSH channel → 环形缓冲 → SwiftTerm feed(主线程批量刷新,合并高频小包,避免掉帧)。

---

## 4. 数据模型(核心字段)

```swift
Host {
  id: UUID
  label: String            // 显示名
  hostname: String
  port: Int = 22
  username: String
  authMethod: enum { password, privateKey(keyID), agent }
  groupID: UUID?
  tagColor: enum { none, red, orange, green, blue, purple }  // 红=生产环境的运维习惯
  jumpHostID: UUID?        // 跳板机,免费功能
  proxy: ProxyConfig?      // HTTP/SOCKS5,免费功能
  note: String?
  sortOrder: Int
  source: enum { manual, sshConfig }   // 来自 ~/.ssh/config 的标记为只读镜像
}

SSHKey {
  id: UUID
  name: String
  privateKeyRef: KeychainRef   // 私钥内容存 Keychain
  publicKey: String
  type: enum { ed25519, rsa, ecdsa }
}

PortForward { type: local/remote/dynamic, bindHost, bindPort, targetHost, targetPort, hostID }
```

密码与 passphrase 一律存 Keychain(`kSecAttrAccessibleWhenUnlocked`),数据库中只存 Keychain 引用,**任何情况下不落盘明文**。

---

## 5. 功能规格

### 5.1 主机管理

- 三栏布局:左侧边栏(分组,可折叠)→ 主机列表(支持列表/卡片切换)→ 右侧终端区(标签页)。
- 主机列表项显示:颜色点、label、user@host、最近连接时间。双击/回车连接。
- **快速新建**:新建表单顶部一个大输入框,粘贴 `user@host:port` 或完整 `ssh user@host -p 2222` 命令自动解析填充,其余字段(认证方式等)在下方渐进展开。
- **自动导入 ~/.ssh/config**:首次启动解析并展示为一个独立分组「SSH Config」,支持 Host 别名、HostName、User、Port、IdentityFile、ProxyJump。文件变更监听(FSEvents)自动刷新。导入的主机可一键「转为托管主机」以编辑。
- 拖拽排序、拖入分组;右键菜单:连接、新标签页连接、编辑、复制 ssh 命令、删除(需确认)。

### 5.2 ⌘K 快速连接(核心交互)

- 全局任意界面 ⌘K 唤起悬浮面板(类似 Raycast/Linear):
  - 模糊搜索主机(label/hostname/username/分组名),↑↓ 选择,回车连接。
  - 输入内容不匹配任何主机且形如 `user@host` 时,回车即临时直连(并提示保存)。
- 性能要求:面板出现 < 100ms,搜索即时无感知延迟。

### 5.3 终端

- 基于 SwiftTerm,包一层 `TerminalView`(NSViewRepresentable)。
- 标签页:⌘T 新标签(重复连接当前主机)、⌘W 关标签(有活跃会话时确认)、⌘1-9 切换、标签可拖出为独立窗口。
- 分屏:同一窗口左右/上下分割,用于对比两台机器(⌘D / ⌘⇧D)。
- **回滚搜索**:⌘F 在 scrollback 中搜索,高亮 + 上下跳转。scrollback 默认 10000 行,可配置。
- **复制粘贴**:遵循 macOS 惯例——⌘C/⌘V;选中即复制(可开关,默认关);右键粘贴。**绝不占用 Ctrl 组合键**,Ctrl+C/Ctrl+R 等原样透传给 shell。
- 字体默认 SF Mono 13pt,行高 1.2;支持 JetBrains Mono 等已安装字体选择;⌘+/⌘- 调字号。
- 主题:内置精调深色主题为默认(参考 One Dark / Catppuccin Macchiato 风格自制),另附 3-4 套(含一套浅色);支持导入 iTerm2 色彩方案(.itermcolors)为加分项。
- **断线处理**:非主动断开时标签页顶部出现细条提示「连接已断开 · 重连」,可配置自动重连(指数退避,保留 scrollback)。
- **连接反馈**:连接过程显示阶段化状态(解析 DNS → TCP → 密钥交换 → 认证);失败时用人话解释,例如:
  - 认证失败 → 「服务器拒绝了这个密钥,检查公钥是否已添加到 authorized_keys,或换一种认证方式」
  - 超时 → 「连不上 <host>:<port>,检查地址、防火墙或网络」
  - Host key 变更 → 明确警告 + 展示新旧指纹 + 需显式确认(安全关键,不允许静默接受)

### 5.4 密钥管理

- 密钥列表:生成(默认 ed25519)、导入(文件/粘贴)、导出公钥、一键复制 `ssh-copy-id` 等效命令。
- 生成时可选 passphrase;passphrase 存 Keychain,连接时无需重复输入。
- **Touch ID**:读取私钥用于连接前可要求 Touch ID 验证(设置项,默认开)。
- 支持使用系统 ssh-agent 认证(读取 SSH_AUTH_SOCK)。

### 5.5 known_hosts 与安全

- 读写标准 `~/.ssh/known_hosts`,与命令行 ssh 互通。
- 首次连接展示指纹(SHA256)供确认。

### 5.6 端口转发(免费)

- 每台主机可配置多条 Local/Remote/Dynamic(SOCKS5)转发;连接时自动建立,状态在会话工具栏可见,可单独开关。

### 5.7 跳板机与代理(免费)

- Host 可指定另一台 Host 为 jump host(等效 ProxyJump),支持链式(A→B→C)。
- 支持 HTTP CONNECT 与 SOCKS5 代理。

### 5.8 性能与「跟手感」(硬性指标)

- 冷启动到可交互 < 1s(M 系列机型)。
- 按键到本地渲染延迟目标 < 16ms;高频输出(如 `yes`、编译日志)不掉帧、不卡 UI。
- **本地回显(predictive echo)**:设置项(默认关,高延迟用户开)。在等待服务器回显期间,将可打印字符以半透明样式先行本地渲染,服务器回显到达后校正。实现参考 Mosh 的预测思路,MVP 可先做保守版本:仅在行编辑常见场景(无全屏应用活跃时)启用。此功能可放二期,但架构上预留钩子。
- 内存:10 个活跃会话 < 300MB。

### 5.9 设置页

分组:通用(语言、启动行为)/ 终端(字体、主题、scrollback、复制行为、本地回显)/ 快捷键(可自定义,冲突检测)/ 安全(Touch ID、known_hosts 策略)/ 数据(导入导出 JSON 备份、重置)。

---

## 6. UI/UX 规范

- 视觉基准:Linear / Things 3 / Craft 的密度与精致度,不是「系统默认灰」。
- 侧边栏:毛玻璃材质(`.ultraThinMaterial`),分组行高 28pt,SF Symbols 图标。
- 动效克制:面板出现用 spring(response 0.3, damping 0.8);列表操作有即时反馈;不做花哨过场。
- 深色模式优先设计,浅色模式同等可用;跟随系统。
- 空状态要设计:无主机时展示「粘贴 ssh 命令开始」+「导入 ~/.ssh/config」两个大按钮。
- 全键盘可操作:从启动到进入终端全程不碰鼠标(⌘K → 回车)。
- 文案:错误信息说人话(见 5.3),中文文案避免机翻腔。

---

## 7. 明确不做(第一版)

- 不做账号系统、不做自建服务器同步
- 不做 Telnet/Mosh/串口
- 不做团队协作、会话录制
- 不做 Windows/Linux 版
- 不做内置 AI(留作后续差异化)
- SFTP 与 CloudKit 同步放到二期(见里程碑),第一版专注连接体验

---

## 8. 里程碑(建议 Claude Code 按此分阶段实施)

### M0 — 技术验证 spike(0.5 天)
命令行或最小窗口 demo:Citadel 连接真实主机 → 密码 + 密钥两种认证 → 请求 PTY → SwiftTerm 渲染 → vim/htop 正常、窗口 resize 正常。**此阶段通过才继续。**

### M1 — 骨架与连接(核心)
项目结构、数据模型、Keychain 封装、主窗口三栏布局、手动新建主机、密码/密钥认证连接、终端标签页、基础设置。
验收:新建主机 → 连接 → 在 vim 中编辑文件 → 关闭重连,全流程稳定。

### M2 — 体验完善
⌘K 快速连接、~/.ssh/config 导入 + FSEvents 监听、粘贴 ssh 命令解析、密钥管理页(生成/导入/Touch ID)、known_hosts 处理、错误信息人话化、断线重连、⌘F 搜索、分屏、主题系统、中文本地化。
验收:全键盘完成一次连接;kill 掉网络后重连体验正常;host key 变更弹出正确警告。

### M3 — 高级连接能力
端口转发(三种)、跳板机(含链式)、HTTP/SOCKS5 代理、ssh-agent 支持、JSON 备份导入导出。

### M4 — 二期(发布后)
SFTP(侧边文件树形式,非独立界面;拖拽上传下载;与终端同会话复用连接)、CloudKit 同步(设计冲突合并:last-write-wins + 删除墓碑)、本地回显完整版、iTerm2 主题导入。

---

## 9. 测试要点

- 单元测试:ssh_config 解析器(覆盖 Host 通配、ProxyJump、IdentityFile 展开 ~)、`user@host:port` / ssh 命令解析器、Keychain 封装。
- 集成测试:用 Docker 起 openssh-server 作为测试目标(密码、密钥、非标准端口、强制断开场景)。
- 手动清单:vim/tmux/htop 渲染、中文与 emoji 宽字符对齐、大量输出时 UI 响应、睡眠唤醒后会话状态。

## 10. 工程约定

- 仓库含 `CLAUDE.md`:记录本方案要点、构建命令(`xcodebuild` / Xcode 项目路径)、代码风格(SwiftLint 默认规则)。
- 每个里程碑一个 feature branch;提交信息用英文,遵循 conventional commits。
- 发布形态:第一版 Developer ID 签名 + 公证的 DMG(官网/GitHub 分发),不走 App Store(避免沙盒对 ~/.ssh 读取的限制;后续如上架再评估 security-scoped bookmark 方案)。
