import AgentUsageCore
import AppKit
import SwiftUI

@main
struct AgentUsageApp: App {
    var body: some Scene {
        MenuBarExtra(AppInfo.displayName, systemImage: "chart.bar") {
            CodexSetupPanel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct CodexSetupPanel: View {
    @AppStorage("codexExecutablePath") private var executablePath = ""
    @AppStorage("codexHomePath") private var homePath = ""
    @State private var result: CodexSetupResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppInfo.displayName).font(.headline)
            Text(statusMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let executable = result?.executableURL {
                LabeledContent("Codex", value: executable.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Codex home", value: result?.codexHomeURL.path ?? "Checking…")
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button("Choose Codex…", action: chooseExecutable)
                if !executablePath.isEmpty {
                    Button("Use Automatic") { executablePath = "" }
                }
            }
            HStack {
                Button("Choose Home…", action: chooseHome)
                if !homePath.isEmpty {
                    Button("Use Default Home") { homePath = "" }
                }
            }
            HStack {
                Button("Recheck") { Task { await checkSetup() } }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(minWidth: 360, alignment: .leading)
        .task(id: executablePath + "\u{0}" + homePath) { await checkSetup() }
    }

    private var statusMessage: String {
        switch result?.status {
        case .ready:
            return "Codex is signed in with ChatGPT. Usage data will appear here in a later update."
        case .missingInstallation:
            return "Codex CLI was not found. Install it or choose its executable."
        case .invalidExecutableOverride:
            return "The selected Codex path is not an executable. Choose another file or use automatic discovery."
        case .invalidHomeDirectory:
            return "The Codex home directory does not exist. Choose an existing directory or use the default."
        case .missingSignIn:
            return "Codex is not signed in. Run `codex login` in Terminal, then recheck."
        case .unsupportedAuthentication:
            return "Codex uses an unsupported sign-in method. Sign in with ChatGPT using `codex login`."
        case .unableToCheckLogin:
            return "Could not check Codex sign-in. Run `codex login status` in Terminal and verify the selected executable and home."
        case nil:
            return "Checking Codex setup…"
        }
    }

    private func checkSetup() async {
        let configuration = CodexSetupConfiguration(
            executableOverride: executablePath.isEmpty ? nil : executablePath,
            homeOverride: homePath.isEmpty ? nil : homePath
        )
        let checked = await CodexSetupChecker().check(configuration: configuration)
        guard !Task.isCancelled else { return }
        result = checked
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Codex executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { executablePath = url.path }
    }

    private func chooseHome() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Codex home directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { homePath = url.path }
    }
}
