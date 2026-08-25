import AppKit

@MainActor
protocol ControlPanelDelegate: AnyObject {
    func controlPanel(_ controller: ControlPanelController, didSelect tool: DestructionTool)
    func controlPanelDidRequestClear(_ controller: ControlPanelController)
    func controlPanelDidRequestQuit(_ controller: ControlPanelController)
}

@MainActor
final class ControlPanelController: NSObject {
    weak var delegate: ControlPanelDelegate?
    let panel: NSPanel

    private var toolButtons: [DestructionTool: NSButton] = [:]
    private let statusLabel = NSTextField(labelWithString: "")

    init(delegate: ControlPanelDelegate, level: NSWindow.Level) {
        self.delegate = delegate
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 876, height: 116),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 15
        effectView.layer?.masksToBounds = true
        panel.contentView = effectView

        let title = NSTextField(labelWithString: "💣 바탕화면 뿌시기")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = .white

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.64)

        let titleStack = NSStackView(views: [title, statusLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 7

        for tool in DestructionTool.allCases {
            let button = NSButton(
                title: "\(tool.symbol) \(tool.title)  \(tool.shortcut)",
                target: self,
                action: #selector(selectTool(_:))
            )
            button.tag = tool.rawValue
            button.bezelStyle = .rounded
            button.setButtonType(.toggle)
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.toolTip = "키보드 \(tool.shortcut)번"
            toolButtons[tool] = button
            buttons.addArrangedSubview(button)
        }

        let clearButton = NSButton(title: "싹 지우기  R", target: self, action: #selector(clearDamage))
        clearButton.bezelStyle = .rounded
        clearButton.font = .systemFont(ofSize: 12, weight: .medium)
        buttons.addArrangedSubview(clearButton)

        let quitButton = NSButton(title: "종료  Esc", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        quitButton.contentTintColor = .systemRed
        quitButton.font = .systemFont(ofSize: 12, weight: .semibold)
        buttons.addArrangedSubview(quitButton)

        let rootStack = NSStackView(views: [titleStack, buttons])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 13
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: effectView.trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 14),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: effectView.bottomAnchor, constant: -14)
        ])

        updateSelectedTool(.hammer)
    }

    func show(on screen: NSScreen?) {
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let panelFrame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - panelFrame.width / 2,
            y: frame.maxY - panelFrame.height - 18
        ))
        panel.orderFrontRegardless()
    }

    func updateSelectedTool(_ tool: DestructionTool) {
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
        }
        statusLabel.stringValue = "선택: \(tool.title)  ·  1~6 무기 전환  ·  우클릭 전체 초기화"
    }

    @objc private func selectTool(_ sender: NSButton) {
        guard let tool = DestructionTool(rawValue: sender.tag) else { return }
        delegate?.controlPanel(self, didSelect: tool)
    }

    @objc private func clearDamage() {
        delegate?.controlPanelDidRequestClear(self)
    }

    @objc private func quit() {
        delegate?.controlPanelDidRequestQuit(self)
    }
}
