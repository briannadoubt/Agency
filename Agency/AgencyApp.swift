//
//  AgencyApp.swift
//  Agency
//
//  Created by Brianna Zamora on 11/21/25.
//

import SwiftUI

@main
struct AgencyApp: App {
    @State private var showingNewProjectWizard = false

    init() {
        // Auto-discover HTTP providers on app startup
        Task { @MainActor in
            await ProviderRegistry.shared.autoDiscoverProviders()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(showNewProjectWizard: $showingNewProjectWizard)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project...") {
                    showingNewProjectWizard = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
