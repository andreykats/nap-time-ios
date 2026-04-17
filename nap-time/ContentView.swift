import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .nap
    @State private var ringManager = ColmiRingManager()
    @State private var napController: NapAlarmController?

    enum AppTab {
        case nap, settings, ring, calibrate
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            SwiftUI.Tab("Nap", systemImage: "bed.double.fill", value: .nap) {
                NavigationStack {
                    if let controller = napController {
                        MainNapView(controller: controller, ringManager: ringManager)
                    } else {
                        ProgressView()
                    }
                }
            }

            SwiftUI.Tab("Settings", systemImage: "gearshape.fill", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }

            SwiftUI.Tab("Ring", systemImage: "circle.circle", value: .ring) {
                NavigationStack {
                    ConnectionView(ringManager: ringManager)
                }
            }

            SwiftUI.Tab("Test", systemImage: "target", value: .calibrate) {
                NavigationStack {
                    CalibrationView()
                }
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
