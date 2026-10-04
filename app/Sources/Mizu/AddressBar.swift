import AppKit

struct Suggestion {
    let title: String
    let detail: String
    let symbol: String
    let icon: NSImage?
    /// What choosing the suggestion opens.
    let input: String
}

/// Turns what was typed into an address: a URL when it looks like one, a
/// search otherwise.
enum Resolver {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "file", "about", "data", "blob"].contains(scheme) {
            return url
        }
        if looksLikeHost(text), let url = URL(string: (isLocal(text) ? "http://" : "https://") + text) { return url }
        return search(text)
    }

    static func search(_ text: String) -> URL? {
        let query = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
        return URL(string: String(format: Prefs.shared.engine.template, query))
    }

    private static func isLocal(_ text: String) -> Bool {
        let host = text.split(separator: "/").first.map(String.init)?.split(separator: ":").first.map(String.init) ?? text
        return host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".test") || host.hasSuffix(".localhost")
            || host.range(of: #"^(\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil
    }

    static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        if isLocal(text) { return true }
        let host = text.split(separator: "/").first.map(String.init)?.split(separator: ":").first.map(String.init) ?? text
        guard let dot = host.lastIndex(of: "."), dot != host.startIndex else { return false }
        let ending = host[host.index(after: dot)...]
        return ending.count >= 2 && ending.allSatisfy(\.isLetter) && host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}

