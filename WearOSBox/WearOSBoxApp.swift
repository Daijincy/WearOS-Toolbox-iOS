import SwiftUI
import SwiftData

@main
struct WearOSBoxApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: DeviceProfile.self)
    }
}
