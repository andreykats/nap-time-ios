//
//  nap_timeApp.swift
//  nap-time
//
//  Created by Andrey Kats on 4/15/26.
//

import SwiftUI

@main
struct nap_timeApp: App {
    init() {
        // Sensitivity slider was redesigned around an explicit 1.0 default with a
        // visible "Default" badge. Older builds let users land on values they
        // couldn't distinguish (the "Normal" label spanned 0.8–1.1), so any
        // persisted value from before this migration is unlikely to be intentional.
        // One-time reset to surface the new default on first launch of this version.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "sensitivityDefaultMigrated") {
            defaults.removeObject(forKey: "sensitivity")
            defaults.set(true, forKey: "sensitivityDefaultMigrated")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
