import AppKit

/// A view whose origin is at the top left, as the layout code here assumes.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if !enabled { action = nil }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, symbol: String? = nil, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title, symbol: symbol, checked: checked, enabled: enabled, handler)
        addItem(item)
        return item
    }

    @discardableResult
    func addSubmenu(_ title: String, symbol: String? = nil, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        let menu = NSMenu(title: title)
        build(menu)
        item.submenu = menu
        addItem(item)
        return item
    }

    func separator() { addItem(.separator()) }
}

/// A borderless symbol button that lights up under the pointer.
final class IconButton: NSControl {
    var handler: (() -> Void)?
    /// When set, a click opens this menu instead of running the handler.
    var menuProvider: (() -> NSMenu)?
    var symbol: String { didSet { needsDisplay = true } }
    var pointSize: CGFloat
    var tint: NSColor? { didSet { needsDisplay = true } }
    /// A small count drawn at the corner (the blocker's tally).
    var badge: String? { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(_ symbol: String, size: CGFloat = 13, tip: String, handler: (() -> Void)? = nil) {
        self.symbol = symbol
        pointSize = size
        self.handler = handler
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        toolTip = tip
        setAccessibilityLabel(tip)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if let menuProvider {
            pressed = true
            // Below the button; from the bottom of the window, above it.
            let menu = menuProvider()
            let low = (window.map { convert(bounds, to: nil).minY < 120 && $0.frame.height > 300 }) ?? false
            menu.popUp(positioning: low ? menu.items.last : nil, at: low ? NSPoint(x: bounds.width + 4, y: 4) : NSPoint(x: 0, y: -4), in: self)
            pressed = false
            hovering = false
            return
        }
        pressed = true
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { handler?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isEnabled, hovering || pressed {
            NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let color = (tint ?? .secondaryLabelColor).withAlphaComponent(isEnabled ? 1 : 0.35)
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2)
        tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        if let badge {
            let text = NSAttributedString(string: badge, attributes: [.font: NSFont.systemFont(ofSize: 8, weight: .bold), .foregroundColor: NSColor.white])
            let size = text.size()
            let pill = NSRect(x: bounds.width - size.width - 7, y: isFlipped ? bounds.height - 12 : 1, width: size.width + 6, height: 11)
            (tint ?? NSColor.controlAccentColor).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 5.5, yRadius: 5.5).fill()
            text.draw(at: NSPoint(x: pill.minX + 3, y: pill.minY + 0.5))
        }
    }
}

/// The window's backdrop: the system's translucent material, washed with the
/// colours of the profile in front.
final class ThemeBackgroundView: NSView {
    private let effect = NSVisualEffectView()
    private let tint = NSView()
    private let gradient = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)
        tint.wantsLayer = true
        tint.layer = gradient
        tint.autoresizingMask = [.width, .height]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        addSubview(tint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        effect.frame = bounds
        tint.frame = bounds
    }

    func apply(_ profile: Profile) {
        let first = NSColor(hex: profile.color1)
        let second = profile.color2 >= 0 ? NSColor(hex: profile.color2) : first
        let alpha = CGFloat(profile.intensity)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        gradient.colors = [first.withAlphaComponent(alpha).cgColor,
                           second.withAlphaComponent(profile.color2 >= 0 ? alpha : alpha * 0.4).cgColor]
        CATransaction.commit()
    }
}

func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// Asks for a line of text in a sheet-like alert.
func promptForText(title: String, value: String = "", placeholder: String = "", in window: NSWindow?, completion: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    field.stringValue = value
    field.placeholderString = placeholder
    alert.accessoryView = field
    alert.addButton(withTitle: L("OK"))
    alert.addButton(withTitle: L("Cancel"))
    alert.window.initialFirstResponder = field
    let done: (NSApplication.ModalResponse) -> Void = { response in
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if response == .alertFirstButtonReturn, !text.isEmpty { completion(text) }
    }
    if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
}
