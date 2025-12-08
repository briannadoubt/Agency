import SwiftUI

/// Main settings view with tabs for different configuration areas.
struct SettingsView: View {
    var body: some View {
        TabView {
            ClaudeCodeSettingsView()
                .tabItem {
                    Label("Claude Code", systemImage: "terminal")
                }

            SupervisorSettingsView()
                .tabItem {
                    Label("Background Processing", systemImage: "gearshape.2")
                }
        }
        .frame(minWidth: 500, minHeight: 500)
    }
}

#Preview {
    SettingsView()
}
