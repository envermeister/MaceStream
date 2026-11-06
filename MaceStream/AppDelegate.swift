import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var environment: AppEnvironment?
    private var isTerminating = false
    private var keyboardMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSWindow.allowsAutomaticWindowTabbing = false
        installKeyboardMonitor()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if NSClassFromString("XCTestCase") != nil { return .terminateNow }
        guard let environment = AppDelegate.environment, !isTerminating else {
            return isTerminating ? .terminateLater : .terminateNow
        }
        isTerminating = true
        Task { @MainActor in
            await environment.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
        }
    }

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let environment = AppDelegate.environment,
                  event.window === environment.playerWindow,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !Self.isEditingText(event) else {
                return event
            }

            switch event.keyCode {
            case 49 where environment.playback.hasActiveStream && !Self.isControlFocused(event): // Space
                environment.playback.togglePlayPause()
                return nil
            case 46 where environment.playback.hasActiveStream: // M
                environment.playback.toggleMute()
                return nil
            case 3: // F
                environment.toggleFullScreen()
                return nil
            default:
                return event
            }
        }
    }

    private static func isEditingText(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder as? NSTextView else { return false }
        return responder.isEditable
    }

    private static func isControlFocused(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        return responder is NSControl || responder is NSTableView
    }
}
