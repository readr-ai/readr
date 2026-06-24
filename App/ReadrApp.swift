import SwiftUI

@main
struct ReadrApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(model)
        }
    }
}
