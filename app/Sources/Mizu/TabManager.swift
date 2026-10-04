import AppKit
import WebKit

/// A named, coloured run of tabs that can be folded away.
final class TabGroup {
    let id: UUID
    let profile: Profile
    var name: String
    /// Index into `TabGroup.colors`.
    var color: Int
    var collapsed: Bool

    init(id: UUID = UUID(), profile: Profile, name: String, color: Int, collapsed: Bool = false) {
        self.id = id
        self.profile = profile
        self.name = name
        self.color = color
        self.collapsed = collapsed
    }

    static let colors: [(name: String, hex: Int)] = [
        ("Blue", 0x0A84FF), ("Purple", 0x8E5BE8), ("Pink", 0xE8497F), ("Red", 0xE5484D),
        ("Orange", 0xE8792B), ("Yellow", 0xD9A514), ("Green", 0x1DAA61), ("Grey", 0x8E8E93),
    ]

    var nsColor: NSColor { NSColor(hex: Self.colors[color % Self.colors.count].hex) }
}

/// What the tab list shows, in order.
enum TabItem {
    case group(TabGroup, count: Int)
    case tab(Tab)
}

/// The tabs of one window. A window holds tabs of every profile and shows
/// those of the profile it is switched to.
final class TabManager {
    weak var window: BrowserWindowController?
    private(set) var tabs: [Tab] = []
    private(set) var groups: [TabGroup] = []
    private(set) var profile: Profile
    /// The tab in front, per profile.
    private var selection: [UUID: Tab] = [:]
    private var closed: [(profile: Profile, url: URL, title: String, state: Data?)] = []

    init(profile: Profile) {
        self.profile = profile
    }

    var selected: Tab? { selection[profile.id] }
    var visible: [Tab] { tabs.filter { $0.profile === profile } }
    var pinned: [Tab] { visible.filter(\.pinned) }

    func group(_ id: UUID?) -> TabGroup? {
        id.flatMap { id in groups.first { $0.id == id } }
    }

    var visibleGroups: [TabGroup] { groups.filter { $0.profile === profile } }

    /// The unpinned tabs with a header before each group; the tabs of a
    /// folded group are left out.
    var items: [TabItem] {
        var items: [TabItem] = []
        var current: UUID?
        for tab in visible where !tab.pinned {
            if tab.groupID != current, let group = group(tab.groupID) {
                items.append(.group(group, count: tabs.filter { $0.groupID == group.id }.count))
            }
            current = tab.groupID
            if group(tab.groupID)?.collapsed != true { items.append(.tab(tab)) }
        }
        return items
    }

    // MARK: Opening and closing

