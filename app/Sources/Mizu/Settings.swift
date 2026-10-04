import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, profiles, blocker, passwords, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .appearance: return L("Appearance")
        case .profiles: return L("Profiles")
        case .blocker: return L("Ad Blocker")
        case .passwords: return L("Passwords")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .profiles: return "person.2"
        case .blocker: return "shield.lefthalf.filled"
        case .passwords: return "key"
        case .about: return "info.circle"
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var pane = SettingsPane.general
}

enum SettingsWindow {
    private static var window: NSWindow?
    private static let model = SettingsModel()

    static func show(_ pane: SettingsPane) {
        model.pane = pane
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = L("Settings")
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            created.center()
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button { model.pane = pane } label: {
                        Label(pane.title, systemImage: pane.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(model.pane == pane ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.top, 44)
            .frame(width: 180)
            .background(.quaternary.opacity(0.35))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.pane.title).font(.title2.weight(.bold))
                    switch model.pane {
                    case .general: GeneralPane()
                    case .appearance: AppearancePane()
                    case .profiles: ProfilesPane()
                    case .blocker: BlockerPane()
                    case .passwords: PasswordsPane()
                    case .about: AboutPane()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 24)
            }
        }
        .frame(width: 640, height: 520)
        .toggleStyle(RowToggleStyle())
    }
}

/// A switch at the trailing edge of its row, the label filling the rest.
struct RowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// A titled block of settings.
private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct GeneralPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var isDefault = AppDelegate.isDefaultBrowser
    private let startLanguage = Prefs.shared.language

    var body: some View {
        Block(title: L("Browser")) {
            HStack {
                Text(isDefault ? L("Mizu is your default browser.") : L("Mizu is not your default browser."))
                Spacer()
                if !isDefault {
                    Button(L("Make Default")) {
                        AppDelegate.makeDefaultBrowser { isDefault = AppDelegate.isDefaultBrowser }
                    }
                }
            }
            Picker(L("Search Engine"), selection: $prefs.searchEngine) {
                ForEach(SearchEngine.all) { Text($0.name).tag($0.id) }
            }
            Toggle(L("Reopen the tabs of last time at launch"), isOn: $prefs.restoreSession)
            Toggle(L("Ask where to save each download"), isOn: $prefs.askDownloadLocation)
        }
        Block(title: L("Tabs")) {
            Picker(L("Tabs"), selection: $prefs.tabLayout) {
                Text(L("In a sidebar")).tag("vertical")
                Text(L("Along the top")).tag("horizontal")
            }
            .pickerStyle(.segmented).labelsHidden()
            Stepper(value: $prefs.warmTabs, in: 0...12) {
                Text(L("Keep %d background tabs loaded", prefs.warmTabs))
            }
            Text(L("Tabs you have not used for a while are put to sleep to free memory. They come back, where you left them, when you pick them."))
                .font(.callout).foregroundStyle(.secondary)
        }
        Block(title: L("Language")) {
            Picker(L("Language"), selection: $prefs.language) {
                Text(L("Same as the system")).tag("system")
                Text("English").tag("en")
                Text("Türkçe").tag("tr")
            }
            .labelsHidden()
            if prefs.language != startLanguage {
                HStack {
                    Text(L("The language changes when Mizu is restarted.")).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Restart Now")) { AppDelegate.shared.relaunch() }
                }
            }
        }
    }
}

private struct AppearancePane: View {
    @ObservedObject private var profiles = Profiles.shared
    @State private var selected: UUID?

    private var profile: Profile {
        profiles.all.first { $0.id == selected } ?? AppDelegate.shared.currentProfile
    }

