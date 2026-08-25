import AppKit
import CoreGraphics

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ControlPanelDelegate {
    private let soundEngine = SoundEngine()
    private var overlayWindows: [OverlayWindow] = []
    private var destructionViews: [DestructionView] = []
    private var controlPanel: ControlPanelController?
    private var keyMonitor: Any?
    private var selectedTool: DestructionTool = .hammer

    private var overlayLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildOverlays()

        if ProcessInfo.processInfo.arguments.contains("--verification-demo") {
            soundEngine.isMuted = true
            destructionViews.forEach { $0.renderVerificationDemo() }
        }

        let panel = ControlPanelController(
            delegate: self,
            level: NSWindow.Level(rawValue: overlayLevel.rawValue + 2)
        )
        controlPanel = panel
        panel.show(on: NSScreen.main)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        NSApp.activate(ignoringOtherApps: true)
        overlayWindows.first?.makeKey()
        panel.panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        destructionViews.forEach { $0.stopContinuousAction() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func buildOverlays() {
        overlayWindows.forEach { $0.close() }
        overlayWindows.removeAll()
        destructionViews.removeAll()

        for screen in NSScreen.screens {
            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.setFrame(screen.frame, display: false)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = overlayLevel
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

            let view = DestructionView(frame: NSRect(origin: .zero, size: screen.frame.size), soundEngine: soundEngine)
            view.autoresizingMask = [.width, .height]
            view.selectedTool = selectedTool
            window.contentView = view
            window.orderFrontRegardless()

            overlayWindows.append(window)
            destructionViews.append(view)
        }
    }

    @objc private func screenParametersDidChange() {
        buildOverlays()
        controlPanel?.show(on: NSScreen.main)
        overlayWindows.first?.makeKey()
        controlPanel?.panel.orderFrontRegardless()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1":
            select(.hammer)
        case "2":
            select(.machineGun)
        case "3":
            select(.flamethrower)
        case "4":
            select(.bomb)
        case "5":
            select(.chainsaw)
        case "6":
            select(.lightning)
        case "r", "c":
            clearAllDamage()
        default:
            if event.keyCode == 53 {
                NSApp.terminate(nil)
            } else {
                return false
            }
        }
        return true
    }

    private func select(_ tool: DestructionTool) {
        selectedTool = tool
        destructionViews.forEach { $0.selectedTool = tool }
        controlPanel?.updateSelectedTool(tool)
        overlayWindows.first?.makeKey()
        controlPanel?.panel.orderFrontRegardless()
    }

    private func clearAllDamage() {
        destructionViews.forEach { $0.clearDamage() }
        overlayWindows.first?.makeKey()
        controlPanel?.panel.orderFrontRegardless()
    }

    func controlPanel(_ controller: ControlPanelController, didSelect tool: DestructionTool) {
        select(tool)
    }

    func controlPanelDidRequestClear(_ controller: ControlPanelController) {
        clearAllDamage()
    }

    func controlPanelDidRequestQuit(_ controller: ControlPanelController) {
        NSApp.terminate(nil)
    }
}
