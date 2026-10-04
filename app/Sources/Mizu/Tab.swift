import AppKit
import WebKit

/// A screen to imitate in the device view: a phone or tablet (with its user
/// agent), or simply a window width to test a breakpoint at.
struct Device: Equatable {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let userAgent: String?

    var rotated: Device { Device(name: name, width: height, height: width, userAgent: userAgent) }

    private static let iPhone = UserAgent.iPhone
    private static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"
    private static let android = "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36"

    static let presets = [
        Device(name: "iPhone SE", width: 375, height: 667, userAgent: iPhone),
        Device(name: "iPhone 15", width: 393, height: 852, userAgent: iPhone),
        Device(name: "iPhone 16 Pro Max", width: 440, height: 956, userAgent: iPhone),
        Device(name: "Pixel 9", width: 412, height: 915, userAgent: android),
        Device(name: "Galaxy S24", width: 360, height: 780, userAgent: android),
        Device(name: "iPad mini", width: 744, height: 1133, userAgent: iPad),
        Device(name: "iPad Air", width: 820, height: 1180, userAgent: iPad),
        Device(name: "Laptop 1280", width: 1280, height: 800, userAgent: nil),
        Device(name: "Desktop 1440", width: 1440, height: 900, userAgent: nil),
        Device(name: "Desktop 1920", width: 1920, height: 1080, userAgent: nil),
    ]

    /// A size typed in by hand, or one of the saved breakpoints.
    static func custom(width: CGFloat, height: CGFloat) -> Device {
        Device(name: "\(Int(width)) × \(Int(height))", width: min(max(width, 240), 3840), height: min(max(height, 240), 2400), userAgent: nil)
    }

    /// The breakpoints saved in the settings ("1024x768"), as devices.
    static var saved: [Device] {
        Prefs.shared.viewports.compactMap { text in
            let parts = text.split(separator: "x").compactMap { Double($0) }
            return parts.count == 2 ? custom(width: parts[0], height: parts[1]) : nil
        }
    }
}

/// User agents to pass a page off as another browser, or as a crawler.
enum UserAgent {
    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    static let presets: [(name: String, value: String)] = [
        ("Safari — iPhone", iPhone),
        ("Chrome — Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"),
        ("Chrome — macOS", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"),
        ("Chrome — Android", "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36"),
        ("Firefox — Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0"),
        ("Edge — Windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36 Edg/138.0.0.0"),
        ("Googlebot", "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
        ("Googlebot — Smartphone", "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Mobile Safari/537.36 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"),
        ("Bingbot", "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"),
        ("Facebook link preview", "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"),
    ]
}

/// The web view of a tab: WKWebView with a context menu that speaks of tabs.
final class MizuWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "WKMenuItemIdentifierOpenLinkInNewWindow": item.title = L("Open Link in New Tab")
            case "WKMenuItemIdentifierOpenImageInNewWindow": item.title = L("Open Image in New Tab")
            case "WKMenuItemIdentifierOpenFrameInNewWindow": item.title = L("Open Frame in New Tab")
            case "WKMenuItemIdentifierOpenMediaInNewWindow": item.title = L("Open Video in New Tab")
            default: break
            }
        }
        super.willOpenMenu(menu, with: event)
    }
}

/// Passes script messages on without keeping the tab alive.
private final class MessageRelay: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    weak var tab: Tab?

    init(_ tab: Tab) { self.tab = tab }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        tab?.received(message)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let tab else { return replyHandler(nil, nil) }
        tab.received(message, reply: replyHandler)
    }
}

/// One tab. It always knows its address and title; the web view behind it
/// exists only while the tab is loaded, and is dropped when the tab is put to
/// sleep (see `TabLifecycle`).
final class Tab: NSObject {
    let id: UUID
    let profile: Profile
    weak var manager: TabManager?

    private(set) var url: URL?
    private(set) var title = ""
    private(set) var favicon: NSImage?
    var groupID: UUID?
    var pinned = false
    var lastActive = Date()

    private(set) var webView: MizuWebView?
    /// The back/forward list of a sleeping tab.
    private var savedState: Data?
    private var observations: [NSKeyValueObservation] = []
    private var cosmeticExceptions: [String] = []

