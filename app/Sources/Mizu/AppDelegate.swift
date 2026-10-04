import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var launched = false
    /// Links that arrived before the windows were up.
    private var pendingURLs: [URL] = []
    private let bookmarksMenu = NSMenu(title: L("Bookmarks"))
    private let profilesMenu = NSMenu(title: L("Profiles"))

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.applyAppearance()
        NSApp.mainMenu = buildMenu()
        Adblock.shared.start()
        TabLifecycle.watchMemoryPressure()
        Downloads.shared.onStart = { [weak self] in self?.frontWindow?.showDownloads(nil) }
        launched = true
        if !(Prefs.shared.restoreSession && restoreSession()) {
            _ = BrowserWindowController(profile: Profiles.shared.all[0]).window?.makeKeyAndOrderFront(nil)
        }
        for url in pendingURLs { open(url) }
        pendingURLs = []
        NSApp.activate(ignoringOtherApps: true)
        if !Prefs.shared.didSetup {
            Prefs.shared.didSetup = true
            SetupWindow.show()
        }
        Updater.shared.start()
        Debug.start()
    }

    /// Reopens the windows of the last run. False when there were none.
    private func restoreSession() -> Bool {
        let session = Store.shared.loadSession()
        var restored = false
        for row in session.windows {
            let tabs = session.tabs.filter { $0.windowId == row.id }
            guard !tabs.isEmpty, let profile = Profiles.shared.profile(row.profileId) ?? Profiles.shared.all.first else { continue }
            let controller = BrowserWindowController(profile: profile, frame: NSRectFromString(row.frame),
                                                     groups: session.groups.filter { $0.windowId == row.id }, tabRows: tabs)
            controller.window?.makeKeyAndOrderFront(nil)
            restored = true
        }
        return restored
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if BrowserWindowController.all.isEmpty, !(Prefs.shared.restoreSession && restoreSession()) { newWindow(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Session.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Opening

    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else { return pendingURLs += urls }
        urls.forEach(open)
    }

    private func open(_ url: URL) {
        if let window = frontWindow {
            window.open(url)
        } else {
            BrowserWindowController(profile: Profiles.shared.all[0], opening: url).window?.makeKeyAndOrderFront(nil)
        }
    }

    /// The browser window in front, private ones included.
    var frontWindow: BrowserWindowController? {
        let all = BrowserWindowController.all
        return all.first { $0.window?.isKeyWindow == true } ?? all.first { $0.window?.isMainWindow == true }
            ?? NSApp.orderedWindows.lazy.compactMap { window in all.first { $0.window === window } }.first
    }

    var currentProfile: Profile {
        if let profile = frontWindow?.tabs.profile, !profile.isPrivate { return profile }
        return Profiles.shared.all[0]
    }

    @objc func newWindow(_ sender: Any?) {
        BrowserWindowController(profile: currentProfile).window?.makeKeyAndOrderFront(nil)
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        BrowserWindowController(profile: .makePrivate()).window?.makeKeyAndOrderFront(nil)
    }

    @objc func newTab(_ sender: Any?) {
        if let window = frontWindow {
            window.window?.makeKeyAndOrderFront(nil)
            window.newTab(nil)
        } else {
            newWindow(nil)
        }
    }

    /// ⌘W closes a tab in a browser window, and any other window whole.
    @objc func closeTabOrWindow(_ sender: Any?) {
        if let key = NSApp.keyWindow, let controller = BrowserWindowController.all.first(where: { $0.window === key }) {
            controller.closeTab(nil)
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { panel.urls.forEach(open) }
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindow.show(.general) }
    @objc func showAbout(_ sender: Any?) { SettingsWindow.show(.about) }

    @objc func checkForUpdates(_ sender: Any?) {
        SettingsWindow.show(.about)
        Updater.shared.check()
    }

    @objc func openRepository(_ sender: Any?) {
        open(URL(string: "https://github.com/mdenizay/mizu-browser")!)
    }

    func relaunch() {
        Session.saveNow()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", Bundle.main.bundleURL.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Default browser

    static var isDefaultBrowser: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks the system to make Mizu the default browser (it confirms with the user).
    static func makeDefaultBrowser(completion: @escaping () -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http") { _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    // MARK: Menu

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private func buildMenu() -> NSMenu {
        typealias W = BrowserWindowController
        let main = NSMenu()
        let services = NSMenu(title: L("Services"))
        NSApp.servicesMenu = services
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services

        main.addItem(menu("Mizu", [
            item(L("About Mizu"), #selector(showAbout(_:))),
            item(L("Check for Updates…"), #selector(checkForUpdates(_:))),
            .separator(),
            item(L("Settings…"), #selector(showSettings(_:)), ","),
            .separator(),
            servicesItem,
            .separator(),
            item(L("Hide Mizu"), #selector(NSApplication.hide(_:)), "h"),
            item(L("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item(L("Show All"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(L("Quit Mizu"), #selector(NSApplication.terminate(_:)), "q"),
        ]))

        main.addItem(menu(L("File"), [
            item(L("New Tab"), #selector(newTab(_:)), "t"),
            item(L("New Window"), #selector(newWindow(_:)), "n"),
            item(L("New Private Window"), #selector(newPrivateWindow(_:)), "n", [.command, .shift]),
            item(L("Open File…"), #selector(openFile(_:)), "o"),
            item(L("Open Location…"), #selector(W.focusAddressBar(_:)), "l"),
            item(L("Command Palette…"), #selector(W.openPalette(_:)), "k"),
            item(L("Switch Profile…"), #selector(W.quickSwitchProfile(_:)), "p", [.command, .shift]),
            .separator(),
            item(L("Close Tab"), #selector(closeTabOrWindow(_:)), "w"),
            item(L("Close Window"), #selector(NSWindow.performClose(_:)), "w", [.command, .shift]),
            item(L("Reopen Closed Tab"), #selector(W.reopenClosedTab(_:)), "t", [.command, .shift]),
            .separator(),
            item(L("Save as PDF…"), #selector(W.savePDF(_:))),
            item(L("Print…"), #selector(W.printPage(_:)), "p"),
        ]))

        main.addItem(menu(L("Edit"), [
            item(L("Undo"), Selector(("undo:")), "z"),
            item(L("Redo"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("Cut"), #selector(NSText.cut(_:)), "x"),
            item(L("Copy"), #selector(NSText.copy(_:)), "c"),
            item(L("Paste"), #selector(NSText.paste(_:)), "v"),
            item(L("Paste and Match Style"), #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
            item(L("Select All"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item(L("Copy Page Address"), #selector(W.copyAddress(_:)), "c", [.command, .shift]),
            item(L("Fill a Password"), #selector(W.fillPassword(_:)), "p", [.command, .option]),
            .separator(),
            item(L("Find…"), #selector(W.findInPage(_:)), "f"),
            item(L("Find Next"), #selector(W.findNext(_:)), "g"),
            item(L("Find Previous"), #selector(W.findPrevious(_:)), "g", [.command, .shift]),
        ]))

        main.addItem(menu(L("View"), [
            item(L("Reload"), #selector(W.reloadPage(_:)), "r"),
            item(L("Reload Without Cache"), #selector(W.reloadFromOrigin(_:)), "r", [.command, .shift]),
            item(L("Stop"), #selector(W.stopLoading(_:)), "."),
            .separator(),
            item(L("Zoom In"), #selector(W.zoomIn(_:)), "+"),
            item(L("Zoom Out"), #selector(W.zoomOut(_:)), "-"),
            item(L("Actual Size"), #selector(W.zoomReset(_:)), "0"),
            .separator(),
            item(L("Show or Hide the Sidebar"), #selector(W.toggleSidebar(_:)), "s"),
            item(L("Tabs on Top"), #selector(W.toggleTabLayout(_:))),
            .separator(),
            item(L("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]))

        main.addItem(menu(L("History"), [
            item(L("Back"), #selector(W.goBack(_:)), "["),
            item(L("Forward"), #selector(W.goForward(_:)), "]"),
            .separator(),
            item(L("Show History"), #selector(W.showHistory(_:)), "y"),
            item(L("Downloads"), #selector(W.showDownloads(_:)), "j", [.command, .option]),
        ]))

        bookmarksMenu.delegate = self
        let bookmarks = NSMenuItem(title: L("Bookmarks"), action: nil, keyEquivalent: "")
        bookmarks.submenu = bookmarksMenu
        main.addItem(bookmarks)

        var tabItems = [
            item(L("Next Tab"), #selector(W.nextTab(_:)), "\t", [.control]),
            item(L("Previous Tab"), #selector(W.previousTab(_:)), "\t", [.control, .shift]),
            .separator(),
            item(L("Pin Tab"), #selector(W.pinTab(_:))),
            item(L("Duplicate Tab"), #selector(W.duplicateTab(_:))),
            item(L("Add Tab to New Group…"), #selector(W.groupTab(_:)), "g", [.command, .option]),
            NSMenuItem.separator(),
        ]
        for number in 1...9 {
            tabItems.append(item(number == 9 ? L("Last Tab") : L("Tab %d", number), #selector(W.selectTabByNumber(_:)), "\(number)", tag: number - 1))
        }
        main.addItem(menu(L("Tabs"), tabItems))

        profilesMenu.delegate = self
        let profiles = NSMenuItem(title: L("Profiles"), action: nil, keyEquivalent: "")
        profiles.submenu = profilesMenu
        main.addItem(profiles)

        var agents = [item(L("Default"), #selector(W.chooseUserAgent(_:)), tag: -1), NSMenuItem.separator()]
        for (index, agent) in UserAgent.presets.enumerated() { agents.append(item(agent.name, #selector(W.chooseUserAgent(_:)), tag: index)) }
        var environments = SiteEnvironment.allCases.enumerated().map { item($1.title, #selector(W.markEnvironment(_:)), tag: $0) }
        environments += [.separator(), item(L("None"), #selector(W.markEnvironment(_:)), tag: 99)]
        var audits: [NSMenuItem] = []
        for (index, tool) in DevPanelModel.Tool.allCases.enumerated() { audits.append(item(tool.title, #selector(W.showDevTool(_:)), tag: index)) }

        main.addItem(menu(L("Develop"), [
            item(L("Web Inspector"), #selector(W.showInspector(_:)), "i", [.command, .option]),
            item(L("JavaScript Console"), #selector(W.showConsole(_:)), "c", [.command, .option]),
            item(L("View Source"), #selector(W.viewSource(_:)), "u", [.command, .option]),
            .separator(),
            item(L("Device View"), #selector(W.toggleMobileView(_:)), "m", [.command, .option]),
            item(L("Desktop and Mobile Side by Side"), #selector(W.toggleSplitMobile(_:)), "m", [.command, .option, .shift]),
            menu(L("User Agent"), agents),
            .separator(),
            item(L("Developer Panel"), #selector(W.toggleDevPanel(_:)), "d", [.command, .option]),
        ] + audits + [
            item(L("Inspect Fonts and Styles"), #selector(W.inspectStyles(_:))),
            item(L("Pick a Colour"), #selector(W.pickColor(_:))),
            .separator(),
            item(L("Full Page Screenshot"), #selector(W.screenshotFullPage(_:)), "s", [.command, .shift]),
            item(L("Screenshot of the Visible Part"), #selector(W.screenshotVisible(_:)), "s", [.command, .option]),
            item(L("Screenshot of an Element"), #selector(W.screenshotElement(_:)), "s", [.command, .option, .shift]),
            .separator(),
            menu(L("Environment"), environments),
            item(L("Disable the Cache"), #selector(W.toggleCache(_:))),
            item(L("Disable JavaScript"), #selector(W.toggleJavaScript(_:))),
            item(L("Clear This Site's Data"), #selector(W.clearSiteData(_:)), "\u{8}", [.command, .shift]),
        ]))

        let window = NSMenu(title: L("Window"))
        window.addItem(item(L("Minimise"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(L("Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(L("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = window
        let windowItem = NSMenuItem(title: L("Window"), action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)

        let help = NSMenu(title: L("Help"))
        help.addItem(item(L("Mizu on GitHub"), #selector(openRepository(_:))))
        NSApp.helpMenu = help
        let helpItem = NSMenuItem(title: L("Help"), action: nil, keyEquivalent: "")
        helpItem.submenu = help
        main.addItem(helpItem)
        return main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === bookmarksMenu {
            menu.addItem(item(L("Bookmark This Page"), #selector(BrowserWindowController.toggleBookmark(_:)), "d"))
            menu.addItem(.separator())
            let profile = currentProfile
            for bookmark in Store.shared.bookmarks(profile: profile.key) {
                let entry = menu.add(bookmark.title.isEmpty ? bookmark.url : bookmark.title) { [weak self] in
                    if let url = URL(string: bookmark.url) { self?.open(url) }
                }
                entry.image = URL(string: bookmark.url)?.host.flatMap(Favicons.shared.cached)
            }
        } else if menu === profilesMenu {
            for (index, profile) in Profiles.shared.all.enumerated() {
                let entry = item(profile.name, #selector(BrowserWindowController.switchProfileByNumber(_:)), index < 9 ? "\(index + 1)" : "", [.control], tag: index)
                entry.image = NSImage(systemSymbolName: profile.symbol, accessibilityDescription: nil)
                entry.state = frontWindow?.tabs.profile === profile ? .on : .off
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            menu.add(L("Manage Profiles…")) { SettingsWindow.show(.profiles) }
        }
    }

    // The key equivalents of these menus must work before they are first opened.
    func menuHasKeyEquivalent(_ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>, action: UnsafeMutablePointer<Selector?>) -> Bool {
        guard let characters = event.charactersIgnoringModifiers else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if menu === bookmarksMenu, characters == "d", flags == .command {
            action.pointee = #selector(BrowserWindowController.toggleBookmark(_:))
            return true
        }
        if menu === profilesMenu, flags == .control, let number = Int(characters), number >= 1, number <= Profiles.shared.all.count {
            frontWindow?.tabs.switchProfile(Profiles.shared.all[number - 1])
            action.pointee = nil
            return true
        }
        return false
    }
}

/// First-run setup: the few choices that shape the app, a page at a time.
enum SetupWindow {
    private static var window: NSWindow?

    static func show() {
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 500), styleMask: [.titled, .closable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        created.titlebarAppearsTransparent = true
        created.isReleasedWhenClosed = false
        created.contentViewController = NSHostingController(rootView: SetupView { window?.close() })
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}

private struct SetupView: View {
    let done: () -> Void
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var profile = AppDelegate.shared.currentProfile
    @State private var page = 0
    @State private var isDefault = AppDelegate.isDefaultBrowser
    private static let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: step(L("Pick your colours"), L("Drag the dot, or add a second one for a gradient. Each profile has its own.")) { ThemePicker(profile: profile) }
                case 2: step(L("Tabs and search"), L("Where the tabs go, and where searches are sent.")) { layout }
                default: step(L("Privacy"), L("Ads and trackers are blocked from the start.")) { privacy }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28).padding(.top, 34)
            HStack {
                Button(page > 0 ? L("Back") : L("Skip")) { if page > 0 { page -= 1 } else { done() } }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<Self.pages, id: \.self) { index in
                        Circle().fill(index == page ? AnyShapeStyle(Color(hex: profile.color1)) : AnyShapeStyle(.quaternary)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == Self.pages - 1 ? L("Done") : L("Continue")) {
                    if page == Self.pages - 1 { done() } else { page += 1 }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 460, height: 500)
        .toggleStyle(RowToggleStyle())
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L("Welcome to Mizu")).font(.title.weight(.bold))
            Text(L("A calm, light browser for your Mac. Let's set it up the way you like it; everything here can be changed later in Settings."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func step(_ title: String, _ subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary).padding(.bottom, 12)
            content()
        }
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(L("Tabs"), selection: $prefs.tabLayout) {
                Label(L("In a sidebar"), systemImage: "sidebar.left").tag("vertical")
                Label(L("Along the top"), systemImage: "rectangle.topthird.inset.filled").tag("horizontal")
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker(L("Search Engine"), selection: $prefs.searchEngine) {
                ForEach(SearchEngine.all) { Text($0.name).tag($0.id) }
            }
            HStack {
                Text(isDefault ? L("Mizu is your default browser.") : L("Open links from other apps in Mizu?"))
                Spacer()
                if !isDefault {
                    Button(L("Make Default")) { AppDelegate.makeDefaultBrowser { isDefault = AppDelegate.isDefaultBrowser } }
                }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("Block ads and trackers"), isOn: $prefs.adblock)
            Toggle(L("Hide the empty spaces ads leave behind"), isOn: $prefs.cosmetic).disabled(!prefs.adblock)
            Text(L("Passwords come from the Passwords app: on a sign-in page, click the key in the address bar. Profiles keep work and personal sign-ins apart; switch between them at the bottom of the sidebar."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
