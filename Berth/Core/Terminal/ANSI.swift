import Foundation

/// 终端转义序列剥离:CSI(颜色/光标)、OSC、以及裸控制字符(保留 \t \n \r)。
/// 供触发器匹配与会话录制共用,得到可读纯文本。
enum ANSI {
    private static let regex = try? NSRegularExpression(
        pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}[@-Z\\\\-_]|[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}]"
    )

    static func strip(_ text: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
