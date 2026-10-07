import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Wire models deliberately mirror the Rust JSON field names.
// swift-format-ignore: AlwaysUseLowerCamelCase
struct MediaInfo: Codable, Equatable {
  var width: Int = 0, height: Int = 0
  var duration: Double = 0
  var codec = "", audio = false, frames = 0, sample_rate = 0, channels = 0, colour = "", title = "",
    artist = ""
}
struct MediaItem: Codable, Identifiable, Equatable {
  var id: Int, path: String, root: String, name: String, kind: String, size: UInt64,
    modified: Double
  var info: MediaInfo, thumbnail: String?, waveform: [Float], error: String?, group: String?,
    copies: Int
  var location: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
  var relativeLocation: String {
    let path = location.replacingOccurrences(of: root, with: "")
    return path.isEmpty ? URL(fileURLWithPath: root).lastPathComponent : String(path.dropFirst())
  }
  var symbol: String {
    switch kind {
    case "image": "photo"
    case "video": "play.rectangle"
    case "audio": "waveform"
    default: "doc.questionmark"
    }
  }
  var detail: String {
    if kind == "other" { return "Unsupported format · original available" }
    if let error { return error.contains("No such") ? "File missing" : "Preview unavailable" }
    if kind == "audio" {
      return info.duration > 0
        ? timeText(info.duration) + " · " + (info.codec.isEmpty ? "Audio" : info.codec.uppercased())
        : "Audio"
    }
    let dimensions = info.width > 0 ? "\(info.width) × \(info.height)" : kind.capitalized
    return kind == "video" && info.duration > 0
      ? timeText(info.duration) + " · " + dimensions : dimensions
  }
}
struct ExportReport: Codable {
  var running = false, total = 0, completed = 0, copied = 0, converted = 0, skipped = 0, failed = 0,
    cancelled = false
  var stage = "", current = "", destination = "", errors: [String] = [], outputs: [String] = []
}
struct PreviewState: Codable {
  var id: Int
  var status: String
  var path: String?
  var error: String?
  var item: MediaItem
}
// swift-format-ignore: AlwaysUseLowerCamelCase
struct Preferences: Codable {
  var theme = "system"
  var thumbnail_size: Double = 196
}
// swift-format-ignore: AlwaysUseLowerCamelCase
struct Snapshot: Decodable {
  var revision: Int, view_revision: Int, items: [MediaItem]?, updates: [MediaItem], roots: [String],
    total: Int, matching: Int, selected: [Int], hidden_selected: Int, scanning: Bool,
    issues: [String], duplicate_status: String, duplicate_progress: Double, report: ExportReport,
    preview: PreviewState?, preferences: Preferences, first_preview_ms: Int?, elapsed_ms: Int,
    counts: [Int]
}
// swift-format-ignore: AlwaysUseLowerCamelCase
struct ExportSettings: Codable, Equatable {
  var originals = true, all_matching = false, destination = "", deduplicate = false,
    preserve_paths = false, prefix = "Liltfold", sequence = false, conflict = "unique"
  var image = "webp", video = "mp4", audio = "original", image_quality = 88, max_dimension = 0,
    transparency = "preserve", metadata = false
  var video_bitrate = 8000, video_crf = 25, video_height = 0, frame_rate = 0, retain_audio = true
  var audio_bitrate = 256, sample_rate = 0, channels = 0
  var json: [String: Any] {
    (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
  }
}

func timeText(_ seconds: Double) -> String {
  guard seconds.isFinite else { return "—" }
  let n = max(0, Int(seconds))
  return n >= 3600
    ? String(format: "%d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60)
    : String(format: "%d:%02d", n / 60, n % 60)
}
func sizeText(_ bytes: UInt64) -> String {
  ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

@MainActor
final class LibraryModel: ObservableObject {
  @Published var items: [MediaItem] = []
  @Published var selected: Set<Int> = []
  @Published var roots: [String] = []
  @Published var total = 0
  @Published var matching = 0
  @Published var hiddenSelected = 0
  @Published var counts = [0, 0, 0, 0]
  @Published var scanning = false
  @Published var issues: [String] = []
  @Published var duplicateStatus = "Add a folder to begin"
  @Published var duplicateProgress = 0.0
  @Published var report = ExportReport()
  @Published var preview: PreviewState?
  @Published var preferences = Preferences()
  @Published var filter = "all"
  @Published var query = ""
  @Published var sort = "name"
  @Published var duplicates = "all"
  @Published var error: String?
  @Published var exportVisible = false
  @Published var exportSettings = ExportSettings()
  @Published var showingReport = false
  @Published var showIssues = false
  var revision = 0, viewRevision = 0, gridRevision = 0
  var firstPreviewMS: Int?
  var pollTimer: Timer?
  var lookup: [Int: Int] = [:]

  init() {
    let cache =
      ProcessInfo.processInfo.environment["LILTFOLD_CACHE"]
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("com.hybes.liltfold").path
    let tools = Bundle.main.resourceURL!.appendingPathComponent("bin").path
    cache.withCString { cache in tools.withCString { tools in lilt_init(cache, tools, nativeImage) }
    }
    poll()
    pollTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    RunLoop.main.add(pollTimer!, forMode: .common)
  }
  @discardableResult func send(
    _ action: String, _ values: [String: Any] = [:], displayError: Bool = true
  ) -> [String: Any] {
    var object = values
    object["action"] = action
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let input = String(data: data, encoding: .utf8)
    else { return [:] }
    let result: Data = input.withCString { pointer in
      guard let output = lilt_command(pointer) else { return Data() }
      defer { lilt_free(output) }
      return Data(String(cString: output).utf8)
    }
    let dictionary = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any] ?? [:]
    if displayError, let message = dictionary["error"] as? String { error = message }
    return dictionary
  }
  func poll() {
    let raw = send(
      "poll", ["revision": revision, "view_revision": viewRevision], displayError: false)
    guard raw["unchanged"] == nil, let data = try? JSONSerialization.data(withJSONObject: raw),
      let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
    else { return }
    revision = snapshot.revision
    viewRevision = snapshot.view_revision
    if let entries = snapshot.items {
      items = entries
      lookup = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
      gridRevision += 1
    }
    if !snapshot.updates.isEmpty {
      for item in snapshot.updates { if let index = lookup[item.id] { items[index] = item } }
      gridRevision += 1
    }
    let selection = Set(snapshot.selected)
    if selection != selected { selected = selection }
    roots = snapshot.roots
    total = snapshot.total
    matching = snapshot.matching
    hiddenSelected = snapshot.hidden_selected
    scanning = snapshot.scanning
    counts = snapshot.counts
    issues = snapshot.issues
    duplicateStatus = snapshot.duplicate_status
    duplicateProgress = snapshot.duplicate_progress
    report = snapshot.report
    preview = snapshot.preview
    firstPreviewMS = snapshot.first_preview_ms
    preferences = snapshot.preferences
    NSApp.appearance =
      preferences.theme == "system"
      ? nil : NSAppearance(named: preferences.theme == "dark" ? .darkAqua : .aqua)
  }
  func changeView() {
    send(
      "view", ["view": ["filter": filter, "query": query, "sort": sort, "duplicates": duplicates]])
    poll()
  }
  func setSelection(_ ids: Set<Int>) {
    selected = ids
    send("selection", ["ids": Array(ids)])
    poll()
  }
  func addFolders() {
    let panel = NSOpenPanel()
    panel.title = "Add folders to Liltfold"
    panel.prompt = "Add folders"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK { add(panel.urls.map(\.path)) }
  }
  func add(_ paths: [String]) {
    send("add_roots", ["paths": paths])
    poll()
  }
  func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
    for provider in providers {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL? =
          if let data = item as? Data { URL(dataRepresentation: data, relativeTo: nil) } else {
            item as? URL
          }
        if let url { Task { @MainActor in self.add([url.path]) } }
      }
    }
    return true
  }
  func openPreview(_ id: Int) {
    send("preview", ["id": id])
    poll()
  }
  func closePreview() {
    send("close_preview")
    poll()
  }
  func nextPreview(_ direction: Int) {
    guard let id = preview?.id, let index = items.firstIndex(where: { $0.id == id }),
      items.indices.contains(index + direction)
    else { return }
    openPreview(items[index + direction].id)
  }
  func startExport(originals: Bool) {
    exportSettings.originals = originals
    showingReport = false
    exportVisible = true
  }
  func savePreferences() {
    send(
      "preferences",
      ["preferences": ["theme": preferences.theme, "thumbnail_size": preferences.thumbnail_size]])
  }
}

