import CoreData
import Foundation

/// 监听 CloudKit 镜像引擎的真实同步事件(NSPersistentCloudKitContainer.Event),
/// 给 UI 提供"同步中 / 上次同步时间 / 出错"三态。CloudKit 无公开的强制拉取 API,
/// 同步由系统调度(前台、有改动、定时);本监视器只反映真实进度,不伪造。
@MainActor
@Observable
final class CloudSyncMonitor {
    static let shared = CloudSyncMonitor()

    enum Phase { case idle, syncing }
    private(set) var phase: Phase = .idle
    private(set) var lastSyncDate: Date?
    private(set) var lastError: String?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
            let ended = event.endDate
            let succeeded = event.succeeded
            let errorText = event.error?.localizedDescription
            MainActor.assumeIsolated {
                if ended == nil {
                    self.phase = .syncing
                } else {
                    self.phase = .idle
                    if succeeded {
                        self.lastSyncDate = ended
                        self.lastError = nil
                    } else {
                        self.lastError = errorText
                    }
                }
            }
        }
    }
}
