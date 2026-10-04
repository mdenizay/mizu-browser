import AppKit
import SwiftUI
import WebKit

/// Which of a client's sites a page belongs to. Marked in the address bar
/// and as a frame around the page, so that production is never mistaken for
/// staging.
enum SiteEnvironment: String, CaseIterable {
    case production, staging, development

    var label: String {
        switch self {
        case .production: return "PROD"
        case .staging: return "STAGING"
        case .development: return "DEV"
        }
    }

    var title: String {
        switch self {
        case .production: return L("Production")
        case .staging: return L("Staging")
        case .development: return L("Development")
        }
    }

    var color: NSColor {
        switch self {
        case .production: return .systemRed
        case .staging: return .systemOrange
        case .development: return .systemGreen
        }
    }

    private static func key(_ host: String) -> String { host.lowercased() }

    /// What a host was marked as, or else what its name gives away.
    static func of(_ host: String?) -> SiteEnvironment? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if let marked = Prefs.shared.environments[key(host)] { return SiteEnvironment(rawValue: marked) }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test")
            || host.range(of: #"^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)"#, options: .regularExpression) != nil {
            return .development
        }
        let words = Set(host.split(whereSeparator: { $0 == "." || $0 == "-" }).map(String.init))
        if !words.isDisjoint(with: ["staging", "stage", "stg", "preprod", "uat", "preview", "sandbox", "test", "dev", "beta", "demo"]) { return .staging }
        if ["vercel.app", "netlify.app", "pages.dev", "ngrok.io", "ngrok-free.app", "herokuapp.com"].contains(where: { host.hasSuffix("." + $0) }) { return .staging }
        return nil
    }

    /// Marks a host by hand; nil says it is none of them, whatever its name.
    static func set(_ environment: SiteEnvironment?, for host: String) {
        Prefs.shared.environments[key(host)] = environment?.rawValue ?? "none"
    }
}

/// Tools an agency keeps open for a client, to pin into a profile in one go.
enum ClientTools {
    static let all: [(name: String, url: String)] = [
        ("GitHub", "https://github.com"),
        ("Figma", "https://www.figma.com/files"),
        ("Google Analytics", "https://analytics.google.com"),
        ("Search Console", "https://search.google.com/search-console"),
        ("Google Ads", "https://ads.google.com"),
        ("Tag Manager", "https://tagmanager.google.com"),
        ("Meta Ads Manager", "https://adsmanager.facebook.com"),
        ("Meta Business Suite", "https://business.facebook.com"),
        ("PageSpeed Insights", "https://pagespeed.web.dev"),
        ("Cloudflare", "https://dash.cloudflare.com"),
        ("Vercel", "https://vercel.com/dashboard"),
        ("Netlify", "https://app.netlify.com"),
        ("Notion", "https://www.notion.so"),
        ("Trello", "https://trello.com"),
    ]
}

extension BrowserWindowController {
    // MARK: Palette

    enum PaletteMode { case open, commands, profiles }

    func showPalette(_ mode: PaletteMode) {
        palette.provider = { [weak self] text in
            guard let self else { return [] }
            switch mode {
            case .open: return self.pagesAndTabs(text)
            case .commands: return self.commands(text)
            case .profiles: return self.profileItems(text)
            }
        }
        switch mode {
        case .open: palette.present(placeholder: L("Search or enter address"), symbol: "magnifyingglass")
        case .commands: palette.present(placeholder: L("Run a command, open a tab or a page"), symbol: "command")
        case .profiles: palette.present(placeholder: L("Switch to a profile"), symbol: "person.2")
        }
    }

    @objc func openPalette(_ sender: Any?) { showPalette(.commands) }
    @objc func quickSwitchProfile(_ sender: Any?) { showPalette(.profiles) }

