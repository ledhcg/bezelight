import SwiftUI
import AppKit
import BezelightCore

@main
struct BezelightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Bezelight", id: "main") {
            MainView()
                .tint(Brand.accent)
                .environmentObject(model)
                .id(model.language) // rebuild the tree so every string re-resolves
                .background(WindowStyler())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 720)

        // A plain window (same configuration as the main one) rather than the `Settings` scene:
        // it lets the title bar blend into the backdrop and keeps the window buttons visible.
        Window(tr("action.settings"), id: "settings") {
            SettingsView()
                .tint(Brand.accent)
                .environmentObject(model)
                .id(model.language)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { SettingsCommand() }

        MenuBarExtra {
            MenuBarView()
                .tint(Brand.accent)
                .environmentObject(model)
                .id(model.language)
        } label: {
            MenuBarLabel(agents: model.agents, running: model.running)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar icon. An agent that needs you, failed or finished changes its *shape*, so the
/// state is not conveyed by colour alone (the system draws menu bar icons in a single colour).
struct MenuBarLabel: View {
    @ObservedObject var agents: AgentsModel
    let running: Bool

    var body: some View {
        Image(systemName: agents.menuSymbol ?? (running ? "lightbulb.led.fill" : "lightbulb.led"))
            .accessibilityLabel(agents.snapshot.waiting > 0 ? tr("agents.menu.waiting", agents.snapshot.waiting) : "Bezelight")
    }
}

/// ⌘, opens Settings, as in any Mac app.
struct SettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(tr("action.settings") + "…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
        }
    }
}

/// One soft periwinkle accent for every control, instead of the saturated system blue.
enum Brand {
    static let accent = Color(red: 0.42, green: 0.45, blue: 0.96)
}

extension AppModel {
    @MainActor static let shared = AppModel()
}

/// Lighting keeps running with the window closed; quitting turns the LEDs off first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.quitOnClose }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await AppModel.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
