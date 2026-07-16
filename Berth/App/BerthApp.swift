import SwiftUI

@main
struct BerthApp: App {
    var body: some Scene {
        WindowGroup("Berth — M0 Spike") {
            SpikeView()
                .frame(minWidth: 720, minHeight: 480)
        }
    }
}
