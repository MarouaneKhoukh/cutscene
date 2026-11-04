import AppKit
import CutsceneCapture
import CutsceneCore
import Foundation
import Observation
import SwiftUI

/// The numbers the recovery window is tuned with.
struct RecoveryFlowSettings: Sendable, Equatable {
    /// Fixed content size in points (PLAN M1-F6): the window never sizes
    /// itself from its rows, which scroll; the height shows three packages
    /// with their status lines.
    var windowWidth = 560.0
    var windowHeight = 480.0
    /// Bytes per megabyte as the rows quote sizes, in the decimal form the
    /// Finder uses.
    var bytesPerMegabyte = 1_000_000.0
    var scanner = RecoveryScannerSettings()
}

/// At launch, offers "Finish recording" / "Discard" for every package a
/// killed process left behind (PLAN M1-13, ARCHITECTURE §2 "Failure
/// handling"): `RecoveryScanner` finds them, finishing runs its recovery and
/// then the recorder's own renderer (`AutoRender`), so a crashed take ends
/// as a normal one does, with its export reachable from the menu's Open
/// Last Export; discarding moves the package to the Trash. Closing the
/// window leaves the rest for the next launch.
///
/// An AppKit window, as onboarding is: a menu-bar agent has no window to
/// hand `openWindow` to. A take left waiting while a new one records is
/// finished only once the recorder is idle, since the export would compete
/// with the take for the encoder, and the model refuses a new take while a
/// package here is being finished or rendered, for the same reason.
@MainActor @Observable final class RecoveryFlow {
    /// Where one package stands in the window.
    enum Phase: Equatable {
        case waiting
        /// The movie is being finalized and the log rebuilt.
        case finishing
        /// The recovered package is being exported; nil until the first report.
        case rendering(progress: Double?)
        /// Recovery is done; `export` is the movie when one was rendered.
        case finished(export: URL?, summary: String)
        /// Recovery succeeded, so the package is a complete recording, but
        /// its render did not; Render Again retries the render alone, and
        /// Discard is not offered.
        case renderFailed(summary: String, error: String)
        /// The recovery itself failed (`RecoveryError.finalizeFailed`) or the
        /// discard did; the package is as the crash left it.
        case failed(String)
        case discarded(URL?)
    }

    struct Item: Identifiable {
        let candidate: RecoveryCandidate
        var phase = Phase.waiting
        /// Set once recovery succeeded, so a render retry needs no second one.
        var result: RecoveryResult?

        var id: URL { candidate.id }
    }

    let settings: RecoveryFlowSettings
    private(set) var items: [Item] = []
    private(set) var unreadable: [UnreadablePackage] = []
    /// Packages another process is recording into, listed and left alone.
    private(set) var inUse: [UnreadablePackage] = []
    private unowned let model: AppModel
    private var window: NSWindow?
    private var tasks: [URL: Task<Void, Never>] = [:]

    init(model: AppModel, settings: RecoveryFlowSettings = RecoveryFlowSettings()) {
        self.model = model
        self.settings = settings
    }

    /// Whether the window is on screen.
    var isVisible: Bool { window?.isVisible == true }

    /// Whether a package is being finished or rendered right now.
    var isBusy: Bool {
        items.contains { item in
            switch item.phase {
            case .finishing, .rendering: true
            case .waiting, .finished, .renderFailed, .failed, .discarded: false
            }
        }
    }

    /// Scans the recordings folders (the user's and the default one, in case
    /// the setting changed since the crash) and shows the window when a
    /// take is waiting. The scan reads one JSON file per package, off the
    /// main actor.
    func checkAtLaunch() {
        var scanner = settings.scanner
        var directories = [model.defaults.recordingsDirectory] + scanner.directories
        directories = directories.reduce(into: []) { unique, url in
            if !unique.contains(url) { unique.append(url) }
        }
        scanner.directories = directories
        Task { [scanner] in
            let result = await Self.scan(scanner)
            inUse = result.inUse
            // A package some other process is recording is no reason to
            // open the window; it is listed when the window opens anyway.
            guard !result.candidates.isEmpty || !result.unreadable.isEmpty else { return }
            items = result.candidates.map { Item(candidate: $0) }
            unreadable = result.unreadable
            show()
        }
    }

