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

/// The strip above the page while the mobile view is on: which device, its
/// size, rotate, and done.
final class DeviceBar: NSView {
    var onChange: ((Device?) -> Void)?
    private let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let size = NSTextField(labelWithString: "")
    private let rotate = IconButton("rotate.right", size: 12, tip: L("Rotate"))
    private let done = IconButton("xmark", size: 10, tip: L("Close Mobile View"))
    private var device: Device?

    override init(frame: NSRect) {
        super.init(frame: frame)
        picker.isBordered = false
        picker.font = .systemFont(ofSize: 12)
        for preset in Device.presets { picker.addItem(withTitle: preset.name) }
        picker.target = self
        picker.action = #selector(picked)
        size.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        size.textColor = .secondaryLabelColor
        rotate.handler = { [weak self] in
            guard let self, let device = self.device else { return }
            self.onChange?(device.rotated)
        }
        done.handler = { [weak self] in self?.onChange?(nil) }
        for view in [picker, size, rotate, done] as [NSView] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ device: Device) {
        self.device = device
        picker.selectItem(withTitle: device.name)
        size.stringValue = "\(Int(device.width)) × \(Int(device.height))"
        needsLayout = true
    }

    @objc private func picked() {
        let preset = Device.presets[max(picker.indexOfSelectedItem, 0)]
        // Keep the orientation when switching device.
        let landscape = device.map { $0.width > $0.height } ?? false
        onChange?(landscape ? preset.rotated : preset)
    }

    override func layout() {
        super.layout()
        picker.sizeToFit()
        size.sizeToFit()
        let total = picker.frame.width + size.frame.width + 26 + 26 + 24
        var x = (bounds.width - total) / 2
        picker.frame.origin = NSPoint(x: x, y: (bounds.height - picker.frame.height) / 2)
        x += picker.frame.width + 8
        size.frame.origin = NSPoint(x: x, y: (bounds.height - size.frame.height) / 2)
        x += size.frame.width + 8
        rotate.frame = NSRect(x: x, y: (bounds.height - 24) / 2, width: 24, height: 24)
        done.frame = NSRect(x: x + 28, y: (bounds.height - 24) / 2, width: 24, height: 24)
    }
}

/// The card the page sits in: the web view of the tab in front (or the start
/// page), with the loading bar, the find bar and the mobile view around it.
final class ContentView: NSView {
    let startModel = StartModel()
    private let card = FlippedView()
    private let stage = FlippedView()
    private let progress = CALayer()
    private let start: NSHostingView<StartPage>
    private let findBar = FindBar()
    private let deviceBar = DeviceBar()
    private(set) var tab: Tab?
    private var webView: WKWebView?
    var accent = NSColor.controlAccentColor { didSet { progress.backgroundColor = accent.cgColor } }
    /// The page is shown edge to edge (full screen video and the like).
    var onFindClosed: (() -> Void)?

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

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
            stage.layer?.backgroundColor = tab?.device != nil ? NSColor.underPageBackgroundColor.cgColor : NSColor.clear.cgColor
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
        start.isHidden = view != nil
        stage.isHidden = view == nil
        deviceChanged()
        progressChanged()
    }

    func deviceChanged() {
        if let device = tab?.device, webView != nil {
            deviceBar.isHidden = false
            deviceBar.show(device)
        } else {
            deviceBar.isHidden = true
        }
        updateColors()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
        start.frame = card.bounds
        let barHeight: CGFloat = deviceBar.isHidden ? 0 : 34
        deviceBar.frame = NSRect(x: 0, y: 0, width: card.bounds.width, height: barHeight)
        stage.frame = NSRect(x: 0, y: barHeight, width: card.bounds.width, height: card.bounds.height - barHeight)
        if let device = tab?.device, !deviceBar.isHidden {
            // The device's width is what matters to a page; its height is cut
            // to what fits the window.
            let width = min(device.width, stage.bounds.width - 24), height = min(device.height, stage.bounds.height - 24)
            webView?.frame = NSRect(x: ((stage.bounds.width - width) / 2).rounded(), y: 12, width: width, height: height)
        } else {
            webView?.frame = stage.bounds
        }
        findBar.frame = NSRect(x: card.bounds.width - 312, y: barHeight + 10, width: 300, height: 36)
        progressChanged()
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
            let tall = min(CGFloat(height), 16000)
            webView.frame = NSRect(x: original.minX, y: original.minY, width: original.width, height: tall)
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
}