private final class AddressField: NSTextField {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

private final class SuggestionRow: NSView {
    let suggestion: Suggestion
    var chosen = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    init(_ suggestion: Suggestion) {
        self.suggestion = suggestion
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
        }
        let primary = chosen ? NSColor.white : NSColor.labelColor
        let secondary = chosen ? NSColor.white.withAlphaComponent(0.75) : NSColor.secondaryLabelColor
        let iconRect = NSRect(x: 16, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if let icon = suggestion.icon {
            icon.draw(in: iconRect)
        } else if let symbol = symbolImage(suggestion.symbol, size: 12) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                secondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: iconRect.midX - symbol.size.width / 2, y: iconRect.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        }
        let text = NSMutableAttributedString(string: suggestion.title, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: primary])
        if !suggestion.detail.isEmpty {
            text.append(NSAttributedString(string: "  —  " + suggestion.detail, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary]))
        }
        text.draw(with: NSRect(x: 42, y: (bounds.height - 16) / 2, width: bounds.width - 56, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The address and search field, with the page's controls (blocker shield,
/// bookmark star, password key) at its trailing edge and suggestions below.
final class AddressBar: NSView, NSTextFieldDelegate {
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    /// Suggestions for what has been typed.
    var suggest: ((String) -> [Suggestion])?

    private let field = AddressField()
    private let lead = NSImageView()
    let shield = IconButton("shield.lefthalf.filled", size: 12, tip: L("Ad Blocker"))
    let star = IconButton("star", size: 12, tip: L("Bookmark This Page"))
    let key = IconButton("key.fill", size: 11, tip: L("Fill a Password"))

    /// Production, staging or development: shown as a label before the address.
    var environment: SiteEnvironment? { didSet { if environment != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The menu behind that label, to mark the site as something else.
    var environmentMenu: (() -> NSMenu)?

    private var url: URL?
    private var editing = false

    private var badge: (text: NSAttributedString, frame: NSRect)? {
        guard let environment, url != nil else { return nil }
        let text = NSAttributedString(string: environment.label, attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white, .kern: 0.4])
        return (text, NSRect(x: 28, y: (bounds.height - 15) / 2, width: text.size().width + 10, height: 15))
    }
    private var panel: NSPanel?
    private var rows: [SuggestionRow] = []
    private var chosen = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = L("Search or enter address")
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.onFocus = { [weak self] in self?.beganEditing() }
        addSubview(field)
        lead.imageScaling = .scaleNone
        addSubview(lead)
        key.isHidden = true
        for button in [shield, star, key] { addSubview(button) }
        show(url: nil, secure: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let badge, badge.frame.contains(convert(event.locationInWindow, from: nil)), let menu = environmentMenu?() {
            menu.popUp(positioning: nil, at: NSPoint(x: badge.frame.minX, y: bounds.height + 4), in: self)
            return
        }
        focus()
    }

    func focus() {
        window?.makeFirstResponder(field)
    }

    var isEditing: Bool { editing }

    /// Shows the address of the page in front (unless one is being typed).
    func show(url: URL?, secure: Bool) {
        self.url = url
        let web = url?.scheme?.hasPrefix("http") == true
        lead.image = symbolImage(url == nil ? "magnifyingglass" : (secure ? "lock.fill" : (web ? "exclamationmark.triangle.fill" : "doc")), size: 10.5, weight: .medium)
        lead.contentTintColor = url != nil && web && !secure ? .systemOrange : .tertiaryLabelColor
        shield.isHidden = !web
        star.isHidden = !web
        if !editing { field.stringValue = Self.pretty(url) }
        needsLayout = true
    }

    /// The address as shown at rest: no scheme, no "www.", no trailing slash.
    static func pretty(_ url: URL?) -> String {
        guard let url else { return "" }
        guard url.scheme?.hasPrefix("http") == true else { return url.absoluteString }
        var text = url.absoluteString.replacingOccurrences(of: "^https?://(www\\.)?", with: "", options: .regularExpression)
        if text.hasSuffix("/") { text.removeLast() }
        return text.removingPercentEncoding ?? text
    }

    override func layout() {
        super.layout()
        lead.frame = NSRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16)
        var right = bounds.width - 4
        for button in [shield, star, key] where !button.isHidden {
            button.frame = NSRect(x: right - 26, y: (bounds.height - 26) / 2, width: 26, height: 26)
            right -= 26
        }
        let left = badge.map { $0.frame.maxX + 5 } ?? 30
        field.frame = NSRect(x: left, y: (bounds.height - 18) / 2, width: max(right - left - 4, 20), height: 18)
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        if editing {
            (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.white.withAlphaComponent(0.9)).setFill()
            shape.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 1.5
            shape.stroke()
        } else {
            NSColor.labelColor.withAlphaComponent(dark ? 0.09 : 0.06).setFill()
            shape.fill()
        }
        if let badge, let environment {
            environment.color.setFill()
            NSBezierPath(roundedRect: badge.frame, xRadius: 4, yRadius: 4).fill()
            badge.text.draw(at: NSPoint(x: badge.frame.minX + 5, y: badge.frame.minY + (badge.frame.height - badge.text.size().height) / 2))
        }
    }

    // MARK: Editing

    private func beganEditing() {
        guard !editing else { return }
        editing = true
        field.stringValue = url?.absoluteString ?? ""
        needsDisplay = true
        // Select once the field editor is in place.
        DispatchQueue.main.async { [self] in field.currentEditor()?.selectAll(nil) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        editing = false
        hideSuggestions()
        field.stringValue = Self.pretty(url)
        needsDisplay = true
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = field.stringValue
        showSuggestions(text.isEmpty ? [] : suggest?(text) ?? [])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let input = chosen >= 0 && chosen < rows.count ? rows[chosen].suggestion.input : field.stringValue
            submit(input)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if panel != nil { hideSuggestions() } else { onCancel?() }
            return true
        case #selector(NSResponder.moveDown(_:)) where !rows.isEmpty:
            choose(chosen + 1 >= rows.count ? 0 : chosen + 1)
            return true
        case #selector(NSResponder.moveUp(_:)) where !rows.isEmpty:
            choose(chosen <= 0 ? rows.count - 1 : chosen - 1)
            return true
        default:
            return false
        }
    }

    private func submit(_ input: String) {
        hideSuggestions()
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSubmit?(input)
    }

    // MARK: Suggestions

    private func choose(_ index: Int) {
        chosen = index
        for (i, row) in rows.enumerated() { row.chosen = i == index }
    }

    private func showSuggestions(_ suggestions: [Suggestion]) {
        guard !suggestions.isEmpty, let window else { return hideSuggestions() }
        let rowHeight: CGFloat = 32
        let width = max(bounds.width, 380)
        let height = CGFloat(suggestions.count) * rowHeight + 10
        let panel = self.panel ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            let effect = NSVisualEffectView()
            effect.material = .popover
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 11
            effect.layer?.masksToBounds = true
            panel.contentView = effect
            window.addChildWindow(panel, ordered: .above)
            self.panel = panel
            return panel
        }()
        let origin = window.convertPoint(toScreen: convert(NSPoint(x: 0, y: bounds.height + 5), to: nil))
        panel.setFrame(NSRect(x: origin.x, y: origin.y - height, width: width, height: height), display: false)
        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        rows = suggestions.enumerated().map { index, suggestion in
            let row = SuggestionRow(suggestion)
            row.frame = NSRect(x: 0, y: height - 5 - CGFloat(index + 1) * rowHeight, width: width, height: rowHeight)
            row.onClick = { [weak self] in self?.submit(suggestion.input) }
            panel.contentView?.addSubview(row)
            return row
        }
        chosen = -1
        panel.orderFront(nil)
    }

    private func hideSuggestions() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
        rows = []
        chosen = -1
    }
}
