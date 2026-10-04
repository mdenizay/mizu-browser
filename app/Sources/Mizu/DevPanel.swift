import AppKit
import SwiftUI
import WebKit

/// One line of a report in the developer panel.
struct PanelRow: Identifiable {
    enum Status { case none, good, warning, bad }

    let id = UUID()
    var label: String
    var value: String
    var status = Status.none
}

struct PanelSection: Identifiable {
    let id = UUID()
    var title: String
    var rows: [PanelRow]
}

/// The scripts the panel runs in the page. Each is the body of a function
/// and returns plain data.
private enum PageScript {
    static let seo = """
    const meta = (name) => (document.querySelector(`meta[name="${name}" i], meta[property="${name}" i]`) || {}).content || '';
    const types = [];
    for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        const walk = node => {
          if (Array.isArray(node)) return node.forEach(walk);
          if (node && typeof node === 'object') { if (node['@type']) types.push([].concat(node['@type']).join(', ')); if (node['@graph']) walk(node['@graph']); }
        };
        walk(JSON.parse(script.textContent));
      } catch (e) { types.push('(invalid JSON-LD)'); }
    }
    const links = [...document.links].filter(a => /^https?:/.test(a.href));
    const images = [...document.images];
    return {
      title: document.title || '',
      description: meta('description'),
      canonical: (document.querySelector('link[rel="canonical"]') || {}).href || '',
      robots: meta('robots'),
      lang: document.documentElement.lang || '',
      viewport: meta('viewport'),
      charset: document.characterSet || '',
      og: ['og:title', 'og:description', 'og:image', 'og:url', 'og:type', 'og:site_name'].map(k => [k, meta(k)]),
      twitter: ['twitter:card', 'twitter:title', 'twitter:image'].map(k => [k, meta(k)]),
      schema: types,
      hreflang: [...document.querySelectorAll('link[rel="alternate"][hreflang]')].map(l => l.hreflang),
      headings: [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].slice(0, 80).map(h => [h.tagName, (h.innerText || '').trim().slice(0, 120)]),
      images: images.length,
      imagesNoAlt: images.filter(i => !i.hasAttribute('alt')).length,
      internal: links.filter(a => a.host === location.host).length,
      external: links.filter(a => a.host !== location.host).length,
      nofollow: links.filter(a => /nofollow/.test(a.rel)).length,
      words: ((document.body && document.body.innerText) || '').split(/\\s+/).filter(Boolean).length,
    };
    """

