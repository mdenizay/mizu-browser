import AppKit
import WebKit

/// Pictures of the app's windows, for the screenshots in the README and for
/// checking the interface from a script. With MIZU_DEBUG set, posting the
/// distributed notification "com.mdenizay.mizu.snapshot" with a folder path
/// as its object writes one PNG per window into that folder.
enum Debug {
    static func start() {
        guard ProcessInfo.processInfo.environment["MIZU_DEBUG"] != nil else { return }
        // "com.mdenizay.mizu.do" runs a command in the front window: "open <url>",
        // "settings <pane>", "group <name>", or the name of a menu action
        // ("toggleMobileView:", "selectTabByNumber: 2").
        DistributedNotificationCenter.default().addObserver(forName: .init("com.mdenizay.mizu.do"), object: nil, queue: .main) { note in
            guard let command = note.object as? String, let controller = AppDelegate.shared.frontWindow ?? BrowserWindowController.all.first else { return }
            let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "open": URL(string: argument).map(controller.open)
            case "settings": SettingsWindow.show(SettingsPane(rawValue: argument) ?? .general)
            case "setup": SetupWindow.show()
            case "group": controller.tabs.selected.map { _ = controller.tabs.makeGroup(with: $0, name: argument) }
            case "join": controller.tabs.selected.map { controller.tabs.add($0, to: controller.tabs.visibleGroups.last) }
            case "fold": controller.tabs.visibleGroups.first.map(controller.tabs.toggle)
            case "private": AppDelegate.shared.newPrivateWindow(nil)
            case "js":
                controller.tabs.selected?.webView?.evaluateJavaScript(argument) { result, error in
                    NSLog("js => %@ %@", String(describing: result), error.map { "\($0)" } ?? "")
                }
            case "screenshot":
                controller.capture(fullPage: true) { png in try? png?.write(to: URL(fileURLWithPath: argument)) }
            default:
                let selector = NSSelectorFromString(parts[0])
                let item = NSMenuItem()
                item.tag = Int(argument) ?? 0
                if controller.responds(to: selector) { controller.perform(selector, with: item) }
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.mdenizay.mizu.dump"), object: nil, queue: .main) { _ in
            NSLog("active=%d hidden=%d key=%@ main=%@", NSApp.isActive ? 1 : 0, NSApp.isHidden ? 1 : 0, String(describing: NSApp.keyWindow), String(describing: NSApp.mainWindow))
            if let tree = BrowserWindowController.all.first?.window?.contentView?.perform(Selector(("_subtreeDescription")))?.takeUnretainedValue() as? String {
                try? tree.write(toFile: "/tmp/mizu-tree.txt", atomically: true, encoding: .utf8)
            }
            func walk(_ menu: NSMenu, _ depth: Int) {
                for item in menu.items where !item.isSeparatorItem {
                    NSLog("menu %@%@ -> %@ target=%@", String(repeating: "  ", count: depth), item.title, item.action.map(NSStringFromSelector) ?? "-", String(describing: item.target))
                    if let sub = item.submenu { walk(sub, depth + 1) }
                }
            }
            if let edit = NSApp.mainMenu?.items.dropFirst(2).first?.submenu { walk(edit, 0) }
            let fill = Selector(("_handleInsertFromPasswordsCommand:"))
            let responder = BrowserWindowController.all.first?.window?.firstResponder
            NSLog("first responder=%@ respondsToFill=%d target=%@", String(describing: responder.map { type(of: $0) }), responder?.responds(to: fill) == true ? 1 : 0,
                  String(describing: NSApp.target(forAction: fill, to: nil, from: nil).map { type(of: $0 as AnyObject) }))
            var chain = responder
            while let current = chain {
                NSLog("  chain %@ responds=%d", String(describing: type(of: current)), current.responds(to: fill) ? 1 : 0)
                chain = current.nextResponder
            }
            for controller in BrowserWindowController.all {
                NSLog("tabs: %@", controller.tabs.tabs.map { "\($0.displayTitle.prefix(12))=\($0.isLoaded ? "loaded" : "asleep")" }.joined(separator: ", "))
            }
            for window in NSApp.windows {
                NSLog("window %@ visible=%d key=%d main=%d canKey=%d canMain=%d level=%d frame=%@ screen=%@ occl=%d", window.title, window.isVisible ? 1 : 0, window.isKeyWindow ? 1 : 0,
                      window.isMainWindow ? 1 : 0, window.canBecomeKey ? 1 : 0, window.canBecomeMain ? 1 : 0, window.level.rawValue, NSStringFromRect(window.frame),
                      String(describing: window.screen?.localizedName), window.occlusionState.contains(.visible) ? 1 : 0)
            }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.mdenizay.mizu.snapshot"), object: nil, queue: .main) { note in
            guard let folder = note.object as? String else { return }
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            for (index, window) in (NSApp.orderedWindows + NSApp.windows.filter { !NSApp.orderedWindows.contains($0) }).filter(\.isVisible).enumerated() {
                snapshot(window) { image in
                    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    try? NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: folder).appendingPathComponent("window-\(index).png"))
                }
            }
        }
    }

    /// Draws a window's views, then lays the page over them: web content is
    /// painted by another process and is not part of what the views draw.
    private static func snapshot(_ window: NSWindow, completion: @escaping (NSImage) -> Void) {
        guard let root = window.contentView?.superview ?? window.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return }
        root.cacheDisplay(in: root.bounds, to: rep)
        let chrome = NSImage(size: root.bounds.size)
        chrome.addRepresentation(rep)
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView, !web.isHiddenOrHasHiddenAncestor { return web }
            return view.subviews.lazy.compactMap(webView).first
        }
        guard let web = webView(in: root) else { return completion(chrome) }
        web.takeSnapshot(with: nil) { page, _ in
            let frame = web.convert(web.bounds, to: root)
            completion(NSImage(size: root.bounds.size, flipped: false) { rect in
                chrome.draw(in: rect)
                if let page {
                    NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10).addClip()
                    page.draw(in: frame)
                }
                return true
            })
        }
    }
}
