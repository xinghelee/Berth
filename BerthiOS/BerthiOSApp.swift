import SwiftData
import SwiftUI

@main
struct BerthiOSApp: App {
    private let container = Persistence.makeContainer()
    @State private var theme = ThemeStore.shared

    var body: some Scene {
        WindowGroup {
            HostListView()
                .tint(theme.current.accentColor)
                .preferredColorScheme(theme.current.isDark ? .dark : .light)
        }
        .modelContainer(container)
    }
}