    static let accessibility = """
    const visible = el => { const r = el.getBoundingClientRect(); const s = getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; };
    const describe = el => (el.outerHTML || '').replace(/\\s+/g, ' ').slice(0, 110);
    const named = el => (el.innerText || '').trim() || el.getAttribute('aria-label') || el.getAttribute('aria-labelledby') || el.title || [...el.querySelectorAll('img[alt]')].map(i => i.alt).join('').trim() || (el.querySelector('svg title') || {}).textContent;
    const issues = [];
    const add = (kind, elements) => { if (elements.length) issues.push({ kind, count: elements.length, samples: elements.slice(0, 5).map(describe) }); };
    add('Images without alt text', [...document.images].filter(i => !i.hasAttribute('alt') && i.getAttribute('role') !== 'presentation'));
    add('Links without a name', [...document.querySelectorAll('a[href]')].filter(a => visible(a) && !named(a)));
    add('Buttons without a name', [...document.querySelectorAll('button, [role="button"]')].filter(b => visible(b) && !named(b)));
    add('Form fields without a label', [...document.querySelectorAll('input, select, textarea')].filter(f => {
      if (['hidden', 'submit', 'button', 'reset', 'image'].includes(f.type) || !visible(f)) return false;
      return !(f.labels && f.labels.length) && !f.getAttribute('aria-label') && !f.getAttribute('aria-labelledby') && !f.title;
    }));
    add('Positive tabindex (breaks the tab order)', [...document.querySelectorAll('[tabindex]')].filter(e => e.tabIndex > 0));
    add('Frames without a title', [...document.querySelectorAll('iframe')].filter(f => visible(f) && !f.title));

    const headings = [...document.querySelectorAll('h1,h2,h3,h4,h5,h6')].filter(visible);
    const skips = [];
    let previous = 0;
    for (const h of headings) { const level = +h.tagName[1]; if (previous && level > previous + 1) skips.push(h); previous = level; }
    add('Heading levels skipped', skips);

    // Contrast of text against the nearest background that has a colour.
    const parse = c => { const m = c.match(/[\\d.]+/g); return m ? m.map(Number) : null; };
    const lum = ([r, g, b]) => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b); };
    const background = el => { for (let e = el; e; e = e.parentElement) { const c = parse(getComputedStyle(e).backgroundColor); if (c && (c.length < 4 || c[3] > 0.5)) return c; if (getComputedStyle(e).backgroundImage !== 'none') return null; } return [255, 255, 255]; };
    const low = [];
    let checked = 0;
    const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
    const seen = new Set();
    while (walker.nextNode() && checked < 600) {
      const el = walker.currentNode.parentElement;
      if (!el || seen.has(el) || !walker.currentNode.textContent.trim() || !visible(el)) continue;
      seen.add(el); checked++;
      const style = getComputedStyle(el), fg = parse(style.color), bg = background(el);
      if (!fg || !bg || (fg.length > 3 && fg[3] < 0.5)) continue;
      const a = lum(fg), b = lum(bg), ratio = (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      const size = parseFloat(style.fontSize), large = size >= 24 || (size >= 18.66 && parseInt(style.fontWeight) >= 700);
      if (ratio < (large ? 3 : 4.5)) low.push(ratio.toFixed(2) + ':1  ' + el.innerText.trim().slice(0, 70));
    }
    return {
      issues,
      lowContrast: low.slice(0, 25), lowContrastCount: low.length, textChecked: checked,
      lang: document.documentElement.lang || '', title: document.title || '',
      h1: headings.filter(h => h.tagName === 'H1').length,
      landmarks: ['main', 'nav', 'header', 'footer'].map(t => [t, document.querySelectorAll(t + ', [role="' + ({ main: 'main', nav: 'navigation', header: 'banner', footer: 'contentinfo' })[t] + '"]').length]),
      outline: headings.slice(0, 60).map(h => [h.tagName, (h.innerText || '').trim().slice(0, 100)]),
    };
    """

    static let resources = """
    const nav = performance.getEntriesByType('navigation')[0];
    return {
      entries: performance.getEntriesByType('resource').map(e => [e.name, e.initiatorType, e.transferSize || 0, Math.round(e.duration)]),
      load: nav ? Math.round(nav.loadEventEnd || nav.domComplete || 0) : 0,
      dom: nav ? Math.round(nav.domContentLoadedEventEnd || 0) : 0,
      ttfb: nav ? Math.round(nav.responseStart || 0) : 0,
      size: nav ? (nav.transferSize || 0) : 0,
    };
    """

    static let storage = """
    const dump = store => { const out = []; try { for (let i = 0; i < store.length; i++) { const k = store.key(i); out.push([k, String(store.getItem(k)).slice(0, 600)]); } } catch (e) {} return out; };
    return { local: dump(localStorage), session: dump(sessionStorage) };
    """

    static let links = """
    const seen = new Set();
    for (const a of document.links) { if (/^https?:/.test(a.href)) seen.add(a.href.split('#')[0]); }
    return [...seen].slice(0, 250);
    """

