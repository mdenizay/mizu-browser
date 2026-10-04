import AppKit
import WebKit

/// Working with the system's Passwords app.
///
/// macOS offers "AutoFill ▸ Passwords…" (the Passwords picker, behind Touch
/// ID) to native text fields only; it is switched off while a field of a web
/// page has the focus. So the key in the address bar opens a small native
/// sign-in panel: Passwords fills that, and Mizu passes what was filled on to
/// the form in the page. What is filled can be kept with the profile (see
/// `Vault`), so that a client's accounts are a click away in that client's
/// profile and nowhere else.
enum Passwords {
    /// Finds the sign-in fields of a page: `{ user, pass }`, either possibly null.
    private static let findFields = """
    const mizuFields = () => {
      const visible = el => el.offsetParent !== null && !el.disabled && !el.readOnly;
      const pass = [...document.querySelectorAll('input[type="password"]')].find(visible) || null;
      const named = el => /user|login|identifier|e-?mail|account|kullanici/i.test((el.name || '') + ' ' + (el.id || '') + ' ' + (el.autocomplete || ''));
      const texts = [...(pass && pass.form ? pass.form : document).querySelectorAll('input[type="text"], input[type="email"], input[type="tel"], input:not([type])')].filter(visible);
      let user = texts.find(el => /username|email/.test(el.autocomplete || '')) || texts.find(named) || null;
      // Beside a password field, the text field before it is the user name.
      if (!user && pass) user = texts.filter(el => el.compareDocumentPosition(pass) & Node.DOCUMENT_POSITION_FOLLOWING).pop() || null;
      // Without one, only a field that says it takes a user name counts.
      if (user && !pass && !/username/.test(user.autocomplete || '') && !/user|login|identifier/i.test((user.name || '') + (user.id || ''))) user = null;
      return { user, pass };
    };
    """

    /// Tells the tab when its page has a sign-in form, so that the key can be
    /// offered in the address bar.
    static let detectorScript = """
    (() => {
      if (window !== window.top) return;
      \(findFields)
      let last = '', timer = 0;
      const report = () => {
        timer = 0;
        const { user, pass } = mizuFields();
        const state = (user ? 'u' : '') + (pass ? 'p' : '');
        if (state === last) return;
        last = state;
        window.webkit.messageHandlers.mizuPage.postMessage({ login: !!(user || pass), user: !!user, pass: !!pass });
      };
      report();
      new MutationObserver(() => { if (!timer) timer = setTimeout(report, 500); })
        .observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'style', 'class', 'hidden'] });
    })();
    """

    /// Types the values into the page's sign-in form, the way a person would
    /// as far as the page's scripts can tell.
    private static let fillScript = """
    \(findFields)
    const set = (el, value) => {
      el.focus();
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, value);
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    };
    const fields = mizuFields();
    if (user && fields.user) set(fields.user, user);
    if (pass && fields.pass) set(fields.pass, pass);
    return !!(fields.user || fields.pass);
    """

    /// The system command behind Edit ▸ AutoFill ▸ Passwords…
    static let pickerAction = Selector(("_handleInsertFromPasswordsCommand:"))