    var body: some View {
        Block(title: "") {
            Picker(L("Profile"), selection: Binding(get: { profile.id }, set: { selected = $0 })) {
                ForEach(profiles.all) { Label($0.name, systemImage: $0.symbol).tag($0.id) }
            }
            ThemePicker(profile: profile).id(profile.id)
            Text(L("Each profile has its own colours, so you can tell at a glance which one a window is showing."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private struct ProfileEditor: View {
    @ObservedObject var profile: Profile
    let canDelete: Bool
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: profile.symbol).foregroundStyle(Color(hex: profile.color1)).frame(width: 22)
                TextField(L("Name"), text: $profile.name).textFieldStyle(.roundedBorder)
                Button(role: .destructive) { confirming = true } label: { Image(systemName: "trash") }
                    .disabled(!canDelete)
                    .help(L("Delete Profile"))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 12), alignment: .leading, spacing: 6) {
                ForEach(Profile.symbols, id: \.self) { symbol in
                    Button { profile.symbol = symbol } label: {
                        Image(systemName: symbol).font(.system(size: 12))
                            .frame(width: 26, height: 24)
                            .background(profile.symbol == symbol ? AnyShapeStyle(Color(hex: profile.color1).opacity(0.25)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog(L("Delete the profile “%@”?", profile.name), isPresented: $confirming) {
            Button(L("Delete"), role: .destructive) { Profiles.shared.remove(profile) }
        } message: {
            Text(L("Its tabs, history, bookmarks, cookies and site data are removed. This cannot be undone."))
        }
    }
}

private struct ProfilesPane: View {
    @ObservedObject private var profiles = Profiles.shared

    var body: some View {
        Text(L("Profiles keep things apart: each has its own sign-ins, cookies, history, bookmarks and tabs."))
            .font(.callout).foregroundStyle(.secondary)
        ForEach(profiles.all) { profile in
            Block(title: "") { ProfileEditor(profile: profile, canDelete: profiles.all.count > 1) }
        }
        Button {
            let colors = [0x1DAA61, 0x8E5BE8, 0xE8497F, 0x0A84FF, 0xE8792B]
            profiles.add(name: L("New Profile"), symbol: Profile.symbols[profiles.all.count % Profile.symbols.count], color1: colors[profiles.all.count % colors.count])
        } label: {
            Label(L("Add Profile"), systemImage: "plus")
        }
    }
}

private struct BlockerPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var adblock = Adblock.shared
    @State private var listsChanged = false

    var body: some View {
        Block(title: "") {
            Toggle(L("Block ads and trackers"), isOn: Binding(get: { prefs.adblock }, set: {
                prefs.adblock = $0
                NotificationCenter.default.post(name: .adblockChanged, object: nil)
            }))
            Toggle(L("Hide the empty spaces ads leave behind"), isOn: $prefs.cosmetic).disabled(!prefs.adblock)
            Text(L("Powered by Brave's adblock-rust. Blocking happens inside WebKit, so it costs no extra memory or speed."))
                .font(.callout).foregroundStyle(.secondary)
        }
        Block(title: L("Filter Lists")) {
            ForEach(FilterList.all) { list in
                Toggle(isOn: Binding(get: { prefs.adblockLists.contains(list.id) }, set: { on in
                    prefs.adblockLists = FilterList.all.map(\.id).filter { $0 == list.id ? on : prefs.adblockLists.contains($0) }
                    listsChanged = true
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(list.name)
                        Text(L(list.detail)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                switch adblock.state {
                case let .updating(step):
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                case let .failed(reason):
                    Text(reason).font(.callout).foregroundStyle(.red)
                case .idle:
                    if let date = adblock.lastUpdate {
                        Text(L("%d rules, updated %@", adblock.ruleCount, date.formatted(date: .numeric, time: .shortened)))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(listsChanged ? L("Apply") : L("Update Now")) {
                    listsChanged = false
                    adblock.update()
                }
                .disabled(adblock.state != .idle && !isFailed)
            }
        }
        Block(title: L("Sites Left Alone")) {
            if prefs.allowlist.isEmpty {
                Text(L("None. Turn the blocker off for a site from the shield in the address bar."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(prefs.allowlist, id: \.self) { host in
                HStack {
                    Text(host)
                    Spacer()
                    Button { Adblock.shared.setAllowlisted(host, false) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = adblock.state { return true }
        return false
    }
}

private struct PasswordsPane: View {
    var body: some View {
        Block(title: "") {
            Label(L("Mizu uses the passwords you keep in the Passwords app; it stores none of its own."), systemImage: "key.fill")
            Text(L("On a sign-in page, click the key in the address bar or press ⌥⌘P. Passwords asks for Touch ID and shows your accounts; the one you pick is filled into the page."))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("Open Passwords")) { Passwords.openPasswordsApp() }
        }
    }
}

private struct AboutPane: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Block(title: "") {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mizu").font(.title2.weight(.bold))
                    Text(L("Version %@", Prefs.version)).foregroundStyle(.secondary)
                    Link("github.com/mdenizay/mizu-browser", destination: URL(string: "https://github.com/mdenizay/mizu-browser")!)
                        .font(.callout)
                }
            }
        }
        Block(title: L("Updates")) {
            Toggle(L("Keep Mizu up to date automatically"), isOn: $updater.automatic).disabled(!updater.available)
            HStack {
                switch updater.state {
                case .idle: Text(updater.available ? "" : L("This build was not signed for release, so it does not update itself.")).font(.callout).foregroundStyle(.secondary)
                case .checking: Text(L("Checking…")).foregroundStyle(.secondary)
                case .upToDate: Text(L("Mizu is up to date.")).foregroundStyle(.secondary)
                case let .downloading(version): Text(L("Downloading %@…", version)).foregroundStyle(.secondary)
                case let .ready(version): Text(L("Version %@ is ready.", version))
                case let .failed(reason): Text(reason).foregroundStyle(.red)
                }
                Spacer()
                if case .ready = updater.state {
                    Button(L("Restart Now")) { updater.installAndRelaunch() }
                } else {
                    Button(L("Check Now")) { updater.check() }.disabled(!updater.available)
                }
            }
        }
        Block(title: L("Built With")) {
            Text("WebKit · [adblock-rust](https://github.com/brave/adblock-rust) (Brave, MPL-2.0) · [GRDB](https://github.com/groue/GRDB.swift) (MIT)")
                .font(.callout).foregroundStyle(.secondary)
            Text(L("Filter lists: EasyList, EasyPrivacy, uBlock Origin and AdGuard, downloaded from their authors."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// What the shield in the address bar opens: the blocker, for this site.
struct ShieldView: View {
    let host: String
    let blocked: Int
    let reload: () -> Void
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(host).font(.headline).lineLimit(1)
            if prefs.adblock {
                Toggle(L("Block ads and trackers on this site"), isOn: Binding(get: { !Adblock.isAllowlisted(host) }, set: {
                    Adblock.shared.setAllowlisted(host, !$0)
                    reload()
                }))
                .toggleStyle(RowToggleStyle())
                if !Adblock.isAllowlisted(host) {
                    Text(blocked == 1 ? L("1 request blocked on this page") : L("%d requests blocked on this page", blocked))
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text(L("The ad blocker is turned off.")).foregroundStyle(.secondary)
            }
            Button(L("Ad Blocker Settings…")) { SettingsWindow.show(.blocker) }.buttonStyle(.link)
        }
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }
}

/// The history of a profile, searchable.
enum HistoryWindow {
    private static var window: NSWindow?

    static func show(profile: Profile, open: @escaping (URL) -> Void) {
        window?.close()
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560), styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        created.title = L("History") + " — " + profile.name
        created.isReleasedWhenClosed = false
        created.contentViewController = NSHostingController(rootView: HistoryView(profile: profile, open: { url in
            open(url)
            window?.close()
        }))
        created.center()
        created.makeKeyAndOrderFront(nil)
        window = created
    }
}

private struct HistoryView: View {
    let profile: Profile
    let open: (URL) -> Void
    @State private var query = ""
    @State private var rows: [HistoryRow] = []
    @State private var confirming = false

    private func load() {
        rows = profile.isPrivate ? [] : Store.shared.history(profile: profile.key, matching: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L("Search history"), text: $query).textFieldStyle(.roundedBorder)
                Button(L("Clear…")) { confirming = true }
            }
            .padding(12)
            List(rows) { row in
                HStack(spacing: 10) {
                    if let host = URL(string: row.url)?.host, let icon = Favicons.shared.cached(host) {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title.isEmpty ? row.url : row.title).lineLimit(1)
                        Text(row.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(Date(timeIntervalSince1970: row.lastVisit).formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { if let url = URL(string: row.url) { open(url) } }
                .contextMenu {
                    Button(L("Delete")) {
                        if let id = row.id { Store.shared.deleteHistory(id: id) }
                        load()
                    }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear(perform: load)
        .onChange(of: query) { _, _ in load() }
        .confirmationDialog(L("Clear history"), isPresented: $confirming) {
            Button(L("The Last Hour")) { Store.shared.clearHistory(profile: profile.key, since: Date().addingTimeInterval(-3600)); load() }
            Button(L("Today")) { Store.shared.clearHistory(profile: profile.key, since: Calendar.current.startOfDay(for: Date())); load() }
            Button(L("All History"), role: .destructive) { Store.shared.clearHistory(profile: profile.key); load() }
        }
    }
}