    /// Lets the user point at an element; resolves with what it is and how
    /// it is styled, or null when Escape is pressed.
    static let picker = """
    return await new Promise(resolve => {
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #0a84ff;background:rgba(10,132,255,.14);border-radius:2px;transition:all .04s';
      const label = document.createElement('div');
      label.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;font:11px -apple-system,sans-serif;background:#0a84ff;color:#fff;padding:2px 6px;border-radius:4px;white-space:nowrap';
      document.documentElement.append(box, label);
      let current = null;
      const finish = value => {
        document.removeEventListener('mousemove', move, true);
        document.removeEventListener('click', click, true);
        document.removeEventListener('keydown', key, true);
        box.remove(); label.remove();
        // Give the frame a moment to repaint without the outline.
        requestAnimationFrame(() => requestAnimationFrame(() => resolve(value)));
      };
      const move = event => {
        const el = document.elementFromPoint(event.clientX, event.clientY);
        if (!el || el === current) return;
        current = el;
        const r = el.getBoundingClientRect();
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
        label.textContent = el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + '  ' + Math.round(r.width) + ' × ' + Math.round(r.height);
        label.style.left = Math.max(r.left, 2) + 'px'; label.style.top = Math.max(r.top - 20, 2) + 'px';
      };
      const click = event => {
        event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation();
        if (!current) return finish(null);
        const el = current, r = el.getBoundingClientRect(), s = getComputedStyle(el);
        finish({
          tag: el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\\s+/).slice(0, 3).join('.') : ''),
          x: r.left, y: r.top, width: r.width, height: r.height,
          text: (el.innerText || '').trim().slice(0, 80),
          fontFamily: s.fontFamily, fontSize: s.fontSize, fontWeight: s.fontWeight, fontStyle: s.fontStyle, lineHeight: s.lineHeight, letterSpacing: s.letterSpacing,
          color: s.color, background: s.backgroundColor, margin: s.margin, padding: s.padding, border: s.border, radius: s.borderRadius, display: s.display, position: s.position,
        });
      };
      const key = event => { if (event.key === 'Escape') { event.preventDefault(); finish(null); } };
      document.addEventListener('mousemove', move, true);
      document.addEventListener('click', click, true);
      document.addEventListener('keydown', key, true);
    });
    """
}

