//
//  HexBSDApp.swift
//  HexBSD
//
//  Created by Joseph Maloney on 3/17/25.
//

import SwiftUI
import SwiftData

// App-wide state for critical UI states like delete confirmations
class AppState: ObservableObject {
    @Published var isShowingDeleteConfirmation = false
}

@main
struct HexBSDApp: App {
    @StateObject private var appState = AppState()
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
            ZStack {
                ContentView()
                    .environmentObject(appState)

                // Red overlay when delete confirmation is showing
                if appState.isShowingDeleteConfirmation {
                    Color.red.opacity(0.3)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            }
        }
        .defaultSize(width: 1400, height: 850)
        .modelContainer(sharedModelContainer)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About HexBSD") {
                    NotificationCenter.default.post(name: NSNotification.Name("ShowAboutWindow"), object: nil)
                }
            }
            HelpWindowCommand()
        }
    }
}