    /// The screen being imitated, when the mobile view is on.
    var device: Device? { didSet { deviceChanged(from: oldValue) } }
    var javaScriptDisabled = false
    /// A user agent chosen in the Develop menu (a device's own wins over it).
    var userAgent: String? { didSet { applyUserAgent(reload: true) } }
    /// Fetch pages and what they load afresh, past the cache.
    var cacheDisabled = false
    /// CSS added to the page for the time being (Develop ▸ CSS Override).
    var customCSS = "" { didSet { applyCSS() } }
    /// A second, phone-sized view of the same page, shown beside it.
    private(set) var mirror: Tab?
    private var isMirror = false
    /// The address the mirror was last sent to by the page it follows.
    private var followed: URL?
    /// What the blocker stopped on this page, newest last.
    private(set) var blockedURLs: [String] = []
    /// Requests blocked on the page being shown.
    private(set) var blocked = 0
    /// The page has a sign-in form, and which of its fields.
    private(set) var hasLoginForm = false
    private(set) var loginFields = (user: false, pass: false)
    private(set) var isPlayingAudio = false

    static let scriptWorld = WKContentWorld.world(name: "Mizu")
    private static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob", "file", "javascript"]

    init(profile: Profile, id: UUID = UUID(), url: URL? = nil, title: String = "", state: Data? = nil) {
        self.id = id
        self.profile = profile
        self.url = url
        self.title = title
        savedState = state
        super.init()
        if let host = url?.host { favicon = Favicons.shared.cached(host) }
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if let url { return url.host ?? url.absoluteString }
        return L("New Tab")
    }

    var isLoaded: Bool { webView != nil }
    var isLoading: Bool { webView?.isLoading ?? false }
    var progress: Double { webView?.estimatedProgress ?? 0 }
    var canGoBack: Bool { webView?.canGoBack ?? false }
    var canGoForward: Bool { webView?.canGoForward ?? false }
    var isSecure: Bool { webView?.hasOnlySecureContent ?? (url?.scheme == "https") }
    var sessionState: Data? { (webView?.interactionState as? Data) ?? savedState }

    // MARK: Web view

    static func configuration(for profile: Profile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.dataStore
        // Sites decide what to serve from the user agent; look like the Safari
        // that ships with this version of WebKit.
        let system = ProcessInfo.processInfo.operatingSystemVersion
        configuration.applicationNameForUserAgent = "Version/\(system.majorVersion).\(system.minorVersion) Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.allowsAirPlayForMediaPlayback = true
        return configuration
    }