    /// Pages to open in a new tab, and open tabs to go back to.
    private func pagesAndTabs(_ text: String) -> [PaletteItem] {
        let query = text.trimmingCharacters(in: .whitespaces)
        var items: [PaletteItem] = []
        let icon: (String) -> NSImage? = { URL(string: $0)?.host.flatMap(Favicons.shared.cached) }
        if query.isEmpty {
            for bookmark in content.startModel.bookmarks.prefix(5) {
                items.append(PaletteItem(title: bookmark.title.isEmpty ? bookmark.url : bookmark.title, detail: AddressBar.pretty(URL(string: bookmark.url)), symbol: "star.fill", icon: icon(bookmark.url)) { [weak self] in
                    URL(string: bookmark.url).map { self?.open($0) }
                })
            }
            if !tabs.profile.isPrivate {
                for row in Store.shared.history(profile: tabs.profile.key, limit: 9 - items.count) where !items.contains(where: { $0.detail == AddressBar.pretty(URL(string: row.url)) }) {
                    items.append(PaletteItem(title: row.title.isEmpty ? row.url : row.title, detail: AddressBar.pretty(URL(string: row.url)), symbol: "clock", icon: icon(row.url)) { [weak self] in
                        URL(string: row.url).map { self?.open($0) }
                    })
                }
            }
            return items
        }
        let direct = Resolver.looksLikeHost(query) || query.contains("://")
        items.append(PaletteItem(title: query, detail: direct ? L("Open") : L("Search with %@", Prefs.shared.engine.name), symbol: direct ? "globe" : "magnifyingglass", hint: "↩") { [weak self] in
            Resolver.url(for: query).map { self?.open($0) }
        })
        for tab in tabs.visible where tab.url != nil && Palette.matches(tab.displayTitle + " " + (tab.url?.absoluteString ?? ""), query) {
            items.append(PaletteItem(title: tab.displayTitle, detail: AddressBar.pretty(tab.url), symbol: "square.on.square", icon: tab.favicon, hint: L("Switch to Tab")) { [weak self] in
                self?.tabs.select(tab)
            })
            if items.count >= 4 { break }
        }
        var seen = Set(tabs.visible.compactMap { $0.url?.absoluteString })
        for suggestion in suggestions(for: query).dropFirst() where seen.insert(suggestion.input).inserted {
            items.append(PaletteItem(title: suggestion.title, detail: suggestion.detail, symbol: suggestion.symbol, icon: suggestion.icon) { [weak self] in
                Resolver.url(for: suggestion.input).map { self?.open($0) }
            })
        }
        return items
    }