/// What the developer panel shows, and the work of gathering it.
final class DevPanelModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case seo, accessibility, requests, storage, links, styles, css

        var id: String { rawValue }

        var title: String {
            switch self {
            case .seo: return L("SEO")
            case .accessibility: return L("Accessibility")
            case .requests: return L("Requests")
            case .storage: return L("Cookies & Storage")
            case .links: return L("Broken Links")
            case .styles: return L("Styles & Colours")
            case .css: return L("CSS Override")
            }
        }

        var symbol: String {
            switch self {
            case .seo: return "magnifyingglass"
            case .accessibility: return "accessibility"
            case .requests: return "arrow.up.arrow.down"
            case .storage: return "internaldrive"
            case .links: return "link"
            case .styles: return "eyedropper"
            case .css: return "curlybraces"
            }
        }
    }

    @Published var tool = Tool.seo { didSet { if tool != oldValue { refresh() } } }
    @Published private(set) var sections: [PanelSection] = []
    @Published private(set) var busy = false
    @Published private(set) var note = ""
    @Published var css = "" { didSet { if css != oldValue { tab?.customCSS = css } } }
    /// The last element and colour picked, kept across refreshes.
    private var picked: [PanelSection] = []

    weak var controller: BrowserWindowController?
    private var tab: Tab? { controller?.tabs.selected }
    private var run = 0

    /// Called when the page in front changes.
    func pageChanged() {
        if css != tab?.customCSS ?? "" { css = tab?.customCSS ?? "" }
        refresh()
    }

    private func call(_ script: String, completion: @escaping (Any?) -> Void) {
        guard let webView = tab?.webView, webView.url != nil else { return completion(nil) }
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: Tab.scriptWorld) { result in
            completion(try? result.get())
        }
    }

    func refresh() {
        run += 1
        let current = run
        note = ""
        guard tab?.webView?.url != nil else {
            sections = []
            note = L("Open a page to inspect it.")
            return
        }
        let finish: ([PanelSection]) -> Void = { [weak self] sections in
            guard let self, self.run == current else { return }
            self.sections = sections
            self.busy = false
        }
        busy = true
        switch tool {
        case .seo: call(PageScript.seo) { finish(Self.seo($0 as? [String: Any] ?? [:])) }
        case .accessibility: call(PageScript.accessibility) { finish(Self.accessibility($0 as? [String: Any] ?? [:])) }
        case .requests: call(PageScript.resources) { [weak self] in finish(self?.requests($0 as? [String: Any] ?? [:]) ?? []) }
        case .storage: storage(finish)
        case .links: checkLinks(current, finish)
        case .styles: finish(picked)
        case .css: finish([])
        }
    }

    // MARK: SEO

    private static func seo(_ data: [String: Any]) -> [PanelSection] {
        let text: (String) -> String = { data[$0] as? String ?? "" }
        let number: (String) -> Int = { data[$0] as? Int ?? 0 }
        func length(_ value: String, _ range: ClosedRange<Int>) -> PanelRow.Status {
            value.isEmpty ? .bad : (range.contains(value.count) ? .good : .warning)
        }
        let title = text("title"), description = text("description"), robots = text("robots")
        var basics = [
            PanelRow(label: L("Title") + " (\(title.count))", value: title.isEmpty ? L("Missing") : title, status: length(title, 15...60)),
            PanelRow(label: L("Description") + " (\(description.count))", value: description.isEmpty ? L("Missing") : description, status: length(description, 70...160)),
            PanelRow(label: "Canonical", value: text("canonical").isEmpty ? L("Missing") : text("canonical"), status: text("canonical").isEmpty ? .warning : .good),
            PanelRow(label: "Robots", value: robots.isEmpty ? "index, follow" : robots, status: robots.lowercased().contains("noindex") ? .bad : .good),
            PanelRow(label: L("Language"), value: text("lang").isEmpty ? L("Missing") : text("lang"), status: text("lang").isEmpty ? .warning : .good),
            PanelRow(label: "Viewport", value: text("viewport").isEmpty ? L("Missing") : text("viewport"), status: text("viewport").isEmpty ? .warning : .good),
        ]
        let hreflang = data["hreflang"] as? [String] ?? []
        if !hreflang.isEmpty { basics.append(PanelRow(label: "hreflang", value: hreflang.joined(separator: ", "))) }

        let pairs: (String) -> [PanelRow] = { key in
            (data[key] as? [[String]] ?? []).filter { $0.count == 2 }.map {
                PanelRow(label: $0[0], value: $0[1].isEmpty ? L("Missing") : $0[1], status: $0[1].isEmpty ? .warning : .good)
            }
        }
        let schema = data["schema"] as? [String] ?? []
        let headings = (data["headings"] as? [[String]] ?? []).filter { $0.count == 2 }
        let h1 = headings.filter { $0[0] == "H1" }.count
        let images = number("images"), noAlt = number("imagesNoAlt")
        return [
            PanelSection(title: L("Basics"), rows: basics),
            PanelSection(title: L("Social"), rows: pairs("og") + pairs("twitter")),
            PanelSection(title: L("Structured Data"), rows: schema.isEmpty
                ? [PanelRow(label: "JSON-LD", value: L("None"), status: .warning)]
                : schema.map { PanelRow(label: "JSON-LD", value: $0, status: $0.contains("invalid") ? .bad : .good) }),
            PanelSection(title: L("Content"), rows: [
                PanelRow(label: L("Words"), value: "\(number("words"))"),
                PanelRow(label: L("Images"), value: noAlt == 0 ? "\(images)" : L("%d, %d without alt text", images, noAlt), status: noAlt == 0 ? .good : .warning),
                PanelRow(label: L("Links"), value: L("%d internal, %d external, %d nofollow", number("internal"), number("external"), number("nofollow"))),
            ]),
            PanelSection(title: L("Headings"), rows: [PanelRow(label: "H1", value: h1 == 1 ? L("One, as it should be") : L("%d on the page", h1), status: h1 == 1 ? .good : .bad)]
                + headings.map { PanelRow(label: $0[0], value: $0[1].isEmpty ? "—" : $0[1]) }),
        ]
    }

    // MARK: Accessibility

    private static func accessibility(_ data: [String: Any]) -> [PanelSection] {
        let issues = data["issues"] as? [[String: Any]] ?? []
        let low = data["lowContrast"] as? [String] ?? []
        let lowCount = data["lowContrastCount"] as? Int ?? 0
        let h1 = data["h1"] as? Int ?? 0
        var summary = [
            PanelRow(label: L("Page language"), value: (data["lang"] as? String ?? "").isEmpty ? L("Missing") : data["lang"] as? String ?? "", status: (data["lang"] as? String ?? "").isEmpty ? .bad : .good),
            PanelRow(label: L("Page title"), value: (data["title"] as? String ?? "").isEmpty ? L("Missing") : data["title"] as? String ?? "", status: (data["title"] as? String ?? "").isEmpty ? .bad : .good),
            PanelRow(label: "H1", value: h1 == 1 ? L("One, as it should be") : L("%d on the page", h1), status: h1 == 1 ? .good : .warning),
            PanelRow(label: L("Contrast"), value: lowCount == 0 ? L("No low-contrast text in %d checked", data["textChecked"] as? Int ?? 0) : L("%d texts below the WCAG AA ratio", lowCount), status: lowCount == 0 ? .good : .bad),
        ]
        for pair in (data["landmarks"] as? [[Any]] ?? []) where pair.count == 2 {
            let count = pair[1] as? Int ?? 0
            summary.append(PanelRow(label: "<\(pair[0])>", value: count == 0 ? L("Missing") : "\(count)", status: count == 0 ? .warning : .good))
        }
        var sections = [PanelSection(title: L("Summary"), rows: summary)]
        for issue in issues {
            let samples = issue["samples"] as? [String] ?? []
            sections.append(PanelSection(title: "\(L(issue["kind"] as? String ?? "")) (\(issue["count"] as? Int ?? 0))",
                                         rows: samples.map { PanelRow(label: "", value: $0, status: .bad) }))
        }
        if !low.isEmpty {
            sections.append(PanelSection(title: L("Low Contrast") + " (\(lowCount))", rows: low.map { PanelRow(label: "", value: $0, status: .warning) }))
        }
        if issues.isEmpty, low.isEmpty {
            sections.append(PanelSection(title: L("Checks"), rows: [PanelRow(label: "", value: L("Nothing found by the quick checks. They cover names, labels, headings, tab order and contrast; they are no substitute for testing with VoiceOver."), status: .good)]))
        }
        let outline = (data["outline"] as? [[String]] ?? []).filter { $0.count == 2 }
        sections.append(PanelSection(title: L("Heading Structure"), rows: outline.map {
            PanelRow(label: String(repeating: "  ", count: max((Int($0[0].dropFirst()) ?? 1) - 1, 0)) + $0[0], value: $0[1].isEmpty ? "—" : $0[1])
        }))
        return sections
    }

    // MARK: Requests

    private func requests(_ data: [String: Any]) -> [PanelSection] {
        let entries = (data["entries"] as? [[Any]] ?? []).filter { $0.count == 4 }
        let pageHost = tab?.webView?.url?.host ?? ""
        let site = pageHost.split(separator: ".").suffix(2).joined(separator: ".")
        var hosts: [String: (count: Int, bytes: Int)] = [:]
        var kinds: [String: Int] = [:]
        var total = data["size"] as? Int ?? 0
        for entry in entries {
            let host = URL(string: entry[0] as? String ?? "")?.host ?? "?"
            let bytes = entry[2] as? Int ?? 0
            hosts[host, default: (0, 0)].count += 1
            hosts[host, default: (0, 0)].bytes += bytes
            kinds[entry[1] as? String ?? "other", default: 0] += 1
            total += bytes
        }
        // (Other sites report no size unless they allow it.)
        let size: (Int) -> String = { $0 == 0 ? "—" : ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        let blocked = tab?.blockedURLs ?? []
        let third = hosts.keys.filter { !$0.hasSuffix(site) }
        var sections = [PanelSection(title: L("Summary"), rows: [
            PanelRow(label: L("Requests"), value: "\(entries.count + 1)"),
            PanelRow(label: L("Transferred"), value: size(total)),
            PanelRow(label: L("First byte"), value: "\(data["ttfb"] as? Int ?? 0) ms"),
            PanelRow(label: L("DOM ready"), value: "\(data["dom"] as? Int ?? 0) ms"),
            PanelRow(label: L("Loaded"), value: "\(data["load"] as? Int ?? 0) ms"),
            PanelRow(label: L("Other sites"), value: "\(third.count)", status: third.count > 15 ? .warning : .none),
            PanelRow(label: L("Blocked"), value: "\(blocked.count)", status: blocked.isEmpty ? .none : .good),
            PanelRow(label: L("By kind"), value: kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")),
        ])]
        sections.append(PanelSection(title: L("By Site"), rows: hosts.sorted { $0.value.bytes > $1.value.bytes }.map {
            PanelRow(label: $0.key, value: "\($0.value.count) · \(size($0.value.bytes))", status: $0.key.hasSuffix(site) ? .none : .warning)
        }))
        if !blocked.isEmpty {
            var counts: [String: Int] = [:]
            for address in blocked { counts[URL(string: address)?.host ?? address, default: 0] += 1 }
            sections.append(PanelSection(title: L("Blocked Trackers and Ads"), rows: counts.sorted { $0.value > $1.value }.map {
                PanelRow(label: $0.key, value: "\($0.value)", status: .good)
            }))
        }
        let slow = entries.sorted { ($0[3] as? Int ?? 0) > ($1[3] as? Int ?? 0) }.prefix(8)
        sections.append(PanelSection(title: L("Slowest"), rows: slow.map {
            PanelRow(label: "\($0[3] as? Int ?? 0) ms", value: AddressBar.pretty(URL(string: $0[0] as? String ?? "")))
        }))
        return sections
    }

    // MARK: Storage

    private func storage(_ finish: @escaping ([PanelSection]) -> Void) {
        guard let tab, let webView = tab.webView, let host = webView.url?.host else { return finish([]) }
        tab.profile.dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            let mine = cookies.filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            let cookieRows = mine.sorted { $0.name < $1.name }.map { cookie -> PanelRow in
                var flags: [String] = []
                if cookie.isSecure { flags.append("Secure") }
                if cookie.isHTTPOnly { flags.append("HttpOnly") }
                if let policy = cookie.sameSitePolicy { flags.append("SameSite=\(policy.rawValue)") }
                flags.append(cookie.expiresDate.map { $0.formatted(date: .numeric, time: .omitted) } ?? "session")
                return PanelRow(label: cookie.name, value: String(cookie.value.prefix(300)) + "\n" + flags.joined(separator: " · "))
            }
            self?.call(PageScript.storage) { result in
                let data = result as? [String: Any] ?? [:]
                let rows: (String) -> [PanelRow] = { key in
                    (data[key] as? [[String]] ?? []).filter { $0.count == 2 }.map { PanelRow(label: $0[0], value: $0[1]) }
                }
                finish([
                    PanelSection(title: L("Cookies") + " (\(cookieRows.count))", rows: cookieRows),
                    PanelSection(title: "Local Storage (\(rows("local").count))", rows: rows("local")),
                    PanelSection(title: "Session Storage (\(rows("session").count))", rows: rows("session")),
                ])
            }
        }
    }

    // MARK: Links

    private func checkLinks(_ current: Int, _ finish: @escaping ([PanelSection]) -> Void) {
        call(PageScript.links) { [weak self] result in
            let links = (result as? [String] ?? []).compactMap(URL.init(string:))
            guard let self, !links.isEmpty else { return finish([PanelSection(title: L("Summary"), rows: [PanelRow(label: "", value: L("No links on this page."))])]) }
            self.note = L("Checking %d links…", links.count)
            let agent = self.tab?.webView?.customUserAgent.flatMap { $0.isEmpty ? nil : $0 }
            Task {
                let results = await LinkChecker.check(links, userAgent: agent)
                await MainActor.run {
                    guard self.run == current else { return }
                    self.note = ""
                    // "Too many requests" and "unavailable" say the server would not
                    // be checked, not that the link is broken.
                    let refused = results.filter { $0.status == 429 || $0.status == 503 }
                    let broken = results.filter { ($0.status >= 400 || $0.status == 0) && $0.status != 429 && $0.status != 503 }.sorted { $0.status > $1.status }
                    let redirected = results.filter { (300..<400).contains($0.status) }
                    var sections = [PanelSection(title: L("Summary"), rows: [
                        PanelRow(label: L("Checked"), value: "\(results.count)"),
                        PanelRow(label: L("Broken"), value: "\(broken.count)", status: broken.isEmpty ? .good : .bad),
                        PanelRow(label: L("Redirected"), value: "\(redirected.count)", status: redirected.isEmpty ? .none : .warning),
                    ] + (refused.isEmpty ? [] : [PanelRow(label: L("Not checked"), value: L("%d: the server turned the check away", refused.count), status: .warning)]))]
                    if !broken.isEmpty {
                        sections.append(PanelSection(title: L("Broken"), rows: broken.map {
                            PanelRow(label: $0.status == 0 ? L("Failed") : "\($0.status)", value: $0.url.absoluteString, status: .bad)
                        }))
                    }
                    if !redirected.isEmpty {
                        sections.append(PanelSection(title: L("Redirected"), rows: redirected.map {
                            PanelRow(label: "\($0.status)", value: $0.url.absoluteString, status: .warning)
                        }))
                    }
                    finish(sections)
                }
            }
        }
    }

    // MARK: Picking

    /// Lets the user click an element of the page; calls back with what the
    /// page reported, or nil when it was cancelled.
    func pickElement(completion: @escaping ([String: Any]?) -> Void) {
        controller?.window?.makeFirstResponder(tab?.webView)
        call(PageScript.picker) { completion($0 as? [String: Any]) }
    }

    func inspectElement() {
        note = L("Click an element of the page. Esc cancels.")
        pickElement { [weak self] info in
            guard let self else { return }
            self.note = ""
            guard let info else { return }
            let text: (String) -> String = { info[$0] as? String ?? "" }
            let number: (String) -> Int = { Int((info[$0] as? Double ?? 0).rounded()) }
            self.picked = [
                PanelSection(title: text("tag"), rows: [
                    PanelRow(label: L("Size"), value: "\(number("width")) × \(number("height"))"),
                    PanelRow(label: L("Text"), value: text("text").isEmpty ? "—" : text("text")),
                ]),
                PanelSection(title: L("Font"), rows: [
                    PanelRow(label: L("Family"), value: text("fontFamily")),
                    PanelRow(label: L("Size"), value: text("fontSize")),
                    PanelRow(label: L("Weight"), value: text("fontWeight") + (text("fontStyle") == "normal" ? "" : " " + text("fontStyle"))),
                    PanelRow(label: L("Line height"), value: text("lineHeight")),
                    PanelRow(label: L("Letter spacing"), value: text("letterSpacing")),
                ]),
                PanelSection(title: L("Colours"), rows: [
                    PanelRow(label: L("Text"), value: Self.hex(text("color"))),
                    PanelRow(label: L("Background"), value: Self.hex(text("background"))),
                ]),
                PanelSection(title: L("Box"), rows: [
                    PanelRow(label: "display", value: text("display")),
                    PanelRow(label: "position", value: text("position")),
                    PanelRow(label: "margin", value: text("margin")),
                    PanelRow(label: "padding", value: text("padding")),
                    PanelRow(label: "border", value: text("border")),
                    PanelRow(label: "border-radius", value: text("radius")),
                ]),
            ] + self.picked.filter { $0.title == L("Picked Colour") }
            self.tool = .styles
            self.sections = self.picked
        }
    }

    /// The system's eyedropper: any pixel on screen, copied as a hex colour.
    func pickColor() {
        NSColorSampler().show { [weak self] color in
            guard let self, let color = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
            let rgb = "rgb(\(Int((color.redComponent * 255).rounded())), \(Int((color.greenComponent * 255).rounded())), \(Int((color.blueComponent * 255).rounded())))"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hex, forType: .string)
            self.picked = self.picked.filter { $0.title != L("Picked Colour") } + [PanelSection(title: L("Picked Colour"), rows: [
                PanelRow(label: "HEX", value: hex + "  (" + L("copied") + ")"),
                PanelRow(label: "RGB", value: rgb),
            ])]
            self.tool = .styles
            self.sections = self.picked
        }
    }

    /// "rgb(10, 132, 255)" as "#0A84FF  rgb(10, 132, 255)".
    private static func hex(_ css: String) -> String {
        let parts = css.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }.compactMap(Double.init)
        guard parts.count >= 3 else { return css }
        if parts.count > 3, parts[3] == 0 { return L("transparent") }
        return String(format: "#%02X%02X%02X", Int(parts[0]), Int(parts[1]), Int(parts[2])) + "  " + css
    }
}