    /// The tab's web view, made (and its page loaded) on first use.
    @discardableResult
    func load(configuration: WKWebViewConfiguration? = nil) -> MizuWebView {
        if let webView { return webView }
        let configuration = configuration ?? Self.configuration(for: profile)
        // A window opened by a page arrives with its opener's configuration;
        // give it scripts and rules of its own.
        let controller = WKUserContentController()
        configuration.userContentController = controller
        let relay = MessageRelay(self)
        controller.addScriptMessageHandler(relay, contentWorld: Self.scriptWorld, name: "mizuHide")
        controller.add(relay, contentWorld: Self.scriptWorld, name: "mizuPage")

        let webView = MizuWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.customUserAgent = device?.userAgent ?? userAgent
        self.webView = webView
        installScripts(nil)
        Adblock.shared.configure(controller, host: url?.host)

        observations = [
            webView.observe(\.title) { [weak self] view, _ in self?.titleChanged(view.title ?? "") },
            webView.observe(\.url) { [weak self] view, _ in self?.urlChanged(view.url) },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self.map { $0.manager?.tabProgressed($0) } },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.notify() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.notify() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.notify() },
        ]
        webView.addObserver(self, forKeyPath: "_isPlayingAudio", options: [.new], context: nil)

        if let savedState {
            webView.interactionState = savedState
            self.savedState = nil
        } else if let url {
            open(url)
        }
        return webView
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard keyPath == "_isPlayingAudio" else { return }
        isPlayingAudio = change?[.newKey] as? Bool ?? false
        notify()
    }

    /// Navigates the tab.
    func open(_ url: URL) {
        self.url = url
        let webView = load()
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
        notify()
    }

    /// Whether the tab may be put to sleep: not while it is making sound,
    /// using the camera or microphone, or imitating a device.
    var canSleep: Bool {
        guard let webView else { return false }
        return !isPlayingAudio && device == nil && mirror == nil && webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
    }

    /// Drops the web view (and with it the page's process), keeping what is
    /// needed to bring the page back.
    func sleep() {
        guard let webView else { return }
        savedState = webView.interactionState as? Data
        url = webView.url ?? url
        observations = []
        webView.removeObserver(self, forKeyPath: "_isPlayingAudio")
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        self.webView = nil
        mirror?.discard()
        mirror = nil
        isPlayingAudio = false
        hasLoginForm = false
        blocked = 0
    }

    /// Called when the tab is closed.
    func discard() {
        webView?.stopLoading()
        sleep()
        savedState = nil
    }

    func reload(fromOrigin: Bool = false) {
        guard let webView else { return }
        if webView.url == nil, let url { return open(url) }
        if fromOrigin { webView.reloadFromOrigin() } else { webView.reload() }
    }

    func showInspector() {
        guard let inspector = load().value(forKey: "_inspector") as? NSObject else { return }
        let show = Selector(("show"))
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    private func deviceChanged(from old: Device?) {
        if device == nil { webView?.pageZoom = 1 }
        guard old?.userAgent != device?.userAgent else { return }
        applyUserAgent(reload: true)
    }

    private func applyUserAgent(reload: Bool) {
        guard let webView else { return }
        let wanted = device?.userAgent ?? userAgent
        guard webView.customUserAgent != (wanted ?? "") else { return }
        webView.customUserAgent = wanted
        if reload { webView.reload() }
    }

    /// Shows or hides the phone-sized view beside the page.
    func setMirror(_ on: Bool) {
        if on, mirror == nil, let url {
            let tab = Tab(profile: profile, url: url)
            tab.isMirror = true
            tab.device = Device.presets[1]
            tab.load()
            mirror = tab
        } else if !on {
            mirror?.discard()
            mirror = nil
        }
    }

    private func applyCSS() {
        guard let webView, let data = try? JSONSerialization.data(withJSONObject: [customCSS]), let literal = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
        (() => {
          let style = document.getElementById('mizu-css-override');
          if (!style) { style = document.createElement('style'); style.id = 'mizu-css-override'; document.documentElement.appendChild(style); }
          style.textContent = \(literal)[0];
        })()
        """, in: nil, in: Self.scriptWorld) { _ in }
    }

    // MARK: State

    private func notify() {
        manager?.tabUpdated(self)
    }

    private func titleChanged(_ new: String) {
        guard !new.isEmpty, new != title else { return }
        title = new
        if !profile.isPrivate, let url, url.scheme?.hasPrefix("http") == true {
            Store.shared.setTitle(profile: profile.key, url: url.absoluteString, title: new)
        }
        notify()
    }

    private func urlChanged(_ new: URL?) {
        guard let new, new != url else { return }
        if new.host != url?.host {
            favicon = new.host.flatMap(Favicons.shared.cached)
        }
        url = new
        notify()
    }

    private func loadFavicon() {
        guard let webView, let page = webView.url, let host = page.host, page.scheme?.hasPrefix("http") == true else { return }
        let script = """
        (() => {
          const links = [...document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]')];
          const best = links.find(l => /apple-touch/.test(l.rel)) || links.find(l => /(64|96|128|180|192)/.test(l.sizes?.value || '')) || links[links.length - 1];
          return best ? best.href : '';
        })()
        """
        webView.evaluateJavaScript(script) { [weak self] result, _ in
            var candidates = [URL]()
            if let link = result as? String, let url = URL(string: link) { candidates.append(url) }
            if let fallback = URL(string: "\(page.scheme!)://\(host)/favicon.ico") { candidates.append(fallback) }
            Favicons.shared.fetch(host: host, candidates: candidates) { image in
                guard let self, let image, self.url?.host == host else { return }
                self.favicon = image
                self.notify()
            }
        }
    }

    // MARK: Scripts

    /// Sets the scripts that run in the next page: the blocker's, shaped to
    /// that page, and the one that looks for a sign-in form.
    private func installScripts(_ cosmetics: Cosmetics?) {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeAllUserScripts()
        cosmeticExceptions = cosmetics?.exceptions ?? []
        if let cosmetics {
            if !cosmetics.script.isEmpty {
                controller.addUserScript(WKUserScript(source: "try {\n\(cosmetics.script)\n} catch (e) {}", injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
            }
            if !cosmetics.selectors.isEmpty {
                controller.addUserScript(WKUserScript(source: Adblock.hidingScript(cosmetics.selectors), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.scriptWorld))
            }
            if !cosmetics.genericHide {
                controller.addUserScript(WKUserScript(source: Adblock.collectorScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.scriptWorld))
            }
        }
        controller.addUserScript(WKUserScript(source: Passwords.detectorScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.scriptWorld))
    }

    fileprivate func received(_ message: WKScriptMessage) {
        guard message.name == "mizuPage", let body = message.body as? [String: Any] else { return }
        if let login = body["login"] as? Bool {
            hasLoginForm = login
            loginFields = (body["user"] as? Bool ?? false, body["pass"] as? Bool ?? false)
            notify()
        }
    }

    fileprivate func received(_ message: WKScriptMessage, reply: @escaping (Any?, String?) -> Void) {
        guard message.name == "mizuHide", let body = message.body as? [String: Any] else { return reply(nil, nil) }
        Adblock.shared.hiddenSelectors(classes: body["classes"] as? [String] ?? [], ids: body["ids"] as? [String] ?? [],
                                       exceptions: cosmeticExceptions) { reply($0, nil) }
    }

    /// WebKit reports each request a content rule list acted on (not public
    /// API, so this is simply never called should it go away).
    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func webView(_ webView: WKWebView, contentRuleListWithIdentifier identifier: String, performedAction action: NSObject, forURL url: URL) {
        guard action.responds(to: Selector(("blockedLoad"))), action.value(forKey: "blockedLoad") as? Bool == true else { return }
        blocked += 1
        if blockedURLs.count < 400 { blockedURLs.append(url.absoluteString) }
        manager?.tabBlockedCountChanged(self)
    }

    private func showError(_ error: Error, in webView: WKWebView) {
        let error = error as NSError
        // Cancelled loads, and loads that turned into downloads, are not errors.
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204)) { return }
        guard let failed = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? url else { return }
        let escape: (String) -> String = { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <title>\(escape(failed.host ?? failed.absoluteString))</title><style>
        body { font: 15px -apple-system, sans-serif; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
        main { max-width: 460px; padding: 24px; }
        h1 { font-size: 22px; margin: 0 0 8px; }
        p { opacity: .7; line-height: 1.5; margin: 0 0 20px; word-break: break-word; }
        button { font: inherit; padding: 7px 16px; border-radius: 8px; border: 0; background: #0a84ff; color: white; }
        </style></head><body><main>
        <h1>\(escape(L("This page can't be opened")))</h1>
        <p>\(escape(error.localizedDescription))<br>\(escape(failed.absoluteString))</p>
        <button onclick="location.reload()">\(escape(L("Try Again")))</button>
        </main></body></html>
        """
        webView.loadSimulatedRequest(URLRequest(url: failed), responseHTML: html)
    }
}

