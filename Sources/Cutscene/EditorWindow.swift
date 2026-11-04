import AppKit
import CutsceneCore
import SwiftUI

/// Flips the activation policy while an editor window is open (ARCHITECTURE
/// §1): a menu-bar agent (`LSUIElement`) has no Dock icon and no main menu,
/// and an editor needs both, for Edit ▸ Undo and for the window to be found
/// again. The first editor to open makes the app regular, the last to close
/// makes it an accessory again. It also keeps the open editors' models, so
/// an orderly quit (`AppDelegate`) can save them: `terminate` closes no
/// window, so `onDisappear` never runs for them.
///
/// AppKit redraws the menu bar for a policy change only on the next
/// activation change, so a flip made while we are frontmost is not shown
/// until the user switches applications: the open activates on the next
/// run-loop turn, after the policy took, and the close yields activation
/// back to the application that was frontmost before the first editor
/// opened, so the menu bar stops showing a menu of an accessory.
@MainActor final class EditorActivation {
    static let shared = EditorActivation()

    private(set) var openWindows = 0
    private var models: [ObjectIdentifier: EditorModel] = [:]
    /// The application that was frontmost when the first editor opened;
    /// activation goes back to it when the last one closes.
    private var previousApplication: NSRunningApplication?

    func windowOpened() {
        openWindows += 1
        if openWindows == 1 {
            let frontmost = NSWorkspace.shared.frontmostApplication
            previousApplication =
                frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
            NSApp.setActivationPolicy(.regular)
            // Activated on a later turn so the activation change follows
            // the policy change and the menu bar is drawn for the new policy.
            DispatchQueue.main.async { NSApp.activate() }
        } else {
            NSApp.activate()
        }
    }

    func windowClosed() {
        openWindows = max(openWindows - 1, 0)
        if openWindows == 0 {
            NSApp.setActivationPolicy(.accessory)
            if let previous = previousApplication, !previous.isTerminated {
                NSApp.yieldActivation(to: previous)
                previous.activate()
            }
            previousApplication = nil
        }
    }

    /// The editors whose models are loaded, for the quit path.
    var openModels: [EditorModel] { Array(models.values) }

    func register(_ model: EditorModel) {
        models[ObjectIdentifier(model)] = model
    }

    func unregister(_ model: EditorModel) {
        models[ObjectIdentifier(model)] = nil
    }

    /// Writes every open editor's pending save and drops its export in
    /// flight, for a quit that closes no window.
    func closeAllForQuit() {
        for model in models.values {
            model.close()
        }
        models = [:]
    }
}

/// The editor scene's content for one package URL (PLAN M2-10): loads the
/// package off the main actor, then shows the preview over the transport
/// bar and the scrubber, with the Style and Zoom inspectors beside them
/// and the export sheet from the toolbar. Fixed size (PLAN M1-F6): the
/// window never sizes itself from its content.
struct EditorWindow: View {
    /// The scene's value: nil for the window SwiftUI presents by itself on
    /// an open-file event, which `onOpenURL` then fills.
    @Binding var url: URL?
    let appModel: AppModel
    let settings = EditorSettings()

    @State private var model: EditorModel?
    @State private var loadError: String?
    @State private var opened = false
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model)
            } else if let loadError {
                ContentUnavailableView(
                    "This recording cannot be opened", systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else if url == nil {
                ContentUnavailableView(
                    "No recording", systemImage: "film",
                    description: Text("Open a recording from the menu bar's Open Last Recording."))
            } else {
                ProgressView("Opening…")
            }
        }
        .frame(width: settings.windowWidth, height: settings.windowHeight)
        .navigationTitle(url.map { $0.deletingPathExtension().lastPathComponent } ?? "Editor")
        .task(id: url) { await load() }
        // A `.cutscene` package opened from the Finder (the bundle declares
        // the type): SwiftUI presents this group's window with no value and
        // delivers the file here, so an empty window takes the package and
        // one already editing another opens a second window for it.
        .onOpenURL { opened in
            if url == nil || url == opened {
                url = opened
            } else {
                openWindow(id: AppModel.editorWindowID, value: opened)
            }
        }
        .onChange(of: undoManager, initial: true) { _, manager in
            if let manager { model?.undoManager = manager }
        }
        .onAppear {
            guard !opened else { return }
            opened = true
            EditorActivation.shared.windowOpened()
        }
        .onDisappear {
            release()
            guard opened else { return }
            opened = false
            EditorActivation.shared.windowClosed()
        }
    }

    private func load() async {
        release()
        loadError = nil
        guard let url else { return }
        let appModel = appModel
        do {
            let loaded = try await EditorModel.load(url: url, settings: settings) { appModel.defaults.exportsDirectory }
            // The window closed (or the URL changed) while the package was
            // being read: the model's player and rebuild must not outlive it.
            guard !Task.isCancelled else {
                loaded.close()
                return
            }
            if let manager = undoManager { loaded.undoManager = manager }
            model = loaded
            EditorActivation.shared.register(loaded)
        } catch {
            if !Task.isCancelled { loadError = error.localizedDescription }
        }
    }

    private func release() {
        if let model {
            EditorActivation.shared.unregister(model)
            model.close()
        }
        model = nil
    }
}

/// Which inspector the column shows.
private enum InspectorTab: String, CaseIterable, Identifiable {
    case style = "Style"
    case zoom = "Zoom"

    var id: String { rawValue }
}

/// The editor once its package is loaded.
private struct EditorContent: View {
    let model: EditorModel
    @State private var tab = InspectorTab.style
    @State private var showsExport = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewView(player: model.preview.player)
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                TransportBar(model: model)
                    .frame(height: model.settings.transportHeight)
                Divider()
                Scrubber(model: model)
                    .frame(height: model.settings.scrubberHeight)
                statusLine
            }
            Divider()
            VStack(spacing: 0) {
                Picker("Inspector", selection: $tab) {
                    ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)
                Divider()
                ScrollView {
                    switch tab {
                    case .style: StyleInspector(model: model)
                    case .zoom: ZoomInspector(model: model)
                    }
                }
            }
            .frame(width: model.settings.inspectorWidth)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsExport = true
                } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .disabled(model.plan == nil)
            }
        }
        .sheet(isPresented: $showsExport) {
            ExportSheet(model: model)
        }
        .onChange(of: model.selectedSegmentID) { _, id in
            if id != nil { tab = .zoom }
        }
    }

    /// One line under the scrubber: where the project came from, whether it
    /// has unsaved or failed work, and the last rebuild error.
    private var statusLine: some View {
        HStack(spacing: 12) {
            Text("Project from \(model.projectSource)")
            if model.isEdited {
                Text(model.saveError.map { "Save failed: \($0)" } ?? "Edited · saves to project.json")
                    .foregroundStyle(model.saveError == nil ? Color.secondary : Color.red)
            }
            if let error = model.rebuildError {
                Text("Preview failed: \(error)").foregroundStyle(.red)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
