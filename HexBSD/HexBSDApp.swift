//
//  HexBSDApp.swift
//  HexBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI
import SwiftData

@main
struct HexBSDApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About HexBSD") {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowAboutWindow"), object: nil)
                }
            }
        }
    }
}
