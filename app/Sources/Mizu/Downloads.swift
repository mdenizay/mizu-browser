import AppKit
import SwiftUI
import WebKit

final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable { case running, done, failed(String) }

    let id = UUID()
    let download: WKDownload
    @Published var name = ""
    @Published var fraction = 0.0
    @Published var state = State.running
    var file: URL?
    fileprivate var observation: NSKeyValueObservation?

    init(_ download: WKDownload) {
        self.download = download
        name = download.originalRequest?.url?.lastPathComponent ?? ""
    }
}

/// The files being, and that have been, downloaded since the app started.
final class Downloads: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = Downloads()
    @Published private(set) var items: [DownloadItem] = []
    /// Called when a download starts, to bring the list into view.
    var onStart: (() -> Void)?

    var active: Int { items.filter { $0.state == .running }.count }

    func adopt(_ download: WKDownload, from tab: Tab) {
        download.delegate = self
        let item = DownloadItem(download)
        item.observation = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async { item?.fraction = fraction }
        }
        items.insert(item, at: 0)
        onStart?()
        // A tab opened only to carry the download has nothing to show.
        if tab.url == nil, tab.webView?.url == nil, tab.manager?.visible.count ?? 0 > 1 { tab.manager?.close(tab) }
    }

    private func item(_ download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let item = item(download)
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        if Prefs.shared.askDownloadLocation {
            let panel = NSSavePanel()
            panel.directoryURL = folder
            panel.nameFieldStringValue = suggestedFilename
            let chosen = panel.runModal() == .OK ? panel.url : nil
            // The panel has already asked about replacing an existing file.
            if let chosen { try? FileManager.default.removeItem(at: chosen) }
            item?.file = chosen
            item?.name = chosen?.lastPathComponent ?? suggestedFilename
            if chosen == nil { items.removeAll { $0 === item } }
            return completionHandler(chosen)
        }
        // "file.zip", "file 2.zip", …: never write over something.
        let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
        var file = folder.appendingPathComponent(suggestedFilename), number = 2
        while FileManager.default.fileExists(atPath: file.path) {
            file = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        item?.file = file
        item?.name = file.lastPathComponent
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(download) else { return }
        item.fraction = 1
        item.state = .done
        objectWillChange.send()
        // The Downloads stack in the Dock bounces.
        if let file = item.file {
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(download) else { return }
        item.state = .failed(error.localizedDescription)
        objectWillChange.send()
    }

    func cancel(_ item: DownloadItem) {
        item.download.cancel { _ in }
        item.state = .failed(L("Cancelled"))
        objectWillChange.send()
    }

    func clear() {
        items.removeAll { $0.state != .running }
    }
}

/// The list in the downloads popover.
struct DownloadsView: View {
    @ObservedObject var downloads = Downloads.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Downloads")).font(.headline)
                Spacer()
                if downloads.items.contains(where: { $0.state != .running }) {
                    Button(L("Clear")) { downloads.clear() }.buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            if downloads.items.isEmpty {
                Text(L("Nothing downloaded yet.")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 26)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(downloads.items) { DownloadRow(item: $0) }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: item.file.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
                .resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                switch item.state {
                case .running: ProgressView(value: item.fraction).controlSize(.small)
                case .done: Text(L("Done")).font(.caption).foregroundStyle(.secondary)
                case let .failed(reason): Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { Downloads.shared.cancel(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            } else if item.state == .done, let file = item.file {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "magnifyingglass.circle.fill") }
                    .buttonStyle(.borderless).help(L("Show in Finder"))
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.state == .done, let file = item.file { NSWorkspace.shared.open(file) }
        }
    }
}