/// Asks each address for its status, a few at a time.
enum LinkChecker {
    struct Result {
        let url: URL
        /// The HTTP status, or 0 when the server could not be reached.
        let status: Int
    }

    /// Reports redirects instead of following them.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func check(_ urls: [URL], userAgent: String?) async -> [Result] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        // Gently: a burst of requests gets a visitor turned away.
        configuration.httpMaximumConnectionsPerHost = 2
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: Result.self) { group in
            var results: [Result] = []
            var pending = urls[...]
            let start: (inout TaskGroup<Result>, URL) -> Void = { group, url in
                group.addTask {
                    func status(_ method: String) async -> Int {
                        var request = URLRequest(url: url)
                        request.httpMethod = method
                        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
                        if method == "GET" { request.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
                        return ((try? await session.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
                    }
                    var code = await status("HEAD")
                    // Plenty of servers refuse HEAD; ask again properly before calling it broken.
                    if code == 0 || (code >= 400 && code != 429 && code != 503) { code = await status("GET") }
                    return Result(url: url, status: code == 206 ? 200 : code)
                }
            }
            for _ in 0..<6 { if let url = pending.popFirst() { start(&group, url) } }
            for await result in group {
                results.append(result)
                if let url = pending.popFirst() { start(&group, url) }
            }
            return results
        }
    }
}

/// The panel at the side of the page with the quick audits.
struct DevPanelView: View {
    @ObservedObject var model: DevPanelModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Picker("", selection: $model.tool) {
                    ForEach(DevPanelModel.Tool.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("Run Again"))
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(L("Close"))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            Divider()
            if model.tool == .styles {
                HStack {
                    Button { model.inspectElement() } label: { Label(L("Pick Element"), systemImage: "cursorarrow.rays") }
                    Button { model.pickColor() } label: { Label(L("Pick Colour"), systemImage: "eyedropper") }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 12).padding(.top, 10)
            }
            if !model.note.isEmpty {
                Text(model.note).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 10)
            }
            if model.tool == .css {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("CSS added to this tab until it is closed. It is applied as you type and again after each page load."))
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $model.css)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    HStack {
                        ForEach(["body { overflow: hidden }", "* { outline: 1px solid #f0f8 }", "img { opacity: .2 }"], id: \.self) { snippet in
                            Button(snippet.prefix(while: { $0 != "{" }).trimmingCharacters(in: .whitespaces)) {
                                model.css += (model.css.isEmpty ? "" : "\n") + snippet
                            }
                            .help(snippet)
                        }
                        Spacer()
                        Button(L("Clear")) { model.css = "" }
                    }
                    .controlSize(.small)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                                ForEach(section.rows) { PanelRowView(row: $0) }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea()
    }
}

private struct PanelRowView: View {
    let row: PanelRow

    private var color: Color {
        switch row.status {
        case .none: return .clear
        case .good: return .green
        case .warning: return .orange
        case .bad: return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(color).frame(width: 6, height: 6).offset(y: -2)
            VStack(alignment: .leading, spacing: 1) {
                if !row.label.isEmpty {
                    Text(row.label).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(row.value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(L("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.value, forType: .string)
            }
        }
    }
}