    /// Opens a tab. With `after`, it goes next to that tab and joins its group.
    @discardableResult
    func newTab(url: URL?, select: Bool = true, after: Tab? = nil, loading: Bool = true) -> Tab {
        let tab = Tab(profile: after?.profile ?? profile, url: url)
        tab.manager = self
        if let after, let index = tabs.firstIndex(where: { $0 === after }) {
            tab.groupID = after.pinned ? nil : after.groupID
            tabs.insert(tab, at: index + 1)
        } else {
            tabs.append(tab)
        }
        normalize()
        if select {
            self.select(tab)
        } else if loading, url != nil {
            tab.lastActive = Date()
            tab.load()
            TabLifecycle.enforce()
        }
        changed()
        return tab
    }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let url = tab.url, !tab.profile.isPrivate {
            closed.append((tab.profile, url, tab.displayTitle, tab.sessionState))
            if closed.count > 25 { closed.removeFirst() }
        }
        let siblings = tabs.filter { $0.profile === tab.profile }
        let position = siblings.firstIndex { $0 === tab } ?? 0
        let wasSelected = selection[tab.profile.id] === tab
        tab.discard()
        tabs.remove(at: index)
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        if wasSelected {
            selection[tab.profile.id] = nil
            let rest = siblings.filter { $0 !== tab }
            if tab.profile === profile {
                if rest.isEmpty {
                    newTab(url: nil)
                } else {
                    select(rest[min(position, rest.count - 1)])
                }
            } else {
                selection[tab.profile.id] = rest.isEmpty ? nil : rest[min(position, rest.count - 1)]
            }
        }
        changed()
    }

    func closeOthers(_ tab: Tab) {
        for other in visible where other !== tab && !other.pinned { close(other) }
    }

    var canReopen: Bool { !closed.isEmpty }

    func reopenClosed() {
        guard let last = closed.popLast() else { return }
        if last.profile !== profile, Profiles.shared.all.contains(where: { $0 === last.profile }) { switchProfile(last.profile) }
        let tab = Tab(profile: profile, url: last.url, title: last.title, state: last.state)
        tab.manager = self
        tabs.append(tab)
        select(tab)
        changed()
    }

    @discardableResult
    func duplicate(_ tab: Tab) -> Tab {
        newTab(url: tab.url, after: tab)
    }

    // MARK: Selection

    func select(_ tab: Tab) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        if tab.profile !== profile { profile = tab.profile }
        selection[profile.id] = tab
        tab.lastActive = Date()
        if tab.url != nil { tab.load() }
        if let group = group(tab.groupID), group.collapsed { group.collapsed = false }
        window?.selectionChanged()
        TabLifecycle.enforce()
        Session.scheduleSave()
    }

    /// Moves the selection through the tabs that can be seen, wrapping round.
    func selectNeighbour(_ offset: Int) {
        let shown = visible.filter { $0.pinned || group($0.groupID)?.collapsed != true || $0 === selected }
        guard let selected, let index = shown.firstIndex(where: { $0 === selected }), shown.count > 1 else { return }
        select(shown[(index + offset + shown.count) % shown.count])
    }

    /// ⌘1…⌘8 pick a tab by position; ⌘9 the last one.
    func select(position: Int) {
        let shown = visible
        guard !shown.isEmpty else { return }
        select(position >= 8 ? shown[shown.count - 1] : shown[min(position, shown.count - 1)])
    }

    // MARK: Profiles

    func switchProfile(_ new: Profile) {
        guard new !== profile, !profile.isPrivate else { return }
        profile = new
        if let tab = selection[new.id] ?? visible.first {
            select(tab)
        } else {
            newTab(url: nil)
        }
        window?.profileChanged()
        changed()
    }

    func profileRemoved(_ removed: Profile, fallback: Profile) {
        for tab in tabs where tab.profile === removed { tab.discard() }
        tabs.removeAll { $0.profile === removed }
        groups.removeAll { $0.profile === removed }
        selection[removed.id] = nil
        closed.removeAll { $0.profile === removed }
        if profile === removed {
            profile = fallback
            if let tab = selection[fallback.id] ?? visible.first { select(tab) } else { newTab(url: nil) }
            window?.profileChanged()
        }
        changed()
    }

    // MARK: Arranging

    /// Keeps pinned tabs first and the tabs of a group next to each other.
    private func normalize() {
        var result: [Tab] = tabs.filter(\.pinned)
        var placed = Set<UUID>()
        for tab in tabs where !tab.pinned {
            guard let id = tab.groupID, group(id) != nil else {
                tab.groupID = nil
                result.append(tab)
                continue
            }
            if placed.insert(id).inserted {
                result += tabs.filter { !$0.pinned && $0.groupID == id }
            }
        }
        tabs = result
    }

    /// Puts a tab before another (or last), as when it is dragged. The tab
    /// joins the group it lands inside of and leaves the one it is dragged out of.
    func move(_ tab: Tab, before other: Tab?) {
        guard tab !== other, let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        if let other, other.pinned != tab.pinned { return }
        tabs.remove(at: from)
        let to = other.flatMap { other in tabs.firstIndex { $0 === other } } ?? tabs.count
        if !tab.pinned {
            let previous = to > 0 && tabs[to - 1].profile === tab.profile ? tabs[to - 1] : nil
            // Inside a group when its neighbours on both sides belong to it.
            tab.groupID = other?.groupID != nil && previous?.groupID == other?.groupID ? other?.groupID : nil
        }
        tabs.insert(tab, at: to)
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        changed()
    }

    func setPinned(_ tab: Tab, _ pinned: Bool) {
        tab.pinned = pinned
        if pinned { tab.groupID = nil }
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        normalize()
        changed()
    }

    @discardableResult
    func makeGroup(with tab: Tab, name: String) -> TabGroup {
        let used = Set(visibleGroups.map(\.color))
        let color = (0..<TabGroup.colors.count).first { !used.contains($0) } ?? groups.count % TabGroup.colors.count
        let group = TabGroup(profile: tab.profile, name: name, color: color)
        groups.append(group)
        add(tab, to: group)
        return group
    }

    func add(_ tab: Tab, to group: TabGroup?) {
        tab.pinned = false
        tab.groupID = group?.id
        if let group, let index = tabs.firstIndex(where: { $0 === tab }) {
            // Join at the end of the group.
            tabs.remove(at: index)
            let last = tabs.lastIndex { $0.groupID == group.id } ?? min(index, tabs.count) - 1
            tabs.insert(tab, at: last + 1)
        }
        groups.removeAll { group in !tabs.contains { $0.groupID == group.id } }
        normalize()
        changed()
    }

    func toggle(_ group: TabGroup) {
        group.collapsed.toggle()
        changed()
    }

    func ungroup(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id { tab.groupID = nil }
        groups.removeAll { $0 === group }
        changed()
    }

    func close(_ group: TabGroup) {
        for tab in tabs where tab.groupID == group.id { close(tab) }
    }

    func groupChanged() {
        changed()
    }

    // MARK: Changes

    private func changed() {
        window?.tabsChanged()
        Session.scheduleSave()
    }

    func tabUpdated(_ tab: Tab) {
        window?.tabUpdated(tab)
    }

    func tabProgressed(_ tab: Tab) {
        if tab === selected { window?.progressChanged() }
    }

    func tabBlockedCountChanged(_ tab: Tab) {
        if tab === selected { window?.blockedCountChanged() }
    }

    // MARK: Session

    func rows(windowID: Int) -> (groups: [GroupRow], tabs: [TabRow]) {
        let groupRows = groups.filter { !$0.profile.isPrivate }.map {
            GroupRow(id: $0.id.uuidString, windowId: windowID, profileId: $0.profile.key, name: $0.name, color: $0.color, collapsed: $0.collapsed)
        }
        let tabRows = tabs.enumerated().compactMap { index, tab -> TabRow? in
            guard !tab.profile.isPrivate, let url = tab.url else { return nil }
            return TabRow(id: tab.id.uuidString, windowId: windowID, profileId: tab.profile.key, groupId: tab.groupID?.uuidString,
                          url: url.absoluteString, title: tab.displayTitle, pinned: tab.pinned, position: index,
                          lastActive: tab.lastActive.timeIntervalSince1970, selected: selection[tab.profile.id] === tab, state: tab.sessionState)
        }
        return (groupRows, tabRows)
    }

    /// Brings back the tabs of an earlier run. They come back asleep; only
    /// the one in front loads.
    func restore(groups groupRows: [GroupRow], tabs tabRows: [TabRow]) {
        for row in groupRows {
            guard let owner = Profiles.shared.profile(row.profileId), let id = UUID(uuidString: row.id) else { continue }
            groups.append(TabGroup(id: id, profile: owner, name: row.name, color: row.color, collapsed: row.collapsed))
        }
        for row in tabRows {
            guard let owner = Profiles.shared.profile(row.profileId), let url = URL(string: row.url) else { continue }
            let tab = Tab(profile: owner, id: UUID(uuidString: row.id) ?? UUID(), url: url, title: row.title, state: row.state)
            tab.manager = self
            tab.pinned = row.pinned
            tab.groupID = row.groupId.flatMap(UUID.init(uuidString:))
            tab.lastActive = Date(timeIntervalSince1970: row.lastActive)
            tabs.append(tab)
            if row.selected { selection[owner.id] = tab }
        }
        normalize()
        if let tab = selected ?? visible.first { select(tab) } else { newTab(url: nil) }
        changed()
    }
}

