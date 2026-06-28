import SwiftUI

@main
struct X4SyncServerApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 760, minHeight: 560)
    }
    .windowResizability(.contentSize)
  }
}
