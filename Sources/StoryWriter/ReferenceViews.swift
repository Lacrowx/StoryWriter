import SwiftUI
import QuickLookUI
import WebKit
import UniformTypeIdentifiers

struct ReferencesView: View {
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Environment(\.storyDestination) private var destination
    @Environment(\.pinResearch) private var pin
    @Environment(\.reviewFocus) private var reviewFocus
    @State private var selection: UUID?
    @State private var search = ""
    @State private var showLinkSheet = false
    @State private var deleteID: UUID?
    @State private var isTargeted = false
    var body: some View {
        if let project = store.project(projectID) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        WriterSearchField(title: "Find a reference", text: $search)
                        Menu {
                            Button("Add files…") { Panels.importSources(projectID, store: store) }
                            Button("Add web link…") { showLinkSheet = true }
                            Button("Add a note") { let note = ReferenceSource(title: "New research note"); store.update(projectID) { $0.sources.append(note) }; selection = note.id }
                        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).tint(.primary).frame(width: 20)
                    }.padding(16)
                    List(selection: $selection) {
                        ForEach(project.sources.filter { search.isEmpty || [$0.title, $0.notes, $0.tags, $0.webURL ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search) }) { source in
                            HStack(alignment: .top, spacing: 11) {
                                WriterSymbol(name: source.symbol)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                                    Text(source.webURL != nil ? (source.snapshotPath != nil ? "Web link · saved copy" : "Web link") : (source.fileExtension.isEmpty ? "Research note" : source.fileExtension.uppercased())).font(.caption).foregroundStyle(.secondary)
                                    if !source.tags.isEmpty { Text(source.tags).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
                                }
                            }.padding(.vertical, 9).tag(source.id).contextMenu { Button("Pin beside manuscript") { pin(.source(source.id)) }; Button("Remove reference…", role: .destructive) { deleteID = source.id }; Divider(); AppContextMenuItems() }
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden)
                    HStack { Button { Panels.importSources(projectID, store: store) } label: { Label("Add files", systemImage: "plus") }; Spacer(); Button { showLinkSheet = true } label: { Image(systemName: "link") }.help("Add web link") }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(18)
                }.frame(width: 235).background(DesktopMaterial())
                Divider()
                if let source = project.sources.first(where: { $0.id == selection }) {
                    ReferenceDetails(projectID: projectID, source: store.itemBinding(projectID, \.sources, id: source.id, fallback: source)).environment(\.grammarNamespace, source.id.uuidString).id(source.id)
                } else {
                    EmptyWorkspace(symbol: "tray.full", title: "Keep your inspiration close", subtitle: "Add images, PDFs, documents, audio, or video.\nSave web links and notes alongside them.\nYou can also drop files here.", action: "Add reference files") { Panels.importSources(projectID, store: store) }
                }
            }
            .overlay { if isTargeted { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4).allowsHitTesting(false) } }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                store.importFiles(files, projectID: projectID)
                if selection == nil { selection = store.project(projectID)?.sources.last?.id }
                return !files.isEmpty
            } isTargeted: { isTargeted = $0 }
            .onAppear { selection = destination?.kind == .reference ? destination?.itemID : project.sources.first?.id }
            .onChange(of: selection) { _, _ in reviewFocus?.activate(nil) }
            .onChange(of: destination) { _, target in if target?.kind == .reference { selection = target?.itemID } }
            .onChange(of: project.sources.map(\.id)) { old, ids in if let new = ids.last, !old.contains(new) { selection = new } }
            .sheet(isPresented: $showLinkSheet) { AddLinkSheet(projectID: projectID) }
            .confirmationDialog("Remove this reference from the project?", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) { Button("Remove reference", role: .destructive) { if let deleteID { store.update(projectID) { $0.sources.removeAll { $0.id == deleteID } }; if selection == deleteID { selection = store.project(projectID)?.sources.first?.id } }; deleteID = nil } } message: { Text("Its imported file is retained so saved revisions can still recover it.") }
        }
    }
}

