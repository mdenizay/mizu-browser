import CAdblock
import Foundation
import WebKit

struct FilterList: Identifiable {
    let id: String
    let name: String
    let detail: String
    let urls: [String]
    let onByDefault: Bool

    static let all = [
        FilterList(id: "easylist", name: "EasyList", detail: "Ads", urls: ["https://easylist.to/easylist/easylist.txt"], onByDefault: true),
        FilterList(id: "easyprivacy", name: "EasyPrivacy", detail: "Trackers", urls: ["https://easylist.to/easylist/easyprivacy.txt"], onByDefault: true),
        FilterList(id: "ublock", name: "uBlock filters", detail: "Ads, trackers and fixes for broken pages", urls: [
            "https://ublockorigin.github.io/uAssets/filters/filters.min.txt",
            "https://ublockorigin.github.io/uAssets/filters/privacy.min.txt",
            "https://ublockorigin.github.io/uAssets/filters/quick-fixes.min.txt",
            "https://ublockorigin.github.io/uAssets/filters/unbreak.min.txt",
        ], onByDefault: true),
        FilterList(id: "adguard-tracking", name: "AdGuard Tracking Protection", detail: "Trackers", urls: ["https://filters.adtidy.org/extension/ublock/filters/3.txt"], onByDefault: true),
        FilterList(id: "adguard-turkish", name: "AdGuard Turkish", detail: "Ads on Turkish sites", urls: ["https://filters.adtidy.org/extension/ublock/filters/13.txt"], onByDefault: Locale.preferredLanguages.contains { $0.hasPrefix("tr") } || Locale.current.region?.identifier == "TR"),
        FilterList(id: "cookies", name: "EasyList Cookie", detail: "Cookie banners", urls: ["https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"], onByDefault: false),
    ]
}

/// What to do to a page beyond blocking its requests.
struct Cosmetics {
    /// Selectors to hide from the start.
    var selectors: [String] = []
    /// Scriptlets, run in the page before its own scripts.
    var script = ""
    /// Classes and ids that generic hiding must leave alone on this page.
    var exceptions: [String] = []
    /// The page is exempt from generic hiding.
    var genericHide = false
}

/// The built-in ad blocker. Brave's adblock-rust reads the filter lists; its
/// network rules are handed to WebKit as content rule lists (so blocking
/// happens inside WebKit, at no cost to this process) and the rest (element
/// hiding, scriptlets) is answered by an in-memory engine.
final class Adblock: ObservableObject {
    static let shared = Adblock()

    enum State: Equatable {
        case idle
        case updating(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var ruleCount = 0
    @Published private(set) var lastUpdate: Date?

    /// What the last update produced; kept beside the rules themselves.
    private struct Saved: Codable {
        var identifiers: [String] = []
        /// The filter lists the rules were built from.
        var lists: [String] = []
        var ruleCount = 0
        var lastUpdate: Date?
    }

    private var saved = Saved() {
        didSet { try? JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("state.json"), options: .atomic) }
    }

    /// The compiled rule lists, to be attached to every web view.
    private(set) var ruleLists: [WKContentRuleList] = []

    private var engine: OpaquePointer?
    /// The engine is only ever touched from this queue.
    private let queue = DispatchQueue(label: "com.mdenizay.mizu.adblock", qos: .userInitiated)
    private let directory = Prefs.supportDirectory.appendingPathComponent("adblock")
    private let store: WKContentRuleListStore
    private static let resourcesURL = "https://raw.githubusercontent.com/brave/adblock-resources/master/dist/resources.json"
    /// WebKit refuses lists beyond 150 000 rules, and compiles small ones faster.
    private static let chunk = 40_000