    /// Finishes the package: recovery, then the renderer when there is one
    /// and the recovery left a playable movie. For a package already
    /// recovered (a render that failed) only the render runs again.
    func finish(_ id: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }), canFinish(items[index]) else { return }
        let candidate = items[index].candidate
        let recovered = items[index].result
        let renderer = model.recorder.renderer
        let scanner = settings.scanner
        items[index].phase = recovered == nil ? .finishing : .rendering(progress: nil)
        tasks[id] = Task { [weak self] in
            defer { self?.tasks[id] = nil }
            let result: RecoveryResult
            if let recovered {
                result = recovered
            } else {
                do {
                    result = try await RecoveryScanner.recover(candidate, settings: scanner)
                } catch {
                    self?.set(id, .failed(error.localizedDescription))
                    return
                }
                guard let self else { return }
                setResult(id, result)
                // A package with video is a recording worth remembering; one
                // without is not the last take.
                if result.playableSeconds > 0 {
                    model.defaults.remember(package: candidate.package.url)
                }
            }
            guard let self else { return }
            guard result.playableSeconds > 0, let renderer else {
                set(id, .finished(export: nil, summary: Self.summary(of: result, export: nil)))
                return
            }
            set(id, .rendering(progress: nil))
            do {
                let export = try await renderer.render(package: candidate.package, manifest: result.manifest) {
                    progress in
                    Task { @MainActor [weak self] in self?.reportProgress(progress, for: id) }
                }
                model.defaults.lastExportURL = export
                set(id, .finished(export: export, summary: Self.summary(of: result, export: export)))
            } catch {
                set(
                    id, .renderFailed(summary: Self.summary(of: result, export: nil), error: error.localizedDescription)
                )
            }
        }
    }

    /// For Quit: a render in flight is cancelled (the package is complete
    /// and the menu's Render Last Recording redoes it) and every finish is
    /// waited for, so no package is left half-finalized.
    func settleForQuit() async {
        let rendering = items.contains { item in
            if case .rendering = item.phase { return true }
            return false
        }
        if rendering {
            await model.recorder.renderer?.cancel()
        }
        for task in Array(tasks.values) {
            await task.value
        }
    }

    /// Moves the package to the Trash.
    func discard(_ id: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }), canDiscard(items[index]) else { return }
        do {
            let trashed = try RecoveryScanner.discard(items[index].candidate, settings: settings.scanner)
            items[index].phase = .discarded(trashed)
        } catch {
            items[index].phase = .failed(error.localizedDescription)
        }
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Whether Finish (or Render Again) applies: the package is waiting, a
    /// try failed, or its render did, and the recorder is not busy with a
    /// take or its render.
    func canFinish(_ item: Item) -> Bool {
        switch item.phase {
        case .waiting, .failed, .renderFailed: !model.recorder.isBusy
        case .finishing, .rendering, .finished, .discarded: false
        }
    }

    /// Whether Discard applies: only to a package the crash left as it is,
    /// never to one recovery has already turned into a complete recording.
    func canDiscard(_ item: Item) -> Bool {
        switch item.phase {
        case .waiting, .failed: true
        case .finishing, .rendering, .finished, .renderFailed, .discarded: false
        }
    }

    func show() {
        let window = window ?? makeWindow()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14: at launch the app has
        // it, and when it does not the window still comes forward.
        NSApp.activate()
        if !NSApp.isActive {
            window.orderFrontRegardless()
        }
    }

    func close() {
        window?.close()
    }

    // MARK: Private

    /// The scan, on the global executor: the call is nonisolated, so a
    /// launch with a folder of packages does not stall the menu.
    private nonisolated static func scan(_ settings: RecoveryScannerSettings) async -> RecoveryScanResult {
        RecoveryScanner.scan(settings: settings)
    }

    private func set(_ id: URL, _ phase: Phase) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].phase = phase
    }

    private func setResult(_ id: URL, _ result: RecoveryResult) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].result = result
    }

    private func reportProgress(_ progress: Double, for id: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .rendering = items[index].phase else {
            return
        }
        items[index].phase = .rendering(progress: progress)
    }

    /// One line for the row once the package is finished.
    private static func summary(of result: RecoveryResult, export: URL?) -> String {
        guard result.playableSeconds > 0 else {
            return "No video was written before the process ended; the package keeps what was saved."
        }
        let seconds = Duration.seconds(result.playableSeconds).formatted(.time(pattern: .minuteSecond))
        var parts = ["\(seconds) of video finished"]
        parts.append(result.logRecovered ? "\(result.eventCount) events recovered" : "no telemetry reached the disk")
        if let export {
            parts.append("exported as \(export.lastPathComponent)")
        }
        return parts.joined(separator: " · ")
    }

    /// A fixed-size window whose content is an `NSHostingView` with no
    /// sizing options, not an `NSHostingController`: the controller's
    /// `preferredContentSize` re-measured the graph inside AppKit's
    /// update-constraints pass, and a row changing height there tripped the
    /// loop detector (PLAN M1-F6; see `OnboardingWindow`).
    private func makeWindow() -> NSWindow {
        let size = NSSize(width: settings.windowWidth, height: settings.windowHeight)
        let hosting = NSHostingView(rootView: RecoveryView(flow: self))
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.contentView = hosting
        window.title = "Finish Recording"
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        return window
    }
}