    private func profileItems(_ text: String) -> [PaletteItem] {
        let query = text.trimmingCharacters(in: .whitespaces)
        var items = Profiles.shared.all.filter { query.isEmpty || Palette.matches($0.name, query) }.map { profile in
            PaletteItem(title: profile.name, detail: profile === tabs.profile ? L("In front") : "", symbol: profile.symbol,
                        hint: "\(tabs.tabs.filter { $0.profile === profile }.count) " + L("tabs")) { [weak self] in
                self?.tabs.switchProfile(profile)
            }
        }
        if !query.isEmpty, !Profiles.shared.all.contains(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }), !tabs.profile.isPrivate {
            items.append(PaletteItem(title: L("New profile “%@”", query), symbol: "plus.circle") { [weak self] in
                let colors = [0x1DAA61, 0x8E5BE8, 0xE8497F, 0x0A84FF, 0xE8792B, 0x2193B0]
                let count = Profiles.shared.all.count
                let profile = Profiles.shared.add(name: query, symbol: "briefcase.fill", color1: colors[count % colors.count])
                self?.tabs.switchProfile(profile)
            })
        }
        return items
    }

    private func commands(_ text: String) -> [PaletteItem] {
        let query = text.trimmingCharacters(in: .whitespaces)
        let tab = tabs.selected
        let host = tab?.webView?.url?.host
        var all: [PaletteItem] = []
        let add: (String, String, String, @escaping () -> Void) -> Void = { title, symbol, hint, run in
            all.append(PaletteItem(title: title, symbol: symbol, hint: hint, run: run))
        }
        add(L("New Tab"), "plus", "⌘T") { [weak self] in self?.showPalette(.open) }
        add(L("Switch Profile…"), "person.2", "⇧⌘P") { [weak self] in self?.showPalette(.profiles) }
        add(L("New Private Window"), "eyeglasses", "⇧⌘N") { AppDelegate.shared.newPrivateWindow(nil) }
        add(L("New Window"), "macwindow", "⌘N") { AppDelegate.shared.newWindow(nil) }
        if host != nil {
            add(L("Web Inspector"), "hammer", "⌥⌘I") { [weak self] in self?.showInspector(nil) }
            add(L("Device View"), "iphone", "⌥⌘M") { [weak self] in self?.toggleMobileView(nil) }
            add(L("Desktop and Mobile Side by Side"), "rectangle.split.2x1", "") { [weak self] in self?.toggleSplitMobile(nil) }
            add(L("Full Page Screenshot"), "camera.viewfinder", "⇧⌘S") { [weak self] in self?.screenshotFullPage(nil) }
            add(L("Screenshot of the Visible Part"), "camera", "⌥⌘S") { [weak self] in self?.screenshotVisible(nil) }
            add(L("Screenshot of an Element"), "viewfinder", "") { [weak self] in self?.screenshotElement(nil) }
            add(L("Inspect Fonts and Styles"), "textformat", "") { [weak self] in self?.inspectStyles(nil) }
            add(L("Pick a Colour"), "eyedropper", "") { [weak self] in self?.pickColor(nil) }
            for tool in DevPanelModel.Tool.allCases where tool != .styles {
                add(tool.title, tool.symbol, "") { [weak self] in self?.showDevPanel(tool) }
            }
            add(L("Clear This Site's Data"), "trash", "⇧⌘⌫") { [weak self] in self?.clearSiteData(nil) }
            add(tab?.cacheDisabled == true ? L("Use the Cache Again") : L("Disable the Cache"), "bolt.slash", "") { [weak self] in self?.toggleCache(nil) }
            add(tab?.javaScriptDisabled == true ? L("Enable JavaScript") : L("Disable JavaScript"), "curlybraces", "") { [weak self] in self?.toggleJavaScript(nil) }
            add(L("Reload Without Cache"), "arrow.clockwise", "⇧⌘R") { [weak self] in self?.reloadFromOrigin(nil) }
            add(L("View Source"), "doc.plaintext", "⌥⌘U") { [weak self] in self?.viewSource(nil) }
            add(L("Bookmark This Page"), "star", "⌘D") { [weak self] in self?.toggleBookmark(nil) }
            add(L("Pin Tab"), "pin", "") { [weak self] in self?.pinTab(nil) }
            add(L("Fill a Password"), "key", "⌥⌘P") { [weak self] in self?.fillPassword(nil) }
            for environment in SiteEnvironment.allCases {
                add(L("Mark This Site as %@", environment.title), "tag", "") { [weak self] in self?.mark(environment) }
            }
            for agent in UserAgent.presets {
                add(L("User Agent: %@", agent.name), "person.badge.shield.checkmark", "") { [weak self] in self?.tabs.selected?.userAgent = agent.value }
            }
            add(L("User Agent: %@", L("Default")), "person.badge.shield.checkmark", "") { [weak self] in self?.tabs.selected?.userAgent = nil }
        }
        add(L("Reopen Closed Tab"), "arrow.uturn.backward", "⇧⌘T") { [weak self] in self?.reopenClosedTab(nil) }
        add(L("Show or Hide the Sidebar"), "sidebar.left", "⌘S") { [weak self] in self?.toggleSidebar(nil) }
        add(Prefs.shared.tabLayout == "horizontal" ? L("Tabs in Sidebar") : L("Tabs on Top"), "rectangle.topthird.inset.filled", "") { [weak self] in self?.toggleTabLayout(nil) }
        add(L("History"), "clock", "⌘Y") { [weak self] in self?.showHistory(nil) }
        add(L("Downloads"), "arrow.down.circle", "⌥⌘J") { [weak self] in self?.showDownloads(nil) }
        add(L("Settings…"), "gearshape", "⌘,") { SettingsWindow.show(.general) }
        for profile in Profiles.shared.all where profile !== tabs.profile && !tabs.profile.isPrivate {
            all.append(PaletteItem(title: L("Switch to %@", profile.name), symbol: profile.symbol) { [weak self] in self?.tabs.switchProfile(profile) })
        }
        guard !query.isEmpty else { return Array(all.prefix(9)) }
        let matching = all.filter { Palette.matches($0.title, query) }
        // Anything else typed is a tab to go to or a page to open.
        return matching + pagesAndTabs(query).filter { item in !matching.contains { $0.title == item.title } }
    }

    // MARK: Environment

    func mark(_ environment: SiteEnvironment?) {
        guard let host = tabs.selected?.webView?.url?.host ?? tabs.selected?.url?.host else { return }
        SiteEnvironment.set(environment, for: host)
        tabs.selected.map(tabUpdated)
    }

    func environmentMenu() -> NSMenu {
        let menu = NSMenu()
        let current = SiteEnvironment.of(tabs.selected?.url?.host)
        for environment in SiteEnvironment.allCases {
            menu.add(environment.title, checked: current == environment) { [weak self] in self?.mark(environment) }
        }
        menu.separator()
        menu.add(L("None"), checked: current == nil) { [weak self] in self?.mark(nil) }
        return menu
    }

    // MARK: Developer

    func showDevPanel(_ tool: DevPanelModel.Tool) {
        devModel.tool = tool
        if !devPanelVisible {
            devPanelVisible = true
            relayout()
        }
        devModel.pageChanged()
    }

    @objc func toggleDevPanel(_ sender: Any?) {
        devPanelVisible.toggle()
        relayout()
        if devPanelVisible { devModel.pageChanged() }
    }

    @objc func showDevTool(_ sender: NSMenuItem) {
        let tools = DevPanelModel.Tool.allCases
        if sender.tag < tools.count { showDevPanel(tools[sender.tag]) }
    }

    @objc func pickColor(_ sender: Any?) {
        showDevPanel(.styles)
        devModel.pickColor()
    }

    @objc func inspectStyles(_ sender: Any?) {
        showDevPanel(.styles)
        devModel.inspectElement()
    }

    @objc func showConsole(_ sender: Any?) {
        guard let inspector = tabs.selected?.webView?.value(forKey: "_inspector") as? NSObject else { return }
        let selector = Selector(("showConsole"))
        if inspector.responds(to: selector) { inspector.perform(selector) }
    }

    @objc func toggleCache(_ sender: Any?) {
        guard let tab = tabs.selected else { return }
        tab.cacheDisabled.toggle()
        if tab.cacheDisabled { tab.reload(fromOrigin: true) }
    }

    @objc func toggleSplitMobile(_ sender: Any?) {
        guard let tab = tabs.selected, tab.webView?.url != nil else { return }
        tab.setMirror(tab.mirror == nil)
        content.show(tab)
    }

    @objc func chooseUserAgent(_ sender: NSMenuItem) {
        tabs.selected?.userAgent = sender.tag < 0 || sender.tag >= UserAgent.presets.count ? nil : UserAgent.presets[sender.tag].value
    }

    /// Point at an element; its picture goes to the clipboard and to a file.
    @objc func screenshotElement(_ sender: Any?) {
        devModel.pickElement { [weak self] info in
            guard let self, let info, let x = info["x"] as? Double, let y = info["y"] as? Double,
                  let width = info["width"] as? Double, let height = info["height"] as? Double, width > 0, height > 0 else { return }
            self.content.screenshot(of: CGRect(x: x, y: y, width: width, height: height)) { self.saveScreenshot($0) }
        }
    }

    func saveScreenshot(_ image: NSImage?) {
        guard let window, let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        let panel = NSSavePanel()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        panel.nameFieldStringValue = "\(tabs.selected?.url?.host ?? "page") \(stamp.string(from: Date())).png"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        panel.message = L("The screenshot is also on the clipboard.")
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { try? png.write(to: url) }
        }
    }
}