    /// Opens the sign-in panel for the page in a tab, under `anchor`.
    static func offer(for tab: Tab, from anchor: NSView) {
        guard let webView = tab.webView, let host = webView.url?.host else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let fields = tab.loginFields
        let panel = SignInPanel(host: host, profile: tab.profile, wantsUser: fields.user || !fields.pass, wantsPassword: fields.pass || !fields.user) { user, password in
            popover.close()
            // Only into the page the panel was opened for.
            guard webView.url?.host == host else { return }
            webView.callAsyncJavaScript(fillScript, arguments: ["user": user, "pass": password], in: nil, in: Tab.scriptWorld) { _ in }
            webView.window?.makeFirstResponder(webView)
        }
        popover.contentViewController = panel
        popover.contentSize = panel.view.fittingSize
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    static func openPasswordsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Passwords") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The native stand-in for a page's sign-in form.
private final class SignInPanel: NSViewController, NSTextFieldDelegate {
    private let host: String
    private let profile: Profile
    /// What this profile already keeps for the site.
    private let saved: [Vault.Login]
    private let remember = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let wantsUser: Bool
    private let wantsPassword: Bool
    private let done: (String, String) -> Void
    private let user = NSTextField()
    private let password = NSSecureTextField()
    private var lengths: [ObjectIdentifier: Int] = [:]
    /// The picker is brought up by itself once per field.
    private var offered: Set<ObjectIdentifier> = []

    init(host: String, profile: Profile, wantsUser: Bool, wantsPassword: Bool, done: @escaping (String, String) -> Void) {
        self.host = host
        self.profile = profile
        saved = Vault.logins(profile, host: host)
        self.wantsUser = wantsUser
        self.wantsPassword = wantsPassword
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var fields: [NSTextField] { (wantsUser ? [user] : []) + (wantsPassword ? [password] : []) }

    override func loadView() {
        let title = NSTextField(labelWithString: L("Sign in to %@", host))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let hint = NSTextField(wrappingLabelWithString: L("Pick the account in Passwords; Mizu fills it into the page."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        user.placeholderString = L("User name")
        user.contentType = .username
        password.placeholderString = L("Password")
        password.contentType = .password
        for field in [user, password] {
            field.delegate = self
            field.target = self
            field.action = #selector(fill)
        }
        let picker = NSButton(title: L("Passwords…"), target: self, action: #selector(pick))
        picker.image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        picker.imagePosition = .imageLeading
        let fillButton = NSButton(title: L("Fill"), target: self, action: #selector(fill))
        fillButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [picker, NSView(), fillButton])
        // The accounts this profile keeps for the site: one click fills them.
        let accounts: [NSView] = saved.enumerated().map { index, login in
            let button = NSButton(title: login.user, target: self, action: #selector(useSaved(_:)))
            button.tag = index
            button.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.alignment = .left
            return button
        }
        remember.title = L("Keep in the profile “%@”", profile.name)
        remember.state = .on
        remember.font = .systemFont(ofSize: 11)
        remember.isHidden = profile.isPrivate
        if !saved.isEmpty { hint.stringValue = L("Pick an account kept in this profile, or another from Passwords.") }
        let rows: [NSView] = [title, hint] + accounts + fields + [remember, buttons]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        for row in rows.dropFirst() {
            row.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let first = fields.first else { return }
        view.window?.makeFirstResponder(first)
        // Straight to the picker, unless the profile has accounts to offer.
        guard saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.offer(for: first) }
    }

    private func offer(for field: NSTextField) {
        guard view.window != nil, offered.insert(ObjectIdentifier(field)).inserted else { return }
        // (Scripted test runs must not raise a Touch ID prompt.)
        if ProcessInfo.processInfo.environment["MIZU_DEBUG"] == nil { pick() }
    }

    @objc private func pick() {
        if !(view.window?.firstResponder is NSText), let first = fields.first(where: \.stringValue.isEmpty) ?? fields.first {
            view.window?.makeFirstResponder(first)
        }
        if !NSApp.sendAction(Passwords.pickerAction, to: nil, from: nil) { Passwords.openPasswordsApp() }
    }

    @objc private func fill() {
        guard fields.contains(where: { !$0.stringValue.isEmpty }) else { return }
        if remember.state == .on, !remember.isHidden {
            Vault.save(profile, host: host, user: user.stringValue, password: password.stringValue)
        }
        done(wantsUser ? user.stringValue : "", wantsPassword ? password.stringValue : "")
    }

    @objc private func useSaved(_ sender: NSButton) {
        guard sender.tag < saved.count else { return }
        let login = saved[sender.tag]
        done(wantsUser ? login.user : "", wantsPassword ? Vault.password(profile, login) ?? "" : "")
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let before = lengths[ObjectIdentifier(field)] ?? 0
        lengths[ObjectIdentifier(field)] = field.stringValue.count
        // Several characters at once: this was filled in, not typed.
        guard field.stringValue.count - before > 1 else { return }
        for other in fields { lengths[ObjectIdentifier(other)] = other.stringValue.count }
        if let empty = fields.first(where: \.stringValue.isEmpty) {
            // The picker gave one of the two; ask it for the other.
            view.window?.makeFirstResponder(empty)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.offer(for: empty) }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.fill() }
        }
    }
}
