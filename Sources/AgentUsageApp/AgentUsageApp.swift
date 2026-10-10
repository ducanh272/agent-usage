import AgentUsageCore
import SwiftUI

@main
struct AgentUsageApp: App {
    var body: some Scene {
        MenuBarExtra(AppInfo.displayName, systemImage: "chart.bar") {
            VStack(alignment: .leading, spacing: 8) {
                Text(AppInfo.displayName)
                    .font(.headline)
                Text("Usage data will appear here.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 240, alignment: .leading)
        }
        .menuBarExtraStyle(.window)
    }
}