struct ReferenceDetails: View {
    @Environment(\.pinResearch) private var pin
    @EnvironmentObject private var store: ProjectStore
    var projectID: UUID
    @Binding var source: ReferenceSource
    @State private var savedCopy = true
    @State private var showNotes = true
    @StateObject private var web = WebReferenceController()
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: source.symbol).foregroundStyle(Color.accentColor)
                WritingTextArea(text: $source.title, height: 30, label: "reference title", fontSize: 17, compact: true, chrome: true)
                Spacer()
                if source.webURL != nil {
                    if source.snapshotPath != nil { Toggle("Saved copy", isOn: $savedCopy).toggleStyle(.switch).controlSize(.small) }
                    Button(web.isSaving ? "Saving…" : "Save page offline") {
                        web.archive { result in
                            switch result {
                            case .success(let data): store.saveWebArchive(data, sourceID: source.id, projectID: projectID); savedCopy = true
                            case .failure(let error): store.errorMessage = error.localizedDescription
                            }
                        }
                    }.disabled(web.isSaving || web.isLoading || (savedCopy && source.snapshotPath != nil)).help("Saves the loaded page and its available resources")
                }
                Button { pin(.source(source.id)) } label: { Image(systemName: "pin") }.buttonStyle(WriterIconButtonStyle()).help("Pin beside manuscript").accessibilityLabel("Pin beside manuscript")
                Button { showNotes.toggle() } label: { Image(systemName: "note.text") }.buttonStyle(WriterIconButtonStyle()).help("Show reference notes").accessibilityLabel("Show reference notes")
                Menu {
                    if let link = source.webURL, let url = URL(string: link) { Button("Open in browser") { NSWorkspace.shared.open(url) } }
                    if let file = store.mediaURL(source, projectID: projectID) {
                        Button("Open in default app") { NSWorkspace.shared.open(file) }
                        Button("Show imported file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }
                } label: { Image(systemName: "arrow.up.forward.app") }.menuStyle(.borderlessButton).tint(.primary).frame(width: 24)
            }.padding(.horizontal, 24).padding(.vertical, 18)
            if let link = source.webURL { Text(link).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).padding(.horizontal, 24).padding(.bottom, 12) }
            Divider()
            if let link = source.webURL, let url = URL(string: link) {
                WebReferenceView(url: url, archiveURL: savedCopy ? store.mediaURL(source, projectID: projectID, snapshot: true) : nil, controller: web)
                if let error = web.message { Text(error).font(.caption).foregroundStyle(.secondary).padding(10) }
            } else if let file = store.mediaURL(source, projectID: projectID) {
                if FileManager.default.fileExists(atPath: file.path) { FilePreview(url: file).frame(maxWidth: .infinity, maxHeight: .infinity).padding(12) }
                else { Text("This reference file is missing from the project. Import it again to restore its preview.").foregroundStyle(.secondary).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity) }
            } else if !showNotes { Text("Open the notes panel to write in this research note.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
            if showNotes {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("YOUR NOTES").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary); Spacer(); TextField("Tags, separated by commas", text: $source.tags).textFieldStyle(.roundedBorder).frame(maxWidth: 280) }
                    WritingTextArea(text: $source.notes, height: source.relativePath == nil && source.webURL == nil ? 300 : 100, label: "reference note").frame(maxHeight: source.relativePath == nil && source.webURL == nil ? .infinity : 150)
                }.cardSurface().padding(16)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FilePreview: NSViewRepresentable {
    var url: URL
    func makeNSView(context: Context) -> NSView {
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else { return NSView() }
        preview.autostarts = false; preview.previewItem = url as NSURL
        return preview
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? QLPreviewView)?.previewItem = url as NSURL }
}

@MainActor
final class WebReferenceController: NSObject, ObservableObject, WKNavigationDelegate {
    weak var view: WKWebView?
    @Published var isLoading = false
    @Published var isSaving = false
    @Published var message: String?
    func archive(completion: @escaping (Result<Data, Error>) -> Void) {
        guard let view else { completion(.failure(ProjectError.invalid("Open the web page before saving it."))); return }
        isSaving = true
        view.createWebArchiveData { [weak self] result in self?.isSaving = false; completion(result) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { isLoading = true; message = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false; message = "Could not load the page. \(error.localizedDescription)" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false; message = error.localizedDescription }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["http", "https", "file", "about", "data"].contains(url.scheme ?? "") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}

struct WebReferenceView: NSViewRepresentable {
    var url: URL
    var archiveURL: URL?
    @ObservedObject var controller: WebReferenceController
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = controller; view.allowsBackForwardNavigationGestures = true; controller.view = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let target = archiveURL ?? url
        guard target != context.coordinator.loaded else { return }
        context.coordinator.loaded = target
        if target.isFileURL { view.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent()) }
        else { view.load(URLRequest(url: target)) }
    }
    class Coordinator { var loaded: URL? }
}

struct AddLinkSheet: View {
    var projectID: UUID
    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Save a web reference", systemImage: "link").font(.system(size: 23, weight: .semibold))
            Text("View the page inside StoryWriter. Use “Save page offline” after it loads to keep a local copy.").foregroundStyle(.secondary)
            LabeledField("Web address", text: $url, placeholder: "https://…")
            LabeledField("Title (optional)", text: $title)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Add link") { do { try store.addLink(url, title: title, projectID: projectID); dismiss() } catch { self.error = error.localizedDescription } }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(30).frame(width: 470).writerSheet()
    }
}
