import Foundation
import UniformTypeIdentifiers

/// SFTP 双击编辑远端文件、用户没指定编辑器时,决定能不能把本地副本交给 macOS 为该文件类型
/// 指定的默认应用(issue #46),而不是一律丢给纯文本编辑器。
///
/// 文件名(含扩展名)由服务器决定,所以不能无条件按扩展名挑程序:`notes.terminal`、`.webloc`、
/// `.command`、`.mobileconfig` 会被直接「执行」而不是编辑。这里过两道门,两道都过才用默认应用,
/// 否则退回系统纯文本编辑器(与 58bb856 之前加固的行为一致):
///
/// 1. 类型门:扩展名对应的 UTType 必须是已声明的、conforms 到 `public.text` 的类型,且不是脚本
///    (`.sh`/`.py`/`.command` 可能被 Terminal、Python Launcher 直接跑)、网页(浏览器渲染 + 跑脚本)、
///    图片(.svg 之类会被图片工具原地改写)、可执行文件。
/// 2. 程序门:该类型的默认程序必须自己声明能打开纯文本(LaunchServices 认它是文本编辑器一类),
///    且没有注册 http/https URL scheme(浏览器)。ProfileHelper、Terminal、Surge 这类「导入/执行」型
///    处理程序不声明纯文本,会被挡在这里。
enum RemoteEditOpenPolicy {

    /// 类型门。返回可以按默认应用处理的 UTType;不满足返回 nil(调用方退回纯文本编辑器)。
    static func textType(forFilenameExtension ext: String) -> UTType? {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let type = UTType(filenameExtension: trimmed), type.isDeclared else { return nil }
        guard type.conforms(to: .text) else { return nil }
        let rejected: [UTType] = [.script, .html, .image, .executable]
        if rejected.contains(where: { type.conforms(to: $0) }) { return nil }
        // .xhtml 只 conforms 到 public.xml 不到 public.html,单独挡掉;.xml 本身放行(配置文件常见)
        if let xhtml = UTType("public.xhtml"), type.conforms(to: xhtml) { return nil }
        return type
    }

    /// 程序门。`plainTextApps` 是 LaunchServices 给出的「能打开 public.plain-text」的应用列表,
    /// `urlSchemes` 是候选程序 Info.plist 里注册的 URL scheme。
    static func isTrustedEditor(_ appURL: URL, plainTextApps: [URL], urlSchemes: [String]) -> Bool {
        let browserSchemes: Set<String> = ["http", "https"]
        if urlSchemes.contains(where: { browserSchemes.contains($0.lowercased()) }) { return false }
        let target = appURL.standardizedFileURL.resolvingSymlinksInPath().path
        return plainTextApps.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == target }
    }
}
