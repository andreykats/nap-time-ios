import SwiftUI

struct ContentView: View {
    @State private var ringManager = ColmiRingManager()
    @State private var napController: NapAlarmController?

    var body: some View {
        NavigationStack {
            if let controller = napController {
                MainNapView(controller: controller, ringManager: ringManager)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if napController == nil {
                napController = NapAlarmController(ringManager: ringManager)
            }
        }
    }
}

#Preview {
    ContentView()
}