/// The rows: one per package, with what is on disk and what to do with it,
/// scrolling inside the fixed frame so a folder of crashed takes never asks
/// the window for more height.
///
/// Every text that may wrap carries `fixedSize(horizontal: false, vertical:
/// true)`: without it, under the SwiftUI `App` lifecycle beside the
/// menu-bar scene, the hosting view's minimum-size and preferred-size
/// passes wrapped the paragraph differently, the window chased the two
/// heights and AppKit's update-constraints loop detector threw at launch
/// (observed 2026-11-03 with the onboarding window open alongside).
struct RecoveryView: View {
    let flow: RecoveryFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recordings left unfinished").font(.title.bold())
                    Text(
                        """
                        Cutscene stopped before these recordings were finished. Finishing writes the movie from \
                        what reached the disk and renders it like a normal take; discarding moves the package \
                        to the Trash.
                        """
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(flow.items) { item in
                            RecoveryRow(item: item, flow: flow)
                            if item.id != flow.items.last?.id { Divider() }
                        }
                        if flow.items.isEmpty {
                            Text("Nothing left to finish.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

                    ForEach(flow.unreadable, id: \.self) { package in
                        Label {
                            Text("\(package.url.lastPathComponent): \(package.detail)")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
                    }
                    ForEach(flow.inUse, id: \.self) { package in
                        Label {
                            Text("\(package.url.lastPathComponent) \(package.detail)")
                                .font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "record.circle")
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { flow.close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: flow.settings.windowWidth, height: flow.settings.windowHeight)
    }
}

private struct RecoveryRow: View {
    let item: RecoveryFlow.Item
    let flow: RecoveryFlow

    private var candidate: RecoveryCandidate { item.candidate }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .foregroundStyle(symbolColor)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.package.url.deletingPathExtension().lastPathComponent).font(.headline)
                Text(onDisk).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                status
            }
            Spacer()
            actions
        }
    }

    @ViewBuilder private var status: some View {
        switch item.phase {
        case .waiting:
            EmptyView()
        case .finishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Finishing the movie…").font(.caption).foregroundStyle(.tertiary)
            }
        case .rendering(let progress):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: progress ?? 0).controlSize(.small)
                Text(progress.map { "Rendering… \(Int(($0 * 100).rounded())) %" } ?? "Rendering…")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        case .finished(_, let summary):
            Text(summary).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        case .renderFailed(let summary, let error):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Export failed: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .discarded(let trashed):
            Text(trashed == nil ? "Deleted" : "Moved to the Trash").font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var actions: some View {
        switch item.phase {
        case .waiting, .failed:
            Button("Finish Recording") { flow.finish(item.id) }
                .disabled(!flow.canFinish(item))
            Button("Discard") { flow.discard(item.id) }
        case .renderFailed:
            Button("Render Again") { flow.finish(item.id) }
                .disabled(!flow.canFinish(item))
            Button("Reveal") { flow.reveal(candidate.package.url) }
        case .finishing, .rendering:
            EmptyView()
        case .finished(let export, _):
            if let export {
                Button("Open") { flow.open(export) }
                Button("Reveal") { flow.reveal(export) }
            } else {
                Button("Reveal") { flow.reveal(candidate.package.url) }
            }
        case .discarded:
            EmptyView()
        }
    }

    /// What the crash left: when the take started and which files survived.
    private var onDisk: String {
        let started = candidate.manifest.createdAt.formatted(date: .abbreviated, time: .shortened)
        var parts = ["Started \(started)"]
        if candidate.fragmentedMovieBytes > 0 {
            let megabytes = Double(candidate.fragmentedMovieBytes) / flow.settings.bytesPerMegabyte
            parts.append("\(String(format: "%.1f", megabytes)) MB of video to finish")
        } else if candidate.hasFinalizedMovie {
            parts.append("movie finalized")
        } else {
            parts.append("no video was written")
        }
        if candidate.hasEventLogHeader {
            parts.append(candidate.eventsSidecarBytes > 0 ? "telemetry to recover" : "telemetry saved")
        } else {
            parts.append("no telemetry saved")
        }
        return parts.joined(separator: " · ")
    }

    private var symbolName: String {
        switch item.phase {
        case .waiting: "exclamationmark.triangle"
        case .finishing, .rendering: "gearshape"
        case .finished: "checkmark.circle.fill"
        case .renderFailed: "exclamationmark.circle"
        case .failed: "xmark.circle"
        case .discarded: "trash"
        }
    }

    private var symbolColor: Color {
        switch item.phase {
        case .waiting, .renderFailed: .orange
        case .finishing, .rendering: .secondary
        case .finished: .green
        case .failed: .red
        case .discarded: .secondary
        }
    }
}
