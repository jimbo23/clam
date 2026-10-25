#if canImport(AppKit)
import AppKit
import SwiftUI

@main
struct ClamApp: App {
    @NSApplicationDelegateAdaptor(ClamAppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            Text(model.hasOperationError ? "Clam needs attention" : (model.isOn ? "Clam is On" : "Clam is Off"))
                .font(.headline)
            Text(model.statusText)
            Divider()
            Toggle("Keep Mac Awake", isOn: Binding(
                get: { model.isOn },
                set: { desired in
                    if desired != model.isOn { model.toggle() }
                }
            ))
            .disabled(!model.canToggle)
            .keyboardShortcut("k", modifiers: [.command])

            if !model.recoveryComplete {
                Button("Retry Recovery") {
                    model.recover()
                }
                .disabled(!model.canRetryRecovery)
            }

            if model.helperMissing {
                Button("Install Helper…") {
                    model.installHelper()
                }
                .disabled(!model.canInstallHelper)
                Text("Without the helper, changes request administrator authorization.")
            }
            Text("Automatically turns off below 10% on battery.")
            Divider()
            Button("Quit Clam") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            Label(model.hasOperationError ? "Clam Needs Attention" : (model.isOn ? "Clam On" : "Clam Off"),
                  systemImage: model.symbolName)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class ClamAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        if model.mayTerminateImmediately { return .terminateNow }
        model.requestTermination { permitted in
            sender.reply(toApplicationShouldTerminate: permitted)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.willTerminate()
    }
}
#else
import Foundation

@main
struct ClamUnsupportedPlatform {
    static func main() {
        print("Clam's menu-bar app requires macOS 13 or later. ClamCore is available on this platform.")
    }
}
#endif
