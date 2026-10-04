import AppKit
import Combine
import SwiftUI
import WebKit

final class RootView: FlippedView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The edge of the sidebar: drag it to make the sidebar wider or narrower.
private final class SidebarResizer: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let x = superview.convert(event.locationInWindow, from: nil).x
        Prefs.shared.sidebarWidth = Double(min(max(x, 190), 420))
    }
}

/// The profiles of a window: an icon each in the sidebar, or a single button
/// with a menu where there is less room.
final class ProfileBar: NSView {
    /// A row of icons (the sidebar), a column (the narrow sidebar), or one
    /// button with a menu (the top bar, or when there are too many to line up).
    enum Style { case row, column, single }

    weak var controller: BrowserWindowController?
    var style = Style.row { didSet { if style != oldValue { reload() } } }
    /// How many icons a row or column has room for.
    var capacity = 4 { didSet { if capacity != oldValue { reload() } } }

    override var isFlipped: Bool { true }

    /// The icons shown: every profile, or one when they do not fit.
    var count: Int {
        let all = Profiles.shared.all.count
        guard let controller, !controller.tabs.profile.isPrivate, style != .single, all <= capacity else { return 1 }
        return all
    }

    func reload() {
        subviews.forEach { $0.removeFromSuperview() }
        guard let controller else { return }
        let current = controller.tabs.profile
        if count == 1, style == .single || current.isPrivate || Profiles.shared.all.count > 1 {
            let button = IconButton(current.symbol, size: 13, tip: current.name)
            button.tint = current.accent
            if !current.isPrivate { button.menuProvider = { [weak controller] in controller?.profileMenu() ?? NSMenu() } }
            button.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
            addSubview(button)
            return
        }
        for (index, profile) in Profiles.shared.all.enumerated() {
            let button = IconButton(profile.symbol, size: 12.5, tip: profile.name) { [weak controller] in controller?.tabs.switchProfile(profile) }
            button.tint = profile === current ? profile.accent : .tertiaryLabelColor
            button.frame = style == .column ? NSRect(x: 0, y: CGFloat(index) * 30, width: 28, height: 28) : NSRect(x: CGFloat(index) * 30, y: 0, width: 28, height: 28)
            button.menu = controller.profileMenu()
            addSubview(button)
        }
    }
}

