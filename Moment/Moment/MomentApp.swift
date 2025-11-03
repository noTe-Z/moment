import SwiftUI
import SwiftData

@main
struct MomentApp: App {
    var body: some Scene {
        WindowGroup {
            CaptureView()
        }
        .modelContainer(for: Recording.self)
    }
}
