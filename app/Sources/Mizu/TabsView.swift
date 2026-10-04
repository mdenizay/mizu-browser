import AppKit

/// One tab in the list: a row in the sidebar, a pill in the top strip, or a
/// bare icon when pinned.
final class TabItemView: NSView {
    /// `icon` is a tab in the narrow sidebar: its icon alone, like a pinned tab.
    enum Style { case row, pill, pinned, icon }

    private var iconOnly: Bool { style == .pinned || style == .icon }

    let tab: Tab
    let style: Style
    private weak var owner: TabsView?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let close = IconButton("xmark", size: 9, tip: L("Close Tab"))
    private var spinner: NSProgressIndicator?
    private var hovering = false { didSet { close.isHidden = !showsClose; needsDisplay = true; needsLayout = true } }
    var selected = false { didSet { needsDisplay = true; close.isHidden = !showsClose; needsLayout = true } }
    /// The colour of the tab's group, drawn as a thin mark.
    var groupColor: NSColor?

    init(tab: Tab, style: Style, owner: TabsView) {
        self.tab = tab
        self.style = style
        self.owner = owner
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.isHidden = iconOnly
        addSubview(label)
        close.isHidden = true
        close.handler = { [weak self] in self.map { $0.tab.manager?.close($0.tab) } }
        addSubview(close)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var showsClose: Bool {
        guard !iconOnly else { return false }
        return hovering || (selected && style == .pill && bounds.width > 90)
    }

    /// A tab squeezed down to its icon in the top strip.
    private var narrow: Bool { style == .pill && bounds.width < 60 }

    func refresh() {
        label.stringValue = tab.displayTitle
        label.textColor = tab.isLoaded || selected ? .labelColor : .secondaryLabelColor
        toolTip = tab.displayTitle
        if tab.isLoading {
            icon.isHidden = true
            if spinner == nil {
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .small
                spinner.isDisplayedWhenStopped = false
                addSubview(spinner)
                spinner.startAnimation(nil)
                self.spinner = spinner
                needsLayout = true
            }
        } else {
            spinner?.removeFromSuperview()
            spinner = nil
            icon.isHidden = false
            if tab.isPlayingAudio {
                icon.image = symbolImage("speaker.wave.2.fill", size: 11)
                icon.contentTintColor = .secondaryLabelColor
            } else if let favicon = tab.favicon {
                icon.image = favicon
                icon.contentTintColor = nil
            } else {
                icon.image = symbolImage(tab.url == nil ? "plus.square.dashed" : "globe", size: 12)
                icon.contentTintColor = .tertiaryLabelColor
            }
            // A sleeping tab is shown a little faded.
            icon.alphaValue = tab.isLoaded || tab.url == nil ? 1 : 0.55
        }
        if narrow { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let iconFrame: NSRect
        if iconOnly {
            iconFrame = NSRect(x: (bounds.width - 16) / 2, y: (bounds.height - 16) / 2, width: 16, height: 16)
        } else {
            iconFrame = NSRect(x: groupColor != nil && style == .row ? 14 : 9, y: (bounds.height - 16) / 2, width: 16, height: 16)
        }
        icon.frame = iconFrame
        spinner?.frame = iconFrame
        let closeWidth: CGFloat = showsClose ? 22 : 0
        close.frame = NSRect(x: bounds.width - 24, y: (bounds.height - 20) / 2, width: 20, height: 20)
        let x = iconFrame.maxX + 8
        label.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: max(bounds.width - x - 6 - closeWidth, 0), height: 16)
        label.isHidden = iconOnly || label.frame.width < 14
        if narrow {
            close.frame = NSRect(x: (bounds.width - 20) / 2, y: (bounds.height - 20) / 2, width: 20, height: 20)
            icon.isHidden = showsClose || tab.isLoading
            spinner?.isHidden = showsClose
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        if selected {
            (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.85)).setFill()
            shape.fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            shape.fill()
        } else if style == .pinned {
            NSColor.labelColor.withAlphaComponent(0.04).setFill()
            shape.fill()
        }
        if let groupColor {
            groupColor.setFill()
            let mark = style == .row ? NSRect(x: 4, y: 7, width: 3, height: bounds.height - 14) : NSRect(x: 8, y: bounds.height - 3, width: bounds.width - 16, height: 2)
            NSBezierPath(roundedRect: mark, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { owner?.track(tab, from: event) }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { tab.manager?.close(tab) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: tab) }
}

/// The header of a tab group: click to fold or unfold it.
final class GroupHeaderView: NSView {
    let group: TabGroup
    private weak var owner: TabsView?
    private let vertical: Bool
    private let count: Int
    /// In the narrow sidebar the header is just a mark in the group's colour.
    var compact = false
    private var hovering = false { didSet { needsDisplay = true } }

    init(group: TabGroup, count: Int, vertical: Bool, owner: TabsView) {
        self.group = group
        self.count = count
        self.vertical = vertical
        self.owner = owner
        super.init(frame: .zero)
        toolTip = group.name
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var title: NSAttributedString {
        NSAttributedString(string: group.name, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: vertical ? NSColor.secondaryLabelColor : NSColor.white,
        ])
    }

    /// The width of the chip in the top strip.
    var chipWidth: CGFloat { min(title.size().width, 120) + (group.collapsed ? 34 : 18) }

    override func draw(_ dirtyRect: NSRect) {
        let color = group.nsColor
        if compact {
            let width: CGFloat = group.collapsed ? 10 : 22
            color.withAlphaComponent(hovering ? 0.7 : 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: (bounds.width - width) / 2, y: (bounds.height - 5) / 2, width: width, height: 5), xRadius: 2.5, yRadius: 2.5).fill()
        } else if vertical {
            if hovering {
                NSColor.labelColor.withAlphaComponent(0.06).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
            }
            let chevron = symbolImage(group.collapsed ? "chevron.right" : "chevron.down", size: 8, weight: .bold)
            if let chevron {
                let tinted = NSImage(size: chevron.size, flipped: false) { rect in
                    chevron.draw(in: rect)
                    color.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 9, y: (bounds.height - chevron.size.height) / 2, width: chevron.size.width, height: chevron.size.height))
            }
            let text = title
            text.draw(with: NSRect(x: 25, y: (bounds.height - text.size().height) / 2, width: bounds.width - 60, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if group.collapsed {
                let number = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor])
                number.draw(at: NSPoint(x: bounds.width - number.size().width - 10, y: (bounds.height - number.size().height) / 2))
            }
        } else {
            let chip = bounds.insetBy(dx: 2, dy: 5)
            color.withAlphaComponent(hovering ? 0.85 : 1).setFill()
            NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
            var text = title
            if group.collapsed {
                let both = NSMutableAttributedString(attributedString: text)
                both.append(NSAttributedString(string: "  \(count)", attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.75)]))
                text = both
            }
            text.draw(with: NSRect(x: chip.minX + 7, y: (bounds.height - text.size().height) / 2, width: chip.width - 12, height: text.size().height),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { owner?.manager?.toggle(group) }
    override func menu(for event: NSEvent) -> NSMenu? { owner?.menu(for: group) }
}

/// The "New Tab" row at the end of the sidebar's list.
private final class NewTabRow: NSView {
    var handler: (() -> Void)?
    var compact = false
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        if let plus = symbolImage("plus", size: 11, weight: .medium) {
            let tinted = NSImage(size: plus.size, flipped: false) { rect in
                plus.draw(in: rect)
                NSColor.secondaryLabelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: compact ? (bounds.width - plus.size.width) / 2 : 11, y: (bounds.height - plus.size.height) / 2, width: plus.size.width, height: plus.size.height))
        }
        if compact { return }
        let text = NSAttributedString(string: L("New Tab"), attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.secondaryLabelColor])
        text.draw(at: NSPoint(x: 33, y: (bounds.height - text.size().height) / 2))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { handler?() }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// The tinted panel behind a group in the sidebar, which shows where the
/// group ends.
private final class GroupBackdrop: NSView {
    init(color: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = color.withAlphaComponent(0.10).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The list of tabs: a column in the sidebar or a strip along the top.
final class TabsView: NSView {
    weak var manager: TabManager?
    var vertical = true { didSet { if vertical != oldValue { configureScroller(); reload() } } }
    /// The narrow sidebar: icons only.
    var compact = false { didSet { if compact != oldValue { reload() } } }
    private var rail: Bool { vertical && compact }
    /// The address bar, when it lives in the strip (the compact top bar):
    /// it takes the place of the selected tab's title, as in Safari.
    var embedded: NSView? {
        didSet {
            guard embedded !== oldValue else { return }
            if oldValue?.superview === document { oldValue?.removeFromSuperview() }
            if let embedded { document.addSubview(embedded) }
            needsLayout = true
        }
    }

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private var tabViews: [TabItemView] = []
    private var headers: [GroupHeaderView] = []
    private var newTabRow: NewTabRow?
    private var backdrops: [UUID: GroupBackdrop] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroll.drawsBackground = false
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = document
        scroll.scrollerStyle = .overlay
        // The strip sits under the (transparent) title bar; no inset for it.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .allowed
        addSubview(scroll)
        configureScroller()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func configureScroller() {
        scroll.hasVerticalScroller = vertical
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = vertical ? .none : .allowed
    }

    /// Rebuilds the list from the manager's tabs.
    func reload() {
        guard let manager else { return }
        document.subviews.filter { $0 !== embedded }.forEach { $0.removeFromSuperview() }
        tabViews = []
        headers = []
        newTabRow = nil
        backdrops = [:]
        for tab in manager.pinned {
            add(TabItemView(tab: tab, style: .pinned, owner: self), selected: manager.selected)
        }
        for item in manager.items {
            switch item {
            case let .group(group, count):
                if vertical, !compact {
                    let backdrop = GroupBackdrop(color: group.nsColor)
                    backdrops[group.id] = backdrop
                    document.addSubview(backdrop)
                }
                let header = GroupHeaderView(group: group, count: count, vertical: vertical, owner: self)
                header.compact = rail
                headers.append(header)
                document.addSubview(header)
            case let .tab(tab):
                let view = TabItemView(tab: tab, style: rail ? .icon : (vertical ? .row : .pill), owner: self)
                view.groupColor = manager.group(tab.groupID)?.nsColor
                add(view, selected: manager.selected)
            }
        }
        if vertical {
            let row = NewTabRow()
            row.compact = rail
            row.toolTip = L("New Tab")
            row.handler = { [weak self] in self?.manager?.window?.newTab(nil) }
            document.addSubview(row)
            newTabRow = row
        }
        needsLayout = true
    }

    private func add(_ view: TabItemView, selected: Tab?) {
        view.selected = view.tab === selected
        tabViews.append(view)
        document.addSubview(view)
    }

    func update(_ tab: Tab) {
        tabViews.first { $0.tab === tab }?.refresh()
    }

    func selectionChanged() {
        guard let manager else { return }
        // A folded group opens when one of its tabs is picked, so the rows may differ.
        if !tabViews.contains(where: { $0.tab === manager.selected }) { return reload() }
        for view in tabViews {
            view.selected = view.tab === manager.selected
            view.refresh()
        }
        if let view = tabViews.first(where: \.selected) { view.scrollToVisible(view.bounds) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        if rail { layoutRail() } else if vertical { layoutColumn() } else { layoutStrip() }
    }

    private func layoutColumn() {
        let pad: CGFloat = 10, width = bounds.width - pad * 2
        var y: CGFloat = 2
        let pinned = tabViews.filter { $0.style == .pinned }
        if !pinned.isEmpty {
            let perRow = max(min(Int(width / 44), pinned.count), 1), gap: CGFloat = 6
            let cell = (width - gap * CGFloat(perRow - 1)) / CGFloat(perRow)
            for (index, view) in pinned.enumerated() {
                view.frame = NSRect(x: pad + CGFloat(index % perRow) * (cell + gap), y: y + CGFloat(index / perRow) * 40, width: cell, height: 34)
            }
            y += CGFloat((pinned.count - 1) / perRow + 1) * 40 + 6
        }
        // Rows in the order they were added: headers and tabs interleaved.
        var open: (id: UUID, top: CGFloat)?
        let closeGroup = {
            guard let group = open else { return }
            self.backdrops[group.id]?.frame = NSRect(x: pad - 4, y: group.top, width: width + 8, height: y - group.top + 2)
            y += 8
            open = nil
        }
        for view in document.subviews where !(view is NewTabRow) && !(view is GroupBackdrop) && (view as? TabItemView)?.style != .pinned {
            if let header = view as? GroupHeaderView {
                closeGroup()
                y += 4
                open = (header.group.id, y - 2)
            } else if (view as? TabItemView)?.tab.groupID == nil {
                closeGroup()
            }
            let height: CGFloat = view is GroupHeaderView ? 26 : 32
            view.frame = NSRect(x: pad, y: y, width: width, height: height)
            y += height + 2
        }
        closeGroup()
        newTabRow?.frame = NSRect(x: pad, y: y + 2, width: width, height: 32)
        y += 40
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    /// The narrow sidebar: one icon per row, a coloured mark before each group.
    private func layoutRail() {
        let pad: CGFloat = 8, width = bounds.width - pad * 2
        var y: CGFloat = 2
        var afterPinned = false
        for view in document.subviews {
            if let header = view as? GroupHeaderView {
                header.frame = NSRect(x: pad, y: y + 2, width: width, height: 12)
                y += 16
            } else if let item = view as? TabItemView {
                // A little air between the pinned tabs and the rest.
                if item.style == .pinned { afterPinned = true } else if afterPinned { y += 6; afterPinned = false }
                item.frame = NSRect(x: pad, y: y, width: width, height: 34)
                y += 37
            }
        }
        newTabRow?.frame = NSRect(x: pad, y: y + 2, width: width, height: 34)
        y += 42
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(y, bounds.height))
    }

    private func layoutStrip() {
        let height = bounds.height, gap: CGFloat = 3
        let pinned = tabViews.filter { $0.style == .pinned }
        let pills = tabViews.filter { $0.style == .pill }
        let fixed = CGFloat(pinned.count) * (34 + gap) + headers.reduce(0) { $0 + $1.chipWidth + gap }
        var each: CGFloat = 0, addressWidth: CGFloat = 0
        if embedded != nil {
            // The selected tab shrinks to its icon and the address bar follows
            // it; the other tabs share what is left.
            let others = pills.filter { !$0.selected }
            let room = bounds.width - fixed - (pills.count > others.count ? 34 + gap : 0)
            let wanted = min(max(room * 0.5, 280), 620)
            each = others.isEmpty ? 0 : min(max((room - wanted - gap) / CGFloat(others.count) - gap, 34), 170)
            addressWidth = min(max(room - CGFloat(others.count) * (each + gap) - gap, 280), 620)
        } else {
            each = pills.isEmpty ? 0 : min(max((bounds.width - fixed) / CGFloat(pills.count) - gap, 44), 200)
        }
        var x: CGFloat = 0
        for view in document.subviews where view !== embedded {
            let width: CGFloat
            let item = view as? TabItemView
            if let header = view as? GroupHeaderView { width = header.chipWidth }
            else if item?.style == .pinned { width = 34 }
            else if embedded != nil, item?.selected == true { width = 34 }
            else { width = each }
            view.frame = NSRect(x: x, y: 4, width: width, height: height - 8)
            x += width + gap
            if let embedded, item?.selected == true {
                embedded.frame = NSRect(x: x, y: 2, width: addressWidth, height: height - 4)
                x += addressWidth + gap
            }
        }
        document.frame = NSRect(x: 0, y: 0, width: max(x, bounds.width), height: height)
    }

    // MARK: Dragging

    /// Follows a press on a tab: selects it, and if the pointer then moves,
    /// carries the tab along the list.
    func track(_ tab: Tab, from event: NSEvent) {
        guard let manager, let window else { return }
        manager.select(tab)
        let start = event.locationInWindow
        var dragging = false
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { break }
            let location = next.locationInWindow
            if !dragging, hypot(location.x - start.x, location.y - start.y) < 6 { continue }
            dragging = true
            let point = document.convert(location, from: nil)
            let candidates = tabViews.filter { $0.tab.pinned == tab.pinned }
            guard let own = candidates.firstIndex(where: { $0.tab === tab }) else { continue }
            let hit: (TabItemView) -> Bool = { view in
                if tab.pinned { return view.frame.contains(point) }
                return self.vertical ? (view.frame.minY...view.frame.maxY).contains(point.y) : (view.frame.minX...view.frame.maxX).contains(point.x)
            }
            guard let target = candidates.firstIndex(where: hit), target != own else { continue }
            if target > own {
                manager.move(tab, before: target + 1 < candidates.count ? candidates[target + 1].tab : nil)
            } else {
                manager.move(tab, before: candidates[target].tab)
            }
            layoutSubtreeIfNeeded()
        }
    }

    // MARK: Menus

    func menu(for tab: Tab) -> NSMenu? {
        guard let manager else { return nil }
        let menu = NSMenu()
        menu.add(L("Reload"), symbol: "arrow.clockwise") { tab.load(); tab.reload() }
        menu.add(L("Duplicate"), symbol: "plus.square.on.square") { manager.duplicate(tab) }
        menu.add(tab.pinned ? L("Unpin") : L("Pin"), symbol: tab.pinned ? "pin.slash" : "pin") { manager.setPinned(tab, !tab.pinned) }
        menu.separator()
        menu.addSubmenu(L("Add to Group"), symbol: "square.stack") { sub in
            sub.add(L("New Group…")) { [weak self] in
                promptForText(title: L("Name the group"), value: tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "", in: self?.window) {
                    manager.makeGroup(with: tab, name: $0)
                }
            }
            if !manager.visibleGroups.isEmpty { sub.separator() }
            for group in manager.visibleGroups {
                sub.add(group.name, checked: tab.groupID == group.id) { manager.add(tab, to: group) }
            }
        }
        if tab.groupID != nil {
            menu.add(L("Remove from Group"), symbol: "square.stack.3d.up.slash") { manager.add(tab, to: nil) }
        }
        let others = Profiles.shared.all.filter { $0 !== tab.profile }
        if !tab.profile.isPrivate, !others.isEmpty, let url = tab.url {
            menu.addSubmenu(L("Open in Profile"), symbol: "person.2") { sub in
                for profile in others {
                    sub.add(profile.name, symbol: profile.symbol) {
                        manager.switchProfile(profile)
                        manager.newTab(url: url)
                    }
                }
            }
        }
        menu.separator()
        if tab.isLoaded, tab !== manager.selected {
            menu.add(L("Put to Sleep"), symbol: "moon.zzz") {
                tab.sleep()
                manager.tabUpdated(tab)
            }
        }
        if let url = tab.url {
            menu.add(L("Copy Link"), symbol: "link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        menu.separator()
        menu.add(L("Close Tab"), symbol: "xmark") { manager.close(tab) }
        menu.add(L("Close Other Tabs"), enabled: manager.visible.count > 1) { manager.closeOthers(tab) }
        return menu
    }

    func menu(for group: TabGroup) -> NSMenu? {
        guard let manager else { return nil }
        let menu = NSMenu()
        menu.add(L("Rename…"), symbol: "pencil") { [weak self] in
            promptForText(title: L("Name the group"), value: group.name, in: self?.window) {
                group.name = $0
                manager.groupChanged()
            }
        }
        menu.addSubmenu(L("Colour"), symbol: "paintpalette") { sub in
            for (index, color) in TabGroup.colors.enumerated() {
                let item = sub.add(L(color.name), checked: group.color == index) {
                    group.color = index
                    manager.groupChanged()
                }
                item.image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    NSColor(hex: color.hex).setFill()
                    NSBezierPath(ovalIn: rect).fill()
                    return true
                }
            }
        }
        menu.separator()
        menu.add(L("Ungroup"), symbol: "square.stack.3d.up.slash") { manager.ungroup(group) }
        menu.add(L("Close Group"), symbol: "xmark") { manager.close(group) }
        return menu
    }
}
