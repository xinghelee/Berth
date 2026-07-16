import AppKit
import UserNotifications

/// 系统通知封装:后台时长任务完成/终端响铃提醒。首次使用时请求授权。
@MainActor
enum NotificationService {
    private static var didRequest = false

    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if didRequest {
            fire()
            return
        }
        didRequest = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { fire() }
        }
    }
}