// MARK: - Navigation

extension Tab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let target = action.request.url else { return decisionHandler(.cancel, preferences) }
        guard Self.webSchemes.contains(target.scheme?.lowercased() ?? "") else {
            // mailto:, tel: and other apps' links.
            if action.navigationType == .linkActivated || action.targetFrame?.isMainFrame != false { NSWorkspace.shared.open(target) }
            return decisionHandler(.cancel, preferences)
        }
        if action.shouldPerformDownload { return decisionHandler(.download, preferences) }
        // ⌘-click and middle click open the link in a new tab (⇧ brings it forward).
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber == 4 {
            manager?.newTab(url: target, select: action.modifierFlags.contains(.shift), after: self)
            return decisionHandler(.cancel, preferences)
        }
        guard action.targetFrame?.isMainFrame == true else { return decisionHandler(.allow, preferences) }
        // With the cache off, a page that would come from it is asked for again.
        if cacheDisabled, action.request.httpMethod ?? "GET" == "GET", action.request.cachePolicy != .reloadIgnoringLocalCacheData,
           target.scheme?.hasPrefix("http") == true, action.navigationType != .backForward {
            decisionHandler(.cancel, preferences)
            var fresh = action.request
            fresh.cachePolicy = .reloadIgnoringLocalCacheData
            webView.load(fresh)
            return
        }
        preferences.allowsContentJavaScript = !javaScriptDisabled
        preferences.preferredContentMode = device?.userAgent != nil ? .mobile : .recommended
        Adblock.shared.configure(webView.configuration.userContentController, host: target.host)
        Adblock.shared.cosmetics(for: target) { [weak self] cosmetics in
            self?.installScripts(cosmetics)
            decisionHandler(.allow, preferences)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        if !response.canShowMIMEType || disposition.lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        Downloads.shared.adopt(download, from: self)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        blocked = 0
        blockedURLs = []
        hasLoginForm = false
        if let mirror, let url = webView.url, mirror.url != url, mirror.followed != url {
            mirror.followed = url
            mirror.open(url)
        }
        manager?.tabBlockedCountChanged(self)
        notify()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !customCSS.isEmpty { applyCSS() }
        if !profile.isPrivate, !isMirror, let url = webView.url, url.scheme?.hasPrefix("http") == true {
            Store.shared.recordVisit(profile: profile.key, url: url.absoluteString, title: webView.title ?? "")
        }
        loadFavicon()
        notify()
        Session.scheduleSave()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError(error, in: webView)
        notify()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        notify()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM].contains(space.authenticationMethod),
              challenge.previousFailureCount < 3, let window = webView.window else {
            return completionHandler(.performDefaultHandling, nil)
        }
        let alert = NSAlert()
        alert.messageText = L("Sign in to %@", space.host)
        alert.informativeText = space.realm ?? ""
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 240, height: 24))
        user.placeholderString = L("User name")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        password.placeholderString = L("Password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        user.nextKeyView = password
        alert.accessoryView = fields
        alert.addButton(withTitle: L("Sign In"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = user
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                completionHandler(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}

// MARK: - Page requests

extension Tab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let manager else { return nil }
        let tab = manager.newTab(url: nil, select: !action.modifierFlags.contains(.command), after: self, loading: false)
        return tab.load(configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        manager?.close(self)
    }

    private func sheet(_ alert: NSAlert, for webView: WKWebView, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        // A page in a background tab may not interrupt the one in front.
        guard let window = webView.window else { return completion(.cancel) }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        sheet(alert, for: webView) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        sheet(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        sheet(alert, for: webView) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        guard let window = webView.window else { return completionHandler(nil) }
        panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let alert = NSAlert()
        switch type {
        case .camera: alert.messageText = L("Allow %@ to use your camera?", origin.host)
        case .microphone: alert.messageText = L("Allow %@ to use your microphone?", origin.host)
        default: alert.messageText = L("Allow %@ to use your camera and microphone?", origin.host)
        }
        alert.addButton(withTitle: L("Allow"))
        alert.addButton(withTitle: L("Don't Allow"))
        sheet(alert, for: webView) { decisionHandler($0 == .alertFirstButtonReturn ? .grant : .deny) }
    }
}

/// Site icons, kept small, in memory and in the caches folder.
final class Favicons {
    static let shared = Favicons()
    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.mdenizay.mizu/favicons")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private var pending: Set<String> = []
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    private init() { memory.countLimit = 300 }

    private func file(_ host: String) -> URL {
        directory.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    func cached(_ host: String) -> NSImage? {
        if let image = memory.object(forKey: host as NSString) { return image }
        guard let image = NSImage(contentsOf: file(host)) else { return nil }
        memory.setObject(image, forKey: host as NSString)
        return image
    }

    /// Fetches the first of the candidates that is an image, at most once per
    /// host per launch.
    func fetch(host: String, candidates: [URL], completion: @escaping (NSImage?) -> Void) {
        if pending.contains(host) { return completion(cached(host)) }
        pending.insert(host)
        Task {
            var found: NSImage?
            for url in candidates {
                guard let (data, _) = try? await session.data(from: url), let image = NSImage(data: data), image.size.width > 0 else { continue }
                // 32 pixels is all a tab shows; keep no more than that.
                let small = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                    NSGraphicsContext.current?.imageInterpolation = .high
                    image.draw(in: rect)
                    return true
                }
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                if let bitmap {
                    bitmap.size = NSSize(width: 16, height: 16)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                    small.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                    NSGraphicsContext.restoreGraphicsState()
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: file(host))
                    let result = NSImage(size: NSSize(width: 16, height: 16))
                    result.addRepresentation(bitmap)
                    found = result
                }
                break
            }
            let image = found
            await MainActor.run {
                if let image { self.memory.setObject(image, forKey: host as NSString) }
                completion(image)
            }
        }
    }
}
