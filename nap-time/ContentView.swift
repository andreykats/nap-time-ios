import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
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
                let controller = NapAlarmController(ringManager: ringManager)
                controller.modelContext = modelContext
                napController = controller
            } else {
                napController?.modelContext = modelContext
            }
        }
    }
}

#Preview {
    ContentView()
}