/// A browser window: the tabs, the address bar and the page in front.
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var all: [BrowserWindowController] = []

    let tabs: TabManager
    let root = RootView()
    private let background = ThemeBackgroundView()
    let tabsView = TabsView()
    let addressBar = AddressBar()
    let content = ContentView()
    let palette = Palette()
    let devModel = DevPanelModel()
    private var devPanel = NSView()
    var devPanelVisible = false
    /// The page the developer panel last looked at.
    private var audited: URL?
    private let profileBar = ProfileBar()
    private let resizer = SidebarResizer()
    private let back = IconButton("chevron.left", tip: L("Back"))
    private let forward = IconButton("chevron.right", tip: L("Forward"))
    private let reloadButton = IconButton("arrow.clockwise", size: 12, tip: L("Reload"))
    private let sidebarButton = IconButton("sidebar.left", tip: L("Show or Hide the Sidebar"))
    private let newTabButton = IconButton("plus", tip: L("New Tab"))
    private let downloadsButton = IconButton("arrow.down.circle", size: 14, tip: L("Downloads"))
    private let menuButton = IconButton("ellipsis", size: 14, tip: L("More"))
    private var subscriptions: [AnyCancellable] = []
    private var observers: [NSObjectProtocol] = []
    private var bookmarked: (url: URL, value: Bool)?
    private var popover: NSPopover?

    init(profile: Profile, frame: NSRect? = nil, groups: [GroupRow] = [], tabRows: [TabRow] = [], opening url: URL? = nil) {
        tabs = TabManager(profile: profile)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 520, height: 380)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        if profile.isPrivate { window.appearance = NSAppearance(named: .darkAqua) }
        super.init(window: window)
        window.delegate = self
        tabs.window = self
        Self.all.append(self)
        if !profile.isPrivate { Session.thaw() }
        build()
        if let frame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
            window.setFrame(frame, display: false)
        } else if let last = Self.all.dropLast().last?.window {
            window.setFrame(last.frame.offsetBy(dx: 26, dy: -26), display: false)
        } else {
            window.center()
            window.setFrameAutosaveName("MizuBrowser")
        }
        if tabRows.isEmpty {
            tabs.newTab(url: url)
        } else {
            tabs.restore(groups: groups, tabs: tabRows)
            if let url { tabs.newTab(url: url) }
        }
        profileChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Building

    private func build() {
        guard let window else { return }
        window.contentView = root
        root.onLayout = { [weak self] in self?.layoutChrome() }
        background.autoresizingMask = [.width, .height]
        background.frame = root.bounds
        root.addSubview(background)
        tabsView.manager = tabs
        profileBar.controller = self
        for view in [tabsView, addressBar, content, profileBar, back, forward, reloadButton, sidebarButton, newTabButton, downloadsButton, menuButton, resizer] as [NSView] {
            root.addSubview(view)
        }

        devModel.controller = self
        let panel = NSHostingView(rootView: DevPanelView(model: devModel) { [weak self] in self?.toggleDevPanel(nil) })
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.masksToBounds = true
        panel.isHidden = true
        devPanel = panel
        root.addSubview(panel)
        palette.isHidden = true
        palette.onDismiss = { [weak self] in
            guard let self else { return }
            if self.tabs.selected?.url == nil, self.tabs.selected?.webView == nil { self.addressBar.focus() } else { self.focusPage() }
        }
        root.addSubview(palette)
        addressBar.environmentMenu = { [weak self] in self?.environmentMenu() ?? NSMenu() }

        back.handler = { [weak self] in self?.goBack(nil) }
        forward.handler = { [weak self] in self?.goForward(nil) }
        reloadButton.handler = { [weak self] in
            guard let tab = self?.tabs.selected else { return }
            if tab.isLoading { tab.webView?.stopLoading() } else { tab.reload() }
        }
        sidebarButton.handler = { [weak self] in self?.toggleSidebar(nil) }
        newTabButton.handler = { [weak self] in self?.newTab(nil) }
        downloadsButton.handler = { [weak self] in self?.showDownloads(nil) }
        menuButton.menuProvider = { [weak self] in self?.moreMenu() ?? NSMenu() }

        addressBar.onSubmit = { [weak self] input in self?.open(input) }
        addressBar.onCancel = { [weak self] in self?.focusPage() }
        addressBar.suggest = { [weak self] text in self?.suggestions(for: text) ?? [] }
        addressBar.shield.handler = { [weak self] in self?.showShield() }
        addressBar.star.handler = { [weak self] in self?.toggleBookmark(nil) }
        addressBar.key.handler = { [weak self] in self?.fillPassword(nil) }

        content.startModel.open = { [weak self] url in self?.tabs.selected?.open(url); self?.selectionChanged() }
        content.startModel.focus = { [weak self] in self?.addressBar.focus() }

        subscriptions.append(Prefs.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.prefsChanged() }
        })
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .profilesChanged, object: nil, queue: .main) { [weak self] _ in self?.applyTheme() })
        observers.append(center.addObserver(forName: .bookmarksChanged, object: nil, queue: .main) { [weak self] _ in
            self?.bookmarked = nil
            self?.loadBookmarks()
            self?.updateToolbar()
        })
        observers.append(center.addObserver(forName: .adblockChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for tab in self.tabs.tabs {
                guard let view = tab.webView else { continue }
                Adblock.shared.configure(view.configuration.userContentController, host: view.url?.host)
            }
            self.updateToolbar()
        })
    }

    var vertical: Bool { Prefs.shared.tabLayout != "horizontal" }
    private var lastLayout = ""

    private func prefsChanged() {
        root.needsLayout = true
        updateToolbar()
    }

    func relayout() {
        root.needsLayout = true
    }

    /// Places everything. The arrangements: tabs in a sidebar; the sidebar
    /// collapsed to a strip of icons, or hidden, under a single bar on top;
    /// and tabs along the top, in one row with the address or in a row of
    /// their own.
    private func layoutChrome() {
        guard let window else { return }
        let size = root.bounds.size
        // Leave room for the close, minimise and zoom buttons.
        let lead: CGFloat = window.styleMask.contains(.fullScreen) ? 10 : 78
        let sidebar = vertical && Prefs.shared.sidebarVisible
        // Collapsed, the sidebar leaves a narrow strip of icons (or nothing).
        let rail = vertical && !sidebar && Prefs.shared.compactSidebar
        // On top, tabs and address share one row unless two are asked for.
        let oneRow = !vertical && Prefs.shared.compactTabBar
        if oneRow {
            tabsView.embedded = addressBar
        } else if addressBar.superview !== root {
            tabsView.embedded = nil
            root.addSubview(addressBar)
        }
        tabsView.vertical = vertical
        tabsView.compact = rail
        tabsView.isHidden = vertical && !sidebar && !rail
        newTabButton.isHidden = vertical
        resizer.isHidden = !sidebar
        sidebarButton.isHidden = !vertical
        profileBar.style = sidebar ? .row : (rail ? .column : .single)
        let place: (NSView, CGFloat, CGFloat) -> Void = { view, x, y in view.frame = NSRect(x: x, y: y, width: 28, height: 28) }

        if sidebar {
            let width = min(CGFloat(Prefs.shared.sidebarWidth), size.width - 300)
            place(sidebarButton, lead, 1)
            place(back, width - 92, 1)
            place(forward, width - 64, 1)
            place(reloadButton, width - 36, 1)
            addressBar.frame = NSRect(x: 10, y: 38, width: width - 20, height: 34)
            tabsView.frame = NSRect(x: 0, y: 82, width: width, height: size.height - 82 - 44)
            profileBar.capacity = max(Int((width - 84) / 30), 1)
            profileBar.frame = NSRect(x: 10, y: size.height - 36, width: width - 80, height: 28)
            place(downloadsButton, width - 66, size.height - 36)
            place(menuButton, width - 36, size.height - 36)
            resizer.frame = NSRect(x: width - 3, y: 0, width: 6, height: size.height)
            content.frame = NSRect(x: width, y: 8, width: size.width - width - 8, height: size.height - 16)
        } else if oneRow {
            let top: CGFloat = 4
            place(back, lead, top)
            place(forward, lead + 28, top)
            place(reloadButton, lead + 56, top)
            place(menuButton, size.width - 36, top)
            profileBar.frame = NSRect(x: size.width - 66, y: top, width: 28, height: 28)
            place(downloadsButton, size.width - 96, top)
            place(newTabButton, size.width - 126, top)
            tabsView.frame = NSRect(x: lead + 90, y: 1, width: size.width - lead - 90 - 132, height: 34)
            content.frame = NSRect(x: 6, y: 40, width: size.width - 12, height: size.height - 46)
        } else {
            var top: CGFloat = 4
            if !vertical {
                tabsView.frame = NSRect(x: lead, y: 3, width: size.width - lead - 44, height: 34)
                place(newTabButton, size.width - 38, 6)
                top = 40
            }
            var x: CGFloat = vertical ? lead : 10
            if vertical {
                place(sidebarButton, x, top)
                x += 30
            }
            place(back, x, top)
            place(forward, x + 28, top)
            place(reloadButton, x + 56, top)
            x += 90
            let y = top + 36
            let left: CGFloat = rail ? 52 : 6
            if rail {
                // As in the wide sidebar, profiles, downloads and the menu sit
                // at the bottom left, stacked.
                profileBar.capacity = 4
                var bottom = size.height - 36
                place(menuButton, 12, bottom)
                bottom -= 30
                place(downloadsButton, 12, bottom)
                bottom -= 30 * CGFloat(profileBar.count)
                profileBar.frame = NSRect(x: 12, y: bottom, width: 28, height: 30 * CGFloat(profileBar.count))
                tabsView.frame = NSRect(x: 0, y: y, width: left, height: bottom - y - 8)
                addressBar.frame = NSRect(x: x, y: top - 2, width: size.width - x - 10, height: 32)
            } else {
                place(menuButton, size.width - 36, top)
                profileBar.frame = NSRect(x: size.width - 66, y: top, width: 28, height: 28)
                place(downloadsButton, size.width - 96, top)
                addressBar.frame = NSRect(x: x, y: top - 2, width: size.width - x - 106, height: 32)
            }
            content.frame = NSRect(x: left, y: y, width: size.width - left - 6, height: size.height - y - 6)
        }
        devPanel.isHidden = !devPanelVisible
        if devPanelVisible {
            let width = min(340, (content.frame.width * 0.45).rounded())
            devPanel.frame = NSRect(x: content.frame.maxX - width, y: content.frame.minY, width: width, height: content.frame.height)
            content.frame.size.width -= width + 8
        }
        palette.frame = root.bounds
        let layout = "\(vertical)\(sidebar)\(rail)\(oneRow)\(profileBar.count)"
        if layout != lastLayout {
            lastLayout = layout
            tabsView.reload()
            profileBar.reload()
        }
    }

    // MARK: Changes from the tabs

    func tabsChanged() {
        tabsView.reload()
    }

    func selectionChanged() {
        let tab = tabs.selected
        content.show(tab)
        tabsView.selectionChanged()
        updateToolbar()
        if devPanelVisible {
            audited = tab?.url
            devModel.pageChanged()
        }
        if tab?.url == nil, tab?.webView == nil {
            addressBar.focus()
        } else {
            focusPage()
        }
    }

    func profileChanged() {
        applyTheme()
        loadBookmarks()
        profileBar.reload()
        tabsView.reload()
        selectionChanged()
    }

    func tabUpdated(_ tab: Tab) {
        tabsView.update(tab)
        guard tab === tabs.selected else { return }
        content.show(tab)
        updateToolbar()
        if devPanelVisible, !tab.isLoading, tab.url != audited {
            audited = tab.url
            devModel.pageChanged()
        }
    }

    func progressChanged() {
        content.progressChanged()
    }

    func blockedCountChanged() {
        updateShield()
    }

    private func applyTheme() {
        let profile = tabs.profile
        background.apply(profile)
        content.accent = profile.accent
        content.startModel.accent = Color(nsColor: profile.accent)
        content.startModel.isPrivate = profile.isPrivate
        profileBar.reload()
        root.needsLayout = true
    }

    private func loadBookmarks() {
        content.startModel.bookmarks = tabs.profile.isPrivate ? [] : Store.shared.bookmarks(profile: tabs.profile.key)
    }

    private func updateToolbar() {
        let tab = tabs.selected
        window?.title = tab?.displayTitle ?? "Mizu"
        back.isEnabled = tab?.canGoBack ?? false
        forward.isEnabled = tab?.canGoForward ?? false
        reloadButton.isEnabled = tab?.webView != nil
        reloadButton.symbol = tab?.isLoading == true ? "xmark" : "arrow.clockwise"
        let environment = SiteEnvironment.of(tab?.url?.host)
        addressBar.environment = environment
        content.environmentColor = environment?.color
        addressBar.show(url: tab?.url, secure: tab?.isSecure ?? false)
        addressBar.key.isHidden = tab?.hasLoginForm != true
        if let url = tab?.url, !tabs.profile.isPrivate {
            if bookmarked?.url != url { bookmarked = (url, Store.shared.isBookmarked(profile: tabs.profile.key, url: url.absoluteString)) }
            addressBar.star.symbol = bookmarked?.value == true ? "star.fill" : "star"
            addressBar.star.tint = bookmarked?.value == true ? .systemYellow : nil
        } else {
            addressBar.star.isHidden = true
        }
        addressBar.needsLayout = true
        updateShield()
        downloadsButton.tint = Downloads.shared.active > 0 ? tabs.profile.accent : nil
    }

    private func updateShield() {
        let tab = tabs.selected
        let active = Adblock.shared.isActive(on: tab?.url?.host)
        addressBar.shield.symbol = active ? "shield.lefthalf.filled" : "shield.slash"
        addressBar.shield.tint = active ? tabs.profile.accent : .tertiaryLabelColor
        let count = tab?.blocked ?? 0
        addressBar.shield.badge = active && count > 0 ? (count > 99 ? "99+" : "\(count)") : nil
    }

    // MARK: Opening

    /// Opens what was typed in the address bar in the tab in front.
    func open(_ input: String) {
        guard let url = Resolver.url(for: input) else { return }
        if let tab = tabs.selected {
            tab.open(url)
            selectionChanged()
        } else {
            tabs.newTab(url: url)
        }
    }

    func open(_ url: URL) {
        // Reuse an empty tab rather than leaving it behind.
        if let tab = tabs.selected, tab.url == nil, tab.webView == nil {
            tab.open(url)
            selectionChanged()
        } else {
            tabs.newTab(url: url)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func focusPage() {
        if let view = tabs.selected?.webView, view.window != nil {
            window?.makeFirstResponder(view)
        }
    }

    func suggestions(for text: String) -> [Suggestion] {
        var result: [Suggestion] = []
        if Resolver.looksLikeHost(text) || text.contains("://") {
            result.append(Suggestion(title: text, detail: L("Open"), symbol: "globe", icon: nil, input: text))
        } else {
            result.append(Suggestion(title: text, detail: L("Search with %@", Prefs.shared.engine.name), symbol: "magnifyingglass", icon: nil, input: Resolver.search(text)?.absoluteString ?? text))
        }
        guard !tabs.profile.isPrivate else { return result }
        var seen = Set<String>()
        let lower = text.lowercased()
        for bookmark in content.startModel.bookmarks where bookmark.url.lowercased().contains(lower) || bookmark.title.lowercased().contains(lower) {
            guard result.count < 3, seen.insert(bookmark.url).inserted else { continue }
            result.append(Suggestion(title: bookmark.title.isEmpty ? bookmark.url : bookmark.title, detail: AddressBar.pretty(URL(string: bookmark.url)), symbol: "star.fill", icon: nil, input: bookmark.url))
        }
        for row in Store.shared.suggestions(profile: tabs.profile.key, matching: text, limit: 6) where seen.insert(row.url).inserted && result.count < 7 {
            let url = URL(string: row.url)
            result.append(Suggestion(title: row.title.isEmpty ? AddressBar.pretty(url) : row.title, detail: AddressBar.pretty(url), symbol: "clock",
                                     icon: url?.host.flatMap(Favicons.shared.cached), input: row.url))
        }
        return result
    }

    // MARK: Menus and popovers

    func profileMenu() -> NSMenu {
        let menu = NSMenu()
        for profile in Profiles.shared.all {
            menu.add(profile.name, symbol: profile.symbol, checked: profile === tabs.profile) { [weak self] in self?.tabs.switchProfile(profile) }
        }
        menu.separator()
        menu.add(L("Manage Profiles…")) { SettingsWindow.show(.profiles) }
        return menu
    }

    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.add(L("New Tab"), symbol: "plus") { [weak self] in self?.newTab(nil) }
        menu.add(L("New Window"), symbol: "macwindow") { AppDelegate.shared.newWindow(nil) }
        menu.add(L("New Private Window"), symbol: "eyeglasses") { AppDelegate.shared.newPrivateWindow(nil) }
        menu.separator()
        menu.addSubmenu(L("Bookmarks"), symbol: "star") { sub in
            let bookmarks = content.startModel.bookmarks
            if bookmarks.isEmpty { sub.add(L("No Bookmarks"), enabled: false) {} }
            for bookmark in bookmarks {
                let item = sub.add(bookmark.title.isEmpty ? bookmark.url : bookmark.title) { [weak self] in
                    if let url = URL(string: bookmark.url) { self?.open(url) }
                }
                item.image = URL(string: bookmark.url)?.host.flatMap(Favicons.shared.cached)
            }
        }
        menu.add(L("History"), symbol: "clock") { [weak self] in self?.showHistory(nil) }
        menu.add(L("Downloads"), symbol: "arrow.down.circle") { [weak self] in self?.showDownloads(nil) }
        menu.separator()
        let hasPage = tabs.selected?.webView?.url != nil
        menu.add(L("Full Page Screenshot"), symbol: "camera.viewfinder", enabled: hasPage) { [weak self] in self?.screenshotFullPage(nil) }
        menu.add(L("Device View"), symbol: "iphone", checked: tabs.selected?.device != nil, enabled: hasPage) { [weak self] in self?.toggleMobileView(nil) }
        menu.add(L("Web Inspector"), symbol: "hammer", enabled: hasPage) { [weak self] in self?.showInspector(nil) }
        menu.add(L("Developer Panel"), symbol: "sidebar.right", checked: devPanelVisible) { [weak self] in self?.toggleDevPanel(nil) }
        menu.add(L("Command Palette…"), symbol: "command") { [weak self] in self?.showPalette(.commands) }
        menu.separator()
        menu.add(vertical ? L("Tabs on Top") : L("Tabs in Sidebar"), symbol: vertical ? "rectangle.topthird.inset.filled" : "sidebar.left") { [weak self] in self?.toggleTabLayout(nil) }
        menu.add(L("Settings…"), symbol: "gearshape") { SettingsWindow.show(.general) }
        return menu
    }

    func show(_ view: some View, from anchor: NSView, edge: NSRectEdge? = nil) {
        popover?.close()
        // "Below" is the far edge in a flipped view and the near one otherwise.
        let edge = edge ?? (anchor.isFlipped ? .maxY : .minY)
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: view)
        // The size is settled before the popover is placed: one that shrinks
        // afterwards keeps its bottom edge and so drifts away from its button.
        popover.contentSize = host.sizeThatFits(in: NSSize(width: 600, height: 600))
        popover.contentViewController = host
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        self.popover = popover
    }

    func showShield() {
        guard let tab = tabs.selected, let host = tab.url?.host else { return }
        show(ShieldView(host: host, blocked: tab.blocked) { [weak self] in
            self?.popover?.close()
            tab.reload()
        }, from: addressBar.shield)
    }

    @objc func showDownloads(_ sender: Any?) {
        // In either sidebar the button is at the left edge: open to the right.
        show(DownloadsView(), from: downloadsButton, edge: downloadsButton.frame.minX < 60 || (vertical && Prefs.shared.sidebarVisible) ? .maxX : nil)
    }

    @objc func showHistory(_ sender: Any?) {
        HistoryWindow.show(profile: tabs.profile) { [weak self] url in self?.open(url) }
    }

    // MARK: Actions

    /// A new tab starts in the palette: type where to go, and the tab opens
    /// with the page. (Esc leaves everything as it was.)
    @objc func newTab(_ sender: Any?) {
        showPalette(.open)
    }

    @objc func closeTab(_ sender: Any?) {
        guard let tab = tabs.selected else { return }
        // Closing the last, empty tab closes the window.
        if tabs.visible.count == 1, tab.url == nil, tab.webView == nil { window?.performClose(nil) } else { tabs.close(tab) }
    }

    @objc func reopenClosedTab(_ sender: Any?) { tabs.reopenClosed() }
    @objc func focusAddressBar(_ sender: Any?) {
        if vertical, !Prefs.shared.sidebarVisible { root.layoutSubtreeIfNeeded() }
        addressBar.focus()
    }
    @objc func reloadPage(_ sender: Any?) { tabs.selected?.reload() }
    @objc func reloadFromOrigin(_ sender: Any?) { tabs.selected?.reload(fromOrigin: true) }
    @objc func stopLoading(_ sender: Any?) { tabs.selected?.webView?.stopLoading() }
    @objc func goBack(_ sender: Any?) { tabs.selected?.webView?.goBack() }
    @objc func goForward(_ sender: Any?) { tabs.selected?.webView?.goForward() }
    @objc func nextTab(_ sender: Any?) { tabs.selectNeighbour(1) }
    @objc func previousTab(_ sender: Any?) { tabs.selectNeighbour(-1) }
    @objc func selectTabByNumber(_ sender: NSMenuItem) { tabs.select(position: sender.tag) }
    @objc func zoomIn(_ sender: Any?) { tabs.selected?.webView.map { $0.pageZoom = min($0.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ sender: Any?) { tabs.selected?.webView.map { $0.pageZoom = max($0.pageZoom - 0.1, 0.5) } }
    @objc func zoomReset(_ sender: Any?) { tabs.selected?.webView?.pageZoom = 1 }
    @objc func findInPage(_ sender: Any?) { content.showFind() }
    @objc func findNext(_ sender: Any?) { content.findAgain(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { content.findAgain(backwards: true) }
    @objc func toggleSidebar(_ sender: Any?) { Prefs.shared.sidebarVisible.toggle() }
    @objc func toggleTabLayout(_ sender: Any?) { Prefs.shared.tabLayout = vertical ? "horizontal" : "vertical" }
    @objc func duplicateTab(_ sender: Any?) { tabs.selected.map { _ = tabs.duplicate($0) } }
    @objc func pinTab(_ sender: Any?) { tabs.selected.map { tabs.setPinned($0, !$0.pinned) } }

    @objc func groupTab(_ sender: Any?) {
        guard let tab = tabs.selected else { return }
        promptForText(title: L("Name the group"), value: tab.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "", in: window) { [weak self] in
            self?.tabs.makeGroup(with: tab, name: $0)
        }
    }

    @objc func switchProfileByNumber(_ sender: NSMenuItem) {
        let profiles = Profiles.shared.all
        if sender.tag < profiles.count { tabs.switchProfile(profiles[sender.tag]) }
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = tabs.selected, let url = tab.url, !tabs.profile.isPrivate else { return }
        if Store.shared.isBookmarked(profile: tabs.profile.key, url: url.absoluteString) {
            Store.shared.removeBookmark(profile: tabs.profile.key, url: url.absoluteString)
        } else {
            Store.shared.addBookmark(profile: tabs.profile.key, url: url.absoluteString, title: tab.displayTitle)
        }
    }

    @objc func copyAddress(_ sender: Any?) {
        guard let url = tabs.selected?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func fillPassword(_ sender: Any?) {
        guard let tab = tabs.selected, tab.webView?.url != nil else { return }
        Passwords.offer(for: tab, from: addressBar.key.isHidden ? addressBar : addressBar.key)
    }

    @objc func printPage(_ sender: Any?) {
        guard let view = tabs.selected?.webView, let window else { return }
        let operation = view.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = view.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Developer

    @objc func showInspector(_ sender: Any?) { tabs.selected?.showInspector() }

    @objc func toggleMobileView(_ sender: Any?) {
        guard let tab = tabs.selected, tab.webView != nil else { return }
        tab.device = tab.device == nil ? Device.presets[1] : nil
        if tab.device == nil { tab.webView?.pageZoom = 1 }
        content.deviceChanged()
    }

    @objc func toggleJavaScript(_ sender: Any?) {
        guard let tab = tabs.selected else { return }
        tab.javaScriptDisabled.toggle()
        tab.reload()
    }

    @objc func screenshotFullPage(_ sender: Any?) { screenshot(fullPage: true) }
    @objc func screenshotVisible(_ sender: Any?) { screenshot(fullPage: false) }

    /// A PNG of the page in front.
    func capture(fullPage: Bool, completion: @escaping (Data?) -> Void) {
        content.screenshot(fullPage: fullPage) { image in
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return completion(nil) }
            completion(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        }
    }

    private func screenshot(fullPage: Bool) {
        guard let tab = tabs.selected, let window else { return }
        capture(fullPage: fullPage) { png in
            guard let png else { return NSSound.beep() }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(png, forType: .png)
            let panel = NSSavePanel()
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
            panel.nameFieldStringValue = "\(tab.url?.host ?? "page") \(stamp.string(from: Date())).png"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            panel.message = L("The screenshot is also on the clipboard.")
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { try? png.write(to: url) }
            }
        }
    }

    @objc func savePDF(_ sender: Any?) {
        guard let tab = tabs.selected, let view = tab.webView, let window else { return }
        view.createPDF { result in
            guard case let .success(data) = result else { return NSSound.beep() }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(tab.displayTitle.replacingOccurrences(of: "/", with: "-")).pdf"
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { try? data.write(to: url) }
            }
        }
    }

    @objc func viewSource(_ sender: Any?) {
        guard let tab = tabs.selected, let view = tab.webView, let page = view.url else { return }
        view.evaluateJavaScript("new XMLSerializer().serializeToString(document)") { [weak self] result, _ in
            guard let self, let source = result as? String else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(page.host ?? "page")-source-\(Int(Date().timeIntervalSince1970)).txt")
            try? source.write(to: file, atomically: true, encoding: .utf8)
            self.tabs.newTab(url: file, after: tab)
        }
    }

    /// Forgets the cookies, storage and cache of the site in front.
    @objc func clearSiteData(_ sender: Any?) {
        guard let tab = tabs.selected, let host = tab.url?.host else { return }
        let parts = host.split(separator: ".")
        let domain = parts.suffix(2).joined(separator: ".")
        let store = tab.profile.dataStore
        store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matching = records.filter { $0.displayName == domain || host.hasSuffix($0.displayName) }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) { tab.reload(fromOrigin: true) }
        }
    }

    @objc func markEnvironment(_ sender: NSMenuItem) {
        mark(sender.tag < SiteEnvironment.allCases.count ? SiteEnvironment.allCases[sender.tag] : nil)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let tab = tabs.selected
        let hasPage = tab?.webView?.url != nil
        switch item.action {
        case #selector(toggleMobileView(_:)):
            item.state = tab?.device != nil ? .on : .off
            return hasPage
        case #selector(toggleJavaScript(_:)):
            item.state = tab?.javaScriptDisabled == true ? .on : .off
            return hasPage
        case #selector(toggleCache(_:)):
            item.state = tab?.cacheDisabled == true ? .on : .off
            return hasPage
        case #selector(toggleSplitMobile(_:)):
            item.state = tab?.mirror != nil ? .on : .off
            return hasPage
        case #selector(toggleDevPanel(_:)):
            item.state = devPanelVisible ? .on : .off
            return true
        case #selector(chooseUserAgent(_:)):
            let current = tab?.userAgent
            item.state = (item.tag < 0 ? current == nil : (item.tag < UserAgent.presets.count && UserAgent.presets[item.tag].value == current)) ? .on : .off
            return hasPage
        case #selector(markEnvironment(_:)):
            let current = SiteEnvironment.of(tab?.url?.host)
            item.state = (item.tag < SiteEnvironment.allCases.count ? SiteEnvironment.allCases[item.tag] == current : current == nil) ? .on : .off
            return hasPage
        case #selector(showDevTool(_:)), #selector(pickColor(_:)), #selector(inspectStyles(_:)), #selector(screenshotElement(_:)), #selector(showConsole(_:)):
            return hasPage
        case #selector(quickSwitchProfile(_:)):
            return !tabs.profile.isPrivate
        case #selector(pinTab(_:)):
            item.title = tab?.pinned == true ? L("Unpin Tab") : L("Pin Tab")
            return tab != nil
        case #selector(toggleBookmark(_:)):
            item.title = bookmarked?.value == true ? L("Remove Bookmark") : L("Bookmark This Page")
            return hasPage && !tabs.profile.isPrivate
        case #selector(toggleTabLayout(_:)):
            item.title = vertical ? L("Tabs on Top") : L("Tabs in Sidebar")
            return true
        case #selector(toggleSidebar(_:)):
            return vertical
        case #selector(reopenClosedTab(_:)):
            return tabs.canReopen
        case #selector(goBack(_:)):
            return tab?.canGoBack == true
        case #selector(goForward(_:)):
            return tab?.canGoForward == true
        case #selector(switchProfileByNumber(_:)):
            return !tabs.profile.isPrivate && item.tag < Profiles.shared.all.count
        case #selector(showInspector(_:)), #selector(screenshotFullPage(_:)), #selector(screenshotVisible(_:)), #selector(viewSource(_:)),
             #selector(clearSiteData(_:)), #selector(savePDF(_:)), #selector(printPage(_:)), #selector(findInPage(_:)), #selector(reloadPage(_:)),
             #selector(reloadFromOrigin(_:)), #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(zoomReset(_:)), #selector(copyAddress(_:)),
             #selector(fillPassword(_:)):
            return hasPage
        default:
            return true
        }
    }

    // MARK: Window

    func windowDidEnterFullScreen(_ notification: Notification) { root.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) { root.needsLayout = true }
    func windowDidResize(_ notification: Notification) { Session.scheduleSave() }
    func windowDidMove(_ notification: Notification) { Session.scheduleSave() }

    func windowWillClose(_ notification: Notification) {
        // The last window to close is what the next launch brings back.
        if Self.all.filter({ !$0.tabs.profile.isPrivate }).count == 1, !tabs.profile.isPrivate { Session.freeze() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        subscriptions = []
        for tab in tabs.tabs { tab.discard() }
        Self.all.removeAll { $0 === self }
        Session.scheduleSave()
    }
}
