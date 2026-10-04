import AppKit
import Combine

/// Looks a string up in the chosen language (Settings → General), falling
/// back to the key itself, which is the English text.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Prefs.languageBundle.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

struct SearchEngine: Identifiable {
    let id: String
    let name: String
    let template: String

    static let all = [
        SearchEngine(id: "google", name: "Google", template: "https://www.google.com/search?q=%@"),
        SearchEngine(id: "duckduckgo", name: "DuckDuckGo", template: "https://duckduckgo.com/?q=%@"),
        SearchEngine(id: "brave", name: "Brave Search", template: "https://search.brave.com/search?q=%@"),
        SearchEngine(id: "bing", name: "Bing", template: "https://www.bing.com/search?q=%@"),
        SearchEngine(id: "yandex", name: "Yandex", template: "https://yandex.com/search/?text=%@"),
        SearchEngine(id: "kagi", name: "Kagi", template: "https://kagi.com/search?q=%@"),
    ]
}

/// App-wide settings, kept in the user defaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()
    /// Development runs on a scratch data folder keep their settings apart too.
    private static let defaults: UserDefaults = ProcessInfo.processInfo.environment["MIZU_DATA"] != nil
        ? UserDefaults(suiteName: "com.mdenizay.mizu.dev") ?? .standard : .standard

    private static func value<T>(_ key: String, _ fallback: T) -> T {
        defaults.object(forKey: key) as? T ?? fallback
    }

    /// "vertical" (a sidebar of tabs) or "horizontal" (a strip along the top).
    @Published var tabLayout: String = value("tabLayout", "vertical") { didSet { save("tabLayout", tabLayout) } }
    @Published var sidebarVisible: Bool = value("sidebarVisible", true) { didSet { save("sidebarVisible", sidebarVisible) } }
    /// With the sidebar collapsed, keep a narrow strip of tab icons.
    @Published var compactSidebar: Bool = value("compactSidebar", true) { didSet { save("compactSidebar", compactSidebar) } }
    /// With tabs on top, put them and the address in a single row.
    @Published var compactTabBar: Bool = value("compactTabBar", true) { didSet { save("compactTabBar", compactTabBar) } }
    @Published var sidebarWidth: Double = value("sidebarWidth", 240) { didSet { save("sidebarWidth", sidebarWidth) } }
    /// "system", "light" or "dark".
    @Published var appearance: String = value("appearance", "system") { didSet { save("appearance", appearance); Prefs.applyAppearance() } }
    @Published var searchEngine: String = value("searchEngine", "google") { didSet { save("searchEngine", searchEngine) } }
    @Published var restoreSession: Bool = value("restoreSession", true) { didSet { save("restoreSession", restoreSession) } }
    /// How many background tabs stay loaded; older ones are put to sleep.
    /// Minutes a background tab may sit unused before it is put to sleep (0: never).
    @Published var sleepAfter: Int = value("sleepAfter", 15) { didSet { save("sleepAfter", sleepAfter) } }
    /// Window sizes saved for the device view, as "1024x768".
    @Published var viewports: [String] = value("viewports", []) { didSet { save("viewports", viewports) } }
    /// Sites marked by hand as production, staging or development ("none" unmarks a guess).
    @Published var environments: [String: String] = value("environments", [:]) { didSet { save("environments", environments) } }
    @Published var warmTabs: Int = value("warmTabs", 4) { didSet { save("warmTabs", warmTabs) } }
    @Published var language: String = value("language", "system") { didSet { save("language", language) } }
    @Published var askDownloadLocation: Bool = value("askDownloadLocation", false) { didSet { save("askDownloadLocation", askDownloadLocation) } }
    @Published var didSetup: Bool = value("didSetup", false) { didSet { save("didSetup", didSetup) } }

    @Published var adblock: Bool = value("adblock", true) { didSet { save("adblock", adblock) } }
    @Published var cosmetic: Bool = value("cosmetic", true) { didSet { save("cosmetic", cosmetic) } }
    @Published var adblockLists: [String] = value("adblockLists", FilterList.all.filter(\.onByDefault).map(\.id)) { didSet { save("adblockLists", adblockLists) } }
    /// Sites the blocker leaves alone.
    @Published var allowlist: [String] = value("allowlist", []) { didSet { save("allowlist", allowlist) } }

    private func save(_ key: String, _ value: Any) {
        Prefs.defaults.set(value, forKey: key)
    }

    var engine: SearchEngine {
        SearchEngine.all.first { $0.id == searchEngine } ?? SearchEngine.all[0]
    }

    static func applyAppearance() {
        switch shared.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// The bundle strings are read from: the language picked in Settings, or
    /// the system's choice. Read once; changing the language needs a restart.
    static let languageBundle: Bundle = {
        let language = defaults.string(forKey: "language") ?? "system"
        if language != "system", let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }()

    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    /// ~/Library/Application Support/Mizu
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(ProcessInfo.processInfo.environment["MIZU_DATA"] ?? "Mizu")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Notification.Name {
    /// A profile's name, icon or colours changed, or profiles were added or removed.
    static let profilesChanged = Notification.Name("MizuProfilesChanged")
    static let bookmarksChanged = Notification.Name("MizuBookmarksChanged")
    /// The blocker has new rules, or was switched on or off.
    static let adblockChanged = Notification.Name("MizuAdblockChanged")
}
