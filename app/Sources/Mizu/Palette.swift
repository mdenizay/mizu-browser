import AppKit

/// Something the palette offers: a page, a tab, a command, a profile.
struct PaletteItem {
    let title: String
    var detail = ""
    var symbol = "globe"
    var icon: NSImage?
    /// Shown at the trailing edge: a shortcut, or what kind of thing this is.
    var hint = ""
    let run: () -> Void
}

private final class PaletteRow: NSView {
    let item: PaletteItem
    var chosen = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onHover: (() -> Void)?

    init(_ item: PaletteItem) {
        self.item = item
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if chosen {
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        let primary = chosen ? NSColor.white : NSColor.labelColor
        let secondary = chosen ? NSColor.white.withAlphaComponent(0.75) : NSColor.secondaryLabelColor
        let iconRect = NSRect(x: 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
        if let icon = item.icon {
            icon.draw(in: iconRect)
        } else if let symbol = symbolImage(item.symbol, size: 13) {
            let tinted = NSImage(size: symbol.size, flipped: false) { rect in
                symbol.draw(in: rect)
                secondary.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: iconRect.midX - symbol.size.width / 2, y: iconRect.midY - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height))
        }
        var right = bounds.width - 22
        if !item.hint.isEmpty {
            let hint = NSAttributedString(string: item.hint, attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: secondary])
            right -= hint.size().width
            hint.draw(at: NSPoint(x: right, y: (bounds.height - hint.size().height) / 2))
            right -= 12
        }
        let text = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: primary])
        if !item.detail.isEmpty {
            text.append(NSAttributedString(string: "   " + item.detail, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: secondary]))
        }
        text.draw(with: NSRect(x: 50, y: (bounds.height - 18) / 2, width: right - 50, height: 20), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onHover?() }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// The panel that drops into the middle of the window: type to open a page
/// in a new tab (⌘T), to run a command (⌘K) or to switch profile (⇧⌘P).
final class Palette: NSView, NSTextFieldDelegate {
    /// What to offer for the text typed so far.
    var provider: ((String) -> [PaletteItem])?
    var onDismiss: (() -> Void)?

    private let panel = NSVisualEffectView()
    private let field = NSTextField()
    private let glyph = NSImageView()
    private let line = NSBox()
    private let list = FlippedView()
    private var rows: [PaletteRow] = []
    private var chosen = 0
    private static let rowHeight: CGFloat = 36, width: CGFloat = 640, fieldHeight: CGFloat = 52

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        panel.material = .popover
        panel.state = .active
        panel.blendingMode = .withinWindow
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 14
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()
        addSubview(panel)
        glyph.contentTintColor = .secondaryLabelColor
        panel.addSubview(glyph)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 19)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        panel.addSubview(field)
        line.boxType = .separator
        panel.addSubview(line)
        panel.addSubview(list)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A click outside the panel puts it away.
    override func mouseDown(with event: NSEvent) {
        if !panel.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }

    func present(placeholder: String, symbol: String, text: String = "") {
        field.placeholderString = placeholder
        field.stringValue = text
        glyph.image = symbolImage(symbol, size: 16, weight: .medium)
        isHidden = false
        reload()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func dismiss() {
        guard !isHidden else { return }
        isHidden = true
        rows = []
        list.subviews.forEach { $0.removeFromSuperview() }
        onDismiss?()
    }

    private func reload() {
        list.subviews.forEach { $0.removeFromSuperview() }
        let items = Array((provider?(field.stringValue) ?? []).prefix(9))
        rows = items.enumerated().map { index, item in
            let row = PaletteRow(item)
            row.onClick = { [weak self] in self?.run(index) }
            row.onHover = { [weak self] in self?.choose(index) }
            list.addSubview(row)
            return row
        }
        choose(0)
        needsLayout = true
    }

    private func choose(_ index: Int) {
        chosen = index
        for (i, row) in rows.enumerated() where row.chosen != (i == index) { row.chosen = i == index }
    }

    private func run(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        let item = rows[index].item
        dismiss()
        item.run()
    }

    override func layout() {
        super.layout()
        let width = min(Self.width, bounds.width - 40)
        let listHeight = rows.isEmpty ? 0 : CGFloat(rows.count) * Self.rowHeight + 12
        panel.frame = NSRect(x: ((bounds.width - width) / 2).rounded(), y: max((bounds.height * 0.2).rounded(), 60), width: width, height: Self.fieldHeight + listHeight)
        glyph.frame = NSRect(x: 20, y: (Self.fieldHeight - 20) / 2, width: 20, height: 20)
        field.frame = NSRect(x: 50, y: (Self.fieldHeight - 26) / 2, width: width - 70, height: 26)
        // The effect view is not flipped: its children are placed from the bottom.
        glyph.frame.origin.y = panel.bounds.height - Self.fieldHeight + (Self.fieldHeight - 20) / 2
        field.frame.origin.y = panel.bounds.height - Self.fieldHeight + (Self.fieldHeight - 26) / 2
        line.frame = NSRect(x: 0, y: listHeight, width: width, height: 1)
        line.isHidden = rows.isEmpty
        list.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: 6 + CGFloat(index) * Self.rowHeight, width: width, height: Self.rowHeight)
        }
        layer?.shadowPath = nil
    }

    func controlTextDidChange(_ notification: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            run(chosen)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismiss()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            if !rows.isEmpty { choose((chosen + 1) % rows.count) }
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            if !rows.isEmpty { choose((chosen - 1 + rows.count) % rows.count) }
            return true
        default:
            return false
        }
    }

    /// Losing the keyboard (a click elsewhere, another window) closes it.
    func controlTextDidEndEditing(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isHidden, self.window?.firstResponder !== self.field.currentEditor() else { return }
            self.dismiss()
        }
    }

    /// True when each word typed appears somewhere in the text.
    static func matches(_ text: String, _ query: String) -> Bool {
        let haystack = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(separator: " ").allSatisfy { haystack.contains($0) }
    }
}