enum Palette {
  static var secondaryNS: NSColor {
    NSColor(name: nil) {
      $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.67, green: 0.69, blue: 0.64, alpha: 1)
        : NSColor(srgbRed: 0.38, green: 0.39, blue: 0.37, alpha: 1)
    }
  }
  static var secondary: Color { Color(nsColor: secondaryNS) }
  static var background: Color {
    Color(
      nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.137, green: 0.145, blue: 0.129, alpha: 1)
          : NSColor(srgbRed: 0.965, green: 0.953, blue: 0.922, alpha: 1)
      })
  }
  static var ink: Color { Color(nsColor: .labelColor) }
  static var amber: Color {
    Color(
      nsColor: NSColor(name: nil) {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
          ? NSColor(srgbRed: 0.93, green: 0.70, blue: 0.36, alpha: 1)
          : NSColor(srgbRed: 0.55, green: 0.34, blue: 0.03, alpha: 1)
      })
  }
  static var line: Color { Color.primary.opacity(0.11) }
}

struct BrandMark: View {
  var size: CGFloat = 32
  private static let artwork = NSImage(
    contentsOf: Bundle.main.url(forResource: "LiltfoldLogo", withExtension: "png")!)!
  var body: some View {
    Image(nsImage: Self.artwork)
      .resizable().interpolation(.high).scaledToFit()
      .frame(width: size, height: size).accessibilityHidden(true)
  }
}
