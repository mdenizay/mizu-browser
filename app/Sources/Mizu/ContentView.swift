import AppKit
import SwiftUI
import WebKit

/// What the start page shows.
final class StartModel: ObservableObject {
    @Published var bookmarks: [BookmarkRow] = []
    @Published var accent = Color.accentColor
    @Published var isPrivate = false
    var open: (URL) -> Void = { _ in }
    var focus: () -> Void = {}
}

/// The page of an empty tab: a way into the address bar and the bookmarks.
struct StartPage: View {
    @ObservedObject var model: StartModel

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: model.isPrivate ? "eyeglasses" : "drop.fill")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(model.accent.gradient)
            Button(action: model.focus) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                    Text(L("Search or enter address"))
                    Spacer()
                    Text("⌘L").font(.system(size: 11, weight: .medium)).opacity(0.6)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .frame(width: 420, height: 40)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            if model.isPrivate {
                Text(L("Private window: history, cookies and site data are forgotten when it closes."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if !model.bookmarks.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 10), count: 4), spacing: 10) {
                    ForEach(model.bookmarks.prefix(12)) { bookmark in
                        Button {
                            if let url = URL(string: bookmark.url) { model.open(url) }
                        } label: {
                            VStack(spacing: 7) {
                                Group {
                                    if let host = URL(string: bookmark.url)?.host, let icon = Favicons.shared.cached(host) {
                                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                                    } else {
                                        Image(systemName: "globe").font(.system(size: 17)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Text(bookmark.title.isEmpty ? bookmark.url : bookmark.title)
                                    .font(.system(size: 11)).lineLimit(1).foregroundStyle(.secondary)
                            }
                            .frame(width: 96)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(width: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(y: -40)
    }
}

/// The find-in-page field that drops in at the top right of the page.
final class FindBar: NSView, NSTextFieldDelegate {
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?
    private let field = NSTextField()
    private let previous = IconButton("chevron.up", size: 11, tip: L("Previous"))
    private let next = IconButton("chevron.down", size: 11, tip: L("Next"))
    private let done = IconButton("xmark", size: 10, tip: L("Close"))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        shadow = NSShadow()
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        field.placeholderString = L("Find in page")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        addSubview(field)
        previous.handler = { [weak self] in self?.search(backwards: true) }
        next.handler = { [weak self] in self?.search(backwards: false) }
        done.handler = { [weak self] in self?.onClose?() }
        for button in [previous, next, done] { addSubview(button) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        field.frame = NSRect(x: 12, y: (bounds.height - 18) / 2, width: bounds.width - 100, height: 18)
        for (index, button) in [previous, next, done].enumerated() {
            button.frame = NSRect(x: bounds.width - 84 + CGFloat(index) * 26, y: (bounds.height - 24) / 2, width: 24, height: 24)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    func focus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// Shows whether the last search found anything.
    func found(_ found: Bool) {
        field.textColor = found || field.stringValue.isEmpty ? .labelColor : .systemRed
    }

    func search(backwards: Bool) {
        onSearch?(field.stringValue, backwards)
    }

    func controlTextDidChange(_ notification: Notification) { search(backwards: false) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            search(backwards: NSEvent.modifierFlags.contains(.shift))
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        return false
    }
}

/// The strip above the page while the device view is on: which device or
/// breakpoint, its size (editable), the scale it is shown at, rotate, and done.
final class DeviceBar: NSView, NSTextFieldDelegate {
    var onChange: ((Device?) -> Void)?
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let width = NSTextField()
    private let height = NSTextField()
    private let times = NSTextField(labelWithString: "×")
    private let scale = NSTextField(labelWithString: "")
    private let rotate = IconButton("rotate.right", size: 12, tip: L("Rotate"))
    private let save = IconButton("plus.circle", size: 12, tip: L("Save This Size"))
    private let done = IconButton("xmark", size: 10, tip: L("Close Device View"))
    private var device: Device?
    private var choices: [Device] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12)
        picker.target = self
        picker.action = #selector(picked)
        for field in [width, height] {
            field.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            field.alignment = .center
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
            field.focusRingType = .none
            field.delegate = self
            field.target = self
            field.action = #selector(typed)
        }
        for label in [times, scale] {
            label.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            label.textColor = .secondaryLabelColor
        }
        rotate.handler = { [weak self] in
            guard let self, let device = self.device else { return }
            self.onChange?(device.rotated)
        }
        save.handler = { [weak self] in
            guard let self, let device = self.device else { return }
            let key = "\(Int(device.width))x\(Int(device.height))"
            if !Prefs.shared.viewports.contains(key) { Prefs.shared.viewports.append(key) }
            self.show(device, scale: 1)
        }
        done.handler = { [weak self] in self?.onChange?(nil) }
        for view in [picker, width, times, height, scale, rotate, save, done] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ device: Device, scale shown: CGFloat) {
        self.device = device
        choices = Device.presets + Device.saved
        picker.removeAllItems()
        for (index, choice) in choices.enumerated() {
            if index == 7 || index == Device.presets.count { picker.menu?.addItem(.separator()) }
            picker.addItem(withTitle: choice.name)
        }
        let known = choices.first { $0.name == device.name || ($0.width == device.height && $0.height == device.width && $0.name == device.name) }
        if known != nil {
            picker.selectItem(withTitle: device.name)
        } else {
            picker.menu?.addItem(.separator())
            picker.addItem(withTitle: L("Custom"))
            picker.selectItem(withTitle: L("Custom"))
        }
        width.stringValue = "\(Int(device.width))"
        height.stringValue = "\(Int(device.height))"
        scale.stringValue = shown < 0.995 ? "\(Int((shown * 100).rounded()))%" : ""
        needsLayout = true
    }

    @objc private func picked() {
        guard let preset = choices.first(where: { $0.name == picker.titleOfSelectedItem }) else { return }
        // Keep the orientation when switching between phones and tablets.
        let landscape = device.map { $0.width > $0.height && $0.userAgent != nil } ?? false
        onChange?(landscape && preset.userAgent != nil ? preset.rotated : preset)
    }

    @objc private func typed() {
        guard let w = Double(width.stringValue), let h = Double(height.stringValue), w > 0, h > 0 else { return }
        if let device, device.width == CGFloat(w), device.height == CGFloat(h) { return }
        onChange?(Device.custom(width: CGFloat(w), height: CGFloat(h)))
    }

    func controlTextDidEndEditing(_ notification: Notification) { typed() }

    override func layout() {
        super.layout()
        picker.sizeToFit()
        scale.sizeToFit()
        times.sizeToFit()
        let scaleWidth = scale.stringValue.isEmpty ? 0 : scale.frame.width + 8
        let total = picker.frame.width + 8 + 48 + 4 + times.frame.width + 4 + 48 + 8 + scaleWidth + 26 * 3
        var x = ((bounds.width - total) / 2).rounded()
        let middle: (NSView) -> CGFloat = { (self.bounds.height - $0.frame.height) / 2 }
        picker.frame.origin = NSPoint(x: x, y: middle(picker))
        x += picker.frame.width + 8
        width.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 48, height: 20)
        x += 52
        times.frame.origin = NSPoint(x: x, y: middle(times))
        x += times.frame.width + 4
        height.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 48, height: 20)
        x += 56
        scale.frame.origin = NSPoint(x: x, y: middle(scale))
        x += scaleWidth
        for button in [rotate, save, done] {
            button.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: 24, height: 24)
            x += 26
        }
    }
}

/// The card the page sits in: the web view of the tab in front (or the start
/// page), with the loading bar, the find bar and the device view around it.
final class ContentView: NSView {
    let startModel = StartModel()
    private let card = FlippedView()
    /// Not flipped: Web Inspector docks itself along the bottom of the web
    /// view's superview, and in a flipped one that comes out on top.
    private let stage = NSView()
    private let divider = NSView()
    private let progress = CALayer()
    private let start: NSHostingView<StartPage>
    private let findBar = FindBar()
    private let deviceBar = DeviceBar()
    private(set) var tab: Tab?
    private var webView: WKWebView?
    private var mirrorView: WKWebView?
    var accent = NSColor.controlAccentColor { didSet { progress.backgroundColor = accent.cgColor } }
    /// The colour of the site's environment (production, staging…), drawn as
    /// a frame around the page so that it cannot be missed.
    var environmentColor: NSColor? { didSet { updateColors() } }

    override init(frame: NSRect) {
        start = NSHostingView(rootView: StartPage(model: startModel))
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.masksToBounds = true
        addSubview(card)
        stage.wantsLayer = true
        card.addSubview(stage)
        divider.wantsLayer = true
        divider.isHidden = true
        stage.addSubview(divider)
        card.addSubview(start)
        deviceBar.isHidden = true
        deviceBar.onChange = { [weak self] device in
            self?.tab?.device = device
            self?.deviceChanged()
        }
        card.addSubview(deviceBar)
        findBar.isHidden = true
        findBar.onClose = { [weak self] in self?.hideFind() }
        findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        card.addSubview(findBar)
        progress.backgroundColor = accent.cgColor
        progress.opacity = 0
        card.layer?.addSublayer(progress)
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var staged: Bool { tab?.device != nil || tab?.mirror != nil }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            stage.layer?.backgroundColor = staged ? NSColor.underPageBackgroundColor.cgColor : NSColor.clear.cgColor
            divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
            card.layer?.borderWidth = environmentColor == nil ? 0 : 2
            card.layer?.borderColor = environmentColor?.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    /// Puts a tab's page in the card.
    func show(_ tab: Tab?) {
        if self.tab !== tab { hideFind() }
        self.tab = tab
        let view = tab?.url == nil && tab?.webView?.url == nil && tab?.isLoading != true ? nil : tab?.webView
        if view !== webView {
            webView?.removeFromSuperview()
            webView = view
            if let view { stage.addSubview(view) }
        }
        let mirror = view == nil ? nil : tab?.mirror?.webView
        if mirror !== mirrorView {
            mirrorView?.removeFromSuperview()
            mirrorView = mirror
            if let mirror { stage.addSubview(mirror) }
        }
        start.isHidden = view != nil
        stage.isHidden = view == nil
        deviceChanged()
        progressChanged()
    }

    func deviceChanged() {
        deviceBar.isHidden = tab?.device == nil || webView == nil
        updateColors()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Web Inspector, when docked, puts its own view beside the page's in
    /// the stage.
    private var inspectorDocked: Bool {
        stage.subviews.contains { $0 !== webView && $0 !== mirrorView && $0 !== divider }
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        start.frame = card.bounds
        let barHeight: CGFloat = deviceBar.isHidden ? 0 : 34
        deviceBar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: barHeight)
        stage.frame = NSRect(x: 0, y: barHeight, width: card.bounds.width, height: card.bounds.height - barHeight)
        findBar.frame = NSRect(x: card.bounds.width - 312, y: barHeight + 10, width: 300, height: 36)
        defer { progressChanged() }
        guard let webView else { return }

        // The phone beside the page takes a column on the right.
        var area = stage.bounds
        divider.isHidden = mirrorView == nil
        if let mirrorView, let phone = tab?.mirror?.device {
            let column = min(phone.width + 32, area.width * 0.45)
            let width = column - 32, height = min(phone.height, area.height - 24)
            mirrorView.frame = NSRect(x: area.width - column + 16, y: area.height - 12 - height, width: width, height: height)
            mirrorView.pageZoom = min(width / phone.width, 1)
            divider.frame = NSRect(x: area.width - column, y: 0, width: 1, height: area.height)
            area.size.width -= column
        }

        if let device = tab?.device, !deviceBar.isHidden {
            // A size wider than the room it has is shown scaled down: the page
            // is laid out at the device's width and zoomed to fit. The height
            // is cut to what fits the window.
            let shown = min((area.width - 24) / device.width, 1)
            let width = (device.width * shown).rounded(), height = min(device.height * shown, area.height - 24).rounded()
            webView.frame = NSRect(x: ((area.width - width) / 2).rounded(), y: area.height - 12 - height, width: width, height: height)
            if abs(webView.pageZoom - shown) > 0.001 { webView.pageZoom = shown }
            deviceBar.show(device, scale: shown)
        } else if mirrorView != nil {
            webView.frame = area
        } else if !inspectorDocked {
            // (With Web Inspector docked, WebKit sizes the page itself.)
            webView.autoresizingMask = [.width, .height]
            webView.frame = area
        }
    }

    func progressChanged() {
        let loading = tab?.isLoading == true
        let value = CGFloat(tab?.progress ?? 0)
        CATransaction.begin()
        CATransaction.setDisableActions(!loading && progress.opacity == 0)
        progress.frame = CGRect(x: 0, y: 0, width: card.bounds.width * max(value, loading ? 0.08 : 0), height: 2)
        progress.opacity = loading ? 1 : 0
        CATransaction.commit()
    }

    // MARK: Find

    func showFind() {
        guard webView != nil else { return }
        findBar.isHidden = false
        findBar.focus()
    }

    func hideFind() {
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        if let webView { window?.makeFirstResponder(webView) }
    }

    func findAgain(backwards: Bool) {
        if findBar.isHidden { showFind() } else { findBar.search(backwards: backwards) }
    }

    private func find(_ text: String, backwards: Bool) {
        guard let webView, !text.isEmpty else { return findBar.found(true) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(text, configuration: configuration) { [weak self] result in
            self?.findBar.found(result.matchFound)
        }
    }

    // MARK: Screenshots

    /// A picture of the page: the part on screen, or all of it. For the whole
    /// page the web view is stretched to the page's height for a moment, so
    /// that a fixed header appears once and not in every screenful.
    func screenshot(fullPage: Bool, completion: @escaping (NSImage?) -> Void) {
        guard let webView else { return completion(nil) }
        guard fullPage else {
            return webView.takeSnapshot(with: nil) { image, _ in completion(image) }
        }
        let measure = "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)"
        webView.evaluateJavaScript(measure) { [weak self] result, _ in
            guard let self, let height = (result as? NSNumber)?.doubleValue, height > 0 else { return completion(nil) }
            let original = webView.frame
            // Beyond this WebKit cannot paint the page in one piece.
            let tall = min(CGFloat(height) * webView.pageZoom, 16000)
            webView.autoresizingMask = []
            webView.frame = NSRect(x: original.minX, y: original.maxY - tall, width: original.width, height: tall)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let configuration = WKSnapshotConfiguration()
                configuration.rect = NSRect(x: 0, y: 0, width: original.width, height: tall)
                webView.takeSnapshot(with: configuration) { image, _ in
                    webView.frame = original
                    self.needsLayout = true
                    completion(image)
                }
            }
        }
    }

    /// A picture of one part of the page, given in the page's own (CSS)
    /// coordinates relative to what is on screen.
    func screenshot(of rect: CGRect, completion: @escaping (NSImage?) -> Void) {
        guard let webView else { return completion(nil) }
        let zoom = webView.pageZoom
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom).intersection(webView.bounds)
        webView.takeSnapshot(with: configuration) { image, _ in completion(image) }
    }
}
