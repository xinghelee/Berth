# Berth 泊

**SSH,该有 Mac 的样子。**

[English](README.en.md)

Berth 是一款 Swift 原生的 macOS SSH 客户端——Metal 渲染终端、连接复用、无限分屏。密码与私钥只进 Keychain,任何数据不离开你的 Mac。

![Berth 终端](site/public/assets/shots/hero-terminal.png)

macOS 15+ · Apple Silicon & Intel · Developer ID 签名与公证

**[⬇︎ 下载 Berth 1.0.0](https://github.com/xinghelee/Berth/releases/latest/download/Berth-1.0.0.dmg)** · [全部版本](https://github.com/xinghelee/Berth/releases)

## 功能

**连接复用与无限分屏。** ⌘T 新标签、⌘D 分屏共享同一条 SSH 通道,不再重新握手。分屏可无限嵌套,`exit` 即收起。

**跳板机与端口转发。** 链式跳板一路到底;本地 / 远程 / 动态 SOCKS5 转发,支持 HTTP 与 SOCKS5 出站代理和 ssh-agent。

**密钥与 Touch ID。** 生成、导入密钥,使用私钥前 Touch ID 验证。`known_hosts` 指纹确认,变更即警告。

**SFTP 文件面板。** 复用会话连接,拖拽上传下载。远端文件用本地编辑器打开,保存自动回传;chmod、书签、文本预览。

**断线不慌。** 指数退避自动重连,重连后回到原工作目录(OSC 7);命令退出码直接标在终端里(OSC 133)。

**生产环境警戒。** 按主机警戒配色,一眼分清测试与生产。广播输入(⌘⌥B)同时操作多台;Snippets 片段库带 `{{变量}}`。

**ssh_config 原生集成。** 导入现有 `~/.ssh/config` 并监听变更实时同步。粘贴任意 `ssh user@host -p 2222` 命令即可直接连接。

**iCloud 同步。** 主机与设置镜像到你的 iCloud 私有数据库;机密经 iCloud 钥匙串端到端加密同步。没有账号,没有我们的服务器。

**二十套内置主题。** Nord、Dracula、Catppuccin、Solarized 尽数内置,另有四套 Berth 原创:松烟墨、玉版宣、夜泊琥珀、祖母绿圣殿。

**键盘优先。** ⌘K 快速连接、⌘P 命令面板、⌘D 分屏、⌘F 搜索、⌘I 服务器信息。Ctrl 组合键全部透传给 shell,你的 Emacs / readline 习惯原样保留。

iOS 伴侣应用(`BerthiOS`)共享同一套核心:主机列表、完整主机编辑器、带按键条的 SwiftTerm 终端、密钥管理、Snippets 与主题。

## 安全

两条底线,写进架构:

- **机密只进 Keychain。** 密码、passphrase、私钥存 macOS Keychain,任何情况不落盘明文。JSON 备份只含主机结构,不含机密。
- **数据全在本地。** 没有账号,没有我们的云端。主机列表在你的 Mac 上,与 `ssh_config` 双向同步;iCloud 同步只经过你自己的私有数据库。

## 安装

Homebrew:

```sh
brew install --cask xinghelee/tap/berth
```

或从 [Releases](https://github.com/xinghelee/Berth/releases/latest) 下载最新的 `Berth-x.y.z.dmg`,打开后把 Berth 拖入「应用程序」。DMG 经 Developer ID 签名并通过 Apple 公证,首次启动无需任何绕过步骤。

## 从源码构建

依赖:Xcode 16+ 及 Metal 工具链(缺失时 `xcodebuild -downloadComponent metalToolchain` 补装)、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
xcodegen generate    # Berth.xcodeproj 由工程文件生成,不入库
xcodebuild -project Berth.xcodeproj -scheme Berth build        # macOS 应用
xcodebuild -project Berth.xcodeproj -scheme BerthiOS build \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' # iOS 应用
```

运行单元测试(解析器、Keychain、known_hosts,共 35 项):

```bash
xcodebuild -project Berth.xcodeproj -scheme Berth test
```

本地测试用的一次性 sshd(密码 `dev` / `berth-spike`,支持密钥认证,监听 `127.0.0.1:2222`):

```bash
./docker/test-sshd/up.sh
docker rm -f berth-test-sshd   # 停止
```

## 技术栈

- **SwiftUI**(AppKit 桥接终端视图)+ **SwiftData** 持久化
- **[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)** 终端模拟,启用 Metal GPU 渲染后端
- **[Citadel](https://github.com/orlandos-nl/Citadel)** SSH 库,vendor 在 `vendor/` 并打补丁——核心是 `rsa-sha2-512` 签名(RFC 8332),让 RSA 密钥能连 OpenSSH 8.8+;详见 `vendor/PATCHES.md`
- **XcodeGen** 生成工程;以公证 DMG 分发(不走 App Store 沙盒,保住 `~/.ssh` 读取)

---

*Berth · 系好每一条连接*