/// Keeps memory in check: the tab in front of each window is live, the few
/// used most recently stay loaded so that going back to them is instant, and
/// the rest are put to sleep until they are picked again.
enum TabLifecycle {
    private static var pressure: DispatchSourceMemoryPressure?

    static func enforce(keeping warm: Int = Prefs.shared.warmTabs) {
        let front = Set(BrowserWindowController.all.compactMap { $0.tabs.selected }.map(ObjectIdentifier.init))
        let background = BrowserWindowController.all.flatMap(\.tabs.tabs)
            .filter { $0.isLoaded && !front.contains(ObjectIdentifier($0)) }
            .sorted { $0.lastActive > $1.lastActive }
        for tab in background.dropFirst(max(warm, 0)) where tab.canSleep {
            tab.sleep()
            tab.manager?.tabUpdated(tab)
        }
    }

    /// When the system runs short of memory, the warm tabs go to sleep too.
    static func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { enforce(keeping: 0) }
        source.resume()
        pressure = source
    }
}

/// Remembers the open windows and tabs between runs.
enum Session {
    private static var pending = false
    private static var frozen = false

    /// Keeps the session as it is now: called when the last window closes, so
    /// that its tabs are what the next launch (or window) brings back.
    static func freeze() {
        saveNow()
        frozen = true
    }

    static func thaw() {
        frozen = false
    }

    static func scheduleSave() {
        guard !pending, !frozen else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            pending = false
            if !frozen { Store.shared.save(snapshot()) }
        }
    }

    static func saveNow() {
        if !frozen { Store.shared.saveNow(snapshot()) }
    }

    private static func snapshot() -> SessionData {
        var session = SessionData()
        let windows = BrowserWindowController.all.filter { !$0.tabs.profile.isPrivate }
        for (index, controller) in windows.enumerated() {
            guard let window = controller.window else { continue }
            session.windows.append(WindowRow(id: index, profileId: controller.tabs.profile.key, frame: NSStringFromRect(window.frame)))
            let rows = controller.tabs.rows(windowID: index)
            session.groups += rows.groups
            session.tabs += rows.tabs
        }
        return session
    }
}