    private init() {
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("lists"), withIntermediateDirectories: true)
        store = WKContentRuleListStore(url: directory.appendingPathComponent("rules")) ?? .default()
        if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")), let state = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = state
            ruleCount = state.ruleCount
            lastUpdate = state.lastUpdate
        }
    }

    /// Loads what the last update left on disk, and updates when that is
    /// missing or more than a few days old.
    func start() {
        let ids = saved.identifiers
        Task { @MainActor in
            var lists: [WKContentRuleList] = []
            for id in ids {
                if let list = await lookUp(id) { lists.append(list) }
            }
            ruleLists = lists
            NotificationCenter.default.post(name: .adblockChanged, object: nil)
            let stale = lastUpdate.map { Date().timeIntervalSince($0) > 3 * 86400 } ?? true
            if lists.count != ids.count || lists.isEmpty || stale || saved.lists != Prefs.shared.adblockLists { update() }
        }
        queue.async { [self] in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("engine.dat")) else { return }
            let loaded = data.withUnsafeBytes { mizu_engine_load($0.bindMemory(to: UInt8.self).baseAddress, data.count) }
            guard let loaded else { return }
            useResources(loaded)
            engine = loaded
        }
    }

    private func useResources(_ engine: OpaquePointer) {
        guard let json = try? Data(contentsOf: directory.appendingPathComponent("resources.json")) else { return }
        _ = json.withUnsafeBytes { mizu_engine_use_resources(engine, $0.bindMemory(to: UInt8.self).baseAddress, json.count) }
    }

    @MainActor private func lookUp(_ id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: id) { list, _ in continuation.resume(returning: list) }
        }
    }

    @MainActor private func compile(_ json: String, id: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, error in
                if let error { NSLog("Mizu adblock: %@ did not compile: %@", id, error.localizedDescription) }
                continuation.resume(returning: list)
            }
        }
    }

    /// Compiles a chunk of rules. Should WebKit reject it, the chunk is cut in
    /// half again and again so that only the offending rules are lost.
    @MainActor private func compileSplitting(_ json: String, id: String, depth: Int = 0) async -> [WKContentRuleList] {
        if let list = await compile(json, id: id) { return [list] }
        guard depth < 14, let all = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        let isException: ([String: Any]) -> Bool = { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" }
        let exceptions = all.filter(isException), rules = all.filter { !isException($0) }
        guard rules.count > 1 else { return [] }
        var lists: [WKContentRuleList] = []
        let half = rules.count / 2
        for (index, part) in [Array(rules[..<half]), Array(rules[half...])].enumerated() {
            guard let data = try? JSONSerialization.data(withJSONObject: part + exceptions), let text = String(data: data, encoding: .utf8) else { continue }
            lists += await compileSplitting(text, id: "\(id)\(index)", depth: depth + 1)
        }
        return lists
    }

    /// Downloads the chosen filter lists and rebuilds the rules from them.
    func update() {
        if case .updating = state { return }
        let chosen = FilterList.all.filter { Prefs.shared.adblockLists.contains($0.id) }
        state = .updating(L("Downloading filter lists…"))
        Task { @MainActor in
            var text = ""
            for list in chosen {
                for (index, address) in list.urls.enumerated() {
                    text += await fetch(address, cache: "lists/\(list.id)-\(index).txt").map { String(decoding: $0, as: UTF8.self) + "\n" } ?? ""
                }
            }
            _ = await fetch(Self.resourcesURL, cache: "resources.json")
            guard !text.isEmpty || chosen.isEmpty else {
                state = .failed(L("The filter lists could not be downloaded."))
                return
            }
            state = .updating(L("Preparing rules…"))
            let (chunks, count) = await build(from: text)
            let stamp = String(Int(Date().timeIntervalSince1970))
            var lists: [WKContentRuleList] = []
            for (index, chunk) in chunks.enumerated() {
                state = .updating(L("Compiling rules (%d of %d)…", index + 1, chunks.count))
                lists += await compileSplitting(chunk, id: "mizu-\(stamp)-\(index)")
            }
            let old = saved.identifiers
            ruleLists = lists
            ruleCount = count
            lastUpdate = Date()
            saved = Saved(identifiers: lists.map(\.identifier), lists: chosen.map(\.id), ruleCount: count, lastUpdate: lastUpdate)
            for id in old where !saved.identifiers.contains(id) {
                store.removeContentRuleList(forIdentifier: id) { _ in }
            }
            state = .idle
            NotificationCenter.default.post(name: .adblockChanged, object: nil)
            // Building the rules takes a few hundred megabytes for a moment;
            // hand the freed pages back rather than sitting on them.
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Fetches a list, keeping a copy; when the download fails the copy from
    /// last time is used instead.
    private func fetch(_ address: String, cache: String) async -> Data? {
        let file = directory.appendingPathComponent(cache)
        if let url = URL(string: address) {
            var request = URLRequest(url: url, timeoutInterval: 30)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                try? data.write(to: file, options: .atomic)
                return data
            }
        }
        return try? Data(contentsOf: file)
    }

    /// Turns filter text into chunks of WebKit rules and a fresh engine.
    private func build(from text: String) async -> (chunks: [String], count: Int) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let bytes = Array(text.utf8)
                var chunks: [String] = []
                if let raw = mizu_content_rules(bytes, bytes.count, Self.chunk) {
                    chunks = String(cString: raw).split(separator: "\n").map(String.init)
                    mizu_string_free(raw)
                }
                let fresh = mizu_engine_new(bytes, bytes.count)
                if let fresh {
                    var length = 0
                    if let data = mizu_engine_serialize(fresh, &length) {
                        try? Data(bytes: data, count: length).write(to: directory.appendingPathComponent("engine.dat"), options: .atomic)
                        mizu_bytes_free(data, length)
                    }
                    useResources(fresh)
                }
                if let engine { mizu_engine_free(engine) }
                engine = fresh
                var count = 0
                text.enumerateLines { line, _ in
                    if !line.isEmpty && !line.hasPrefix("!") && !line.hasPrefix("[") { count += 1 }
                }
                continuation.resume(returning: (chunks, count))
            }
        }
    }

    // MARK: Per page

    static func isAllowlisted(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return Prefs.shared.allowlist.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Whether the blocker is at work on pages of this host.
    func isActive(on host: String?) -> Bool {
        Prefs.shared.adblock && !Self.isAllowlisted(host)
    }

    func setAllowlisted(_ host: String, _ allowed: Bool) {
        let host = host.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        var list = Prefs.shared.allowlist.filter { $0 != host }
        if allowed { list.append(host) }
        Prefs.shared.allowlist = list
        NotificationCenter.default.post(name: .adblockChanged, object: nil)
    }

    /// Attaches the network rules to a web view, or takes them off, to suit
    /// the site its main frame is showing.
    func configure(_ controller: WKUserContentController, host: String?) {
        controller.removeAllContentRuleLists()
        guard isActive(on: host) else { return }
        for list in ruleLists { controller.add(list) }
    }

    /// What to hide and inject on a page. Calls back on the main queue.
    func cosmetics(for url: URL, completion: @escaping (Cosmetics?) -> Void) {
        guard Prefs.shared.cosmetic, isActive(on: url.host), url.scheme?.hasPrefix("http") == true else { return completion(nil) }
        queue.async { [self] in
            var result: Cosmetics?
            if let engine, let raw = mizu_engine_cosmetics(engine, url.absoluteString) {
                if let json = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any] {
                    result = Cosmetics(selectors: json["hide_selectors"] as? [String] ?? [],
                                       script: json["injected_script"] as? String ?? "",
                                       exceptions: json["exceptions"] as? [String] ?? [],
                                       genericHide: json["generichide"] as? Bool ?? false)
                }
                mizu_string_free(raw)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The generic hiding selectors for classes and ids a page has seen.
    func hiddenSelectors(classes: [String], ids: [String], exceptions: [String], completion: @escaping ([String]) -> Void) {
        queue.async { [self] in
            var selectors: [String] = []
            if let engine,
               let seen = try? JSONSerialization.data(withJSONObject: ["classes": classes, "ids": ids, "exceptions": exceptions]),
               let raw = mizu_engine_hidden_selectors(engine, String(decoding: seen, as: UTF8.self)) {
                selectors = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String]) ?? []
                mizu_string_free(raw)
            }
            DispatchQueue.main.async { completion(selectors) }
        }
    }

    /// The script that reports a page's classes and ids and hides what comes
    /// back. Runs in Mizu's own script world, out of the page's reach.
    static let collectorScript = """
    (() => {
      if (window.__mizuHide) return;
      window.__mizuHide = true;
      const seenClasses = new Set(), seenIds = new Set();
      let classes = [], ids = [], timer = 0;
      const style = document.createElement('style');
      const hide = selectors => {
        if (!selectors || !selectors.length) return;
        if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
        for (const selector of selectors) {
          try { style.sheet.insertRule(selector + '{display:none!important}', style.sheet.cssRules.length); } catch (e) {}
        }
      };
      const flush = () => {
        timer = 0;
        if (!classes.length && !ids.length) return;
        const message = { classes, ids };
        classes = []; ids = [];
        window.webkit.messageHandlers.mizuHide.postMessage(message).then(hide, () => {});
      };
      const note = element => {
        if (element.id && typeof element.id === 'string' && !seenIds.has(element.id)) { seenIds.add(element.id); ids.push(element.id); }
        const list = element.classList;
        if (list) for (let i = 0; i < list.length; i++) {
          const name = list[i];
          if (!seenClasses.has(name)) { seenClasses.add(name); classes.push(name); }
        }
      };
      const scan = root => {
        if (root.nodeType !== 1) return;
        note(root);
        const all = root.querySelectorAll('[id],[class]');
        for (let i = 0; i < all.length; i++) note(all[i]);
        if ((classes.length || ids.length) && !timer) timer = setTimeout(flush, 80);
      };
      new MutationObserver(records => {
        for (const record of records) {
          if (record.type === 'attributes') scan(record.target);
          else for (const node of record.addedNodes) scan(node);
        }
      }).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['class', 'id'] });
      if (document.documentElement) scan(document.documentElement);
    })();
    """

    /// The script that hides a page's own selectors from the first paint.
    static func hidingScript(_ selectors: [String]) -> String {
        var css = ""
        // A bad selector voids the rule it is in, so keep the rules short.
        for start in stride(from: 0, to: selectors.count, by: 20) {
            css += selectors[start..<min(start + 20, selectors.count)].joined(separator: ",") + "{display:none!important}\n"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: [css]), let literal = String(data: data, encoding: .utf8) else { return "" }
        return """
        (() => {
          const style = document.createElement('style');
          style.textContent = \(literal)[0];
          (document.head || document.documentElement).appendChild(style);
        })();
        """
    }
}
