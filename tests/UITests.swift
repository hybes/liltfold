import AVKit
import AppKit
import Foundation

/// Compiled only by `tools/build.py --ui-test`. Drives the real views and Rust core in process.
@MainActor enum UITestMetrics {
  static var start = 0.0
  static var firstPaintMS: Double?
  static weak var playback: Playback?
  static func sawPreview() {
    if firstPaintMS == nil { firstPaintMS = (ProcessInfo.processInfo.systemUptime - start) * 1000 }
  }
  static func reset() {
    start = ProcessInfo.processInfo.systemUptime
    firstPaintMS = nil
  }
}
@MainActor enum UITestRunner {
  static var checks: [String] = []
  static var measurements: [[String: Any]] = []
  static func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks.append(label)
    print("PASS UI \(label)")
    fflush(stdout)
  }
  static func until(_ condition: () -> Bool, seconds: Double = 90) async {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      if condition() { return }
      try? await Task.sleep(nanoseconds: 30_000_000)
    }
    fatalError("UI wait timed out")
  }
  static func settle() async { try? await Task.sleep(nanoseconds: 350_000_000) }
  static func descendants(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap(descendants)
  }
  static func rss() -> Int {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Int(
      String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines))! * 1024
  }
  static func capture(_ window: NSWindow, _ name: String, output: URL) async {
    await settle()
    window.displayIfNeeded()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = [
      "-x", "-o", "-l", String(window.windowNumber),
      output.appendingPathComponent(name + ".png").path,
    ]
    try! p.run()
    p.waitUntilExit()
    check(p.terminationStatus == 0, "Captured \(name)")
  }
  static func record(_ name: String, _ model: LibraryModel) {
    let data: [String: Any] = [
      "dataset": name, "files": model.total,
      "first_rendered_thumbnail_ms": UITestMetrics.firstPaintMS ?? -1,
      "first_generated_thumbnail_ms": model.firstPreviewMS ?? -1, "rss_bytes": rss(),
    ]
    measurements.append(data)
    print("MEASURE \(data)")
    fflush(stdout)
  }
  static func run(_ app: AppDelegate) async {
    let model = app.model!
    let window = app.window!
    let output = URL(
      fileURLWithPath: ProcessInfo.processInfo.environment["LILTFOLD_UI_TEST_OUTPUT"]!)
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    model.preferences.theme = "light"
    model.savePreferences()
    model.poll()
    await until { !model.scanning && model.items.count >= 20 && UITestMetrics.firstPaintMS != nil }
    record("mixed-cold-thumbnail-cache", model)
    await until {
      model.items.filter { $0.thumbnail != nil }.count >= 12
        && model.duplicateStatus.hasPrefix("Complete")
    }
    check(model.total == 26, "Nested fixture discovery returns all 26 files")
    check(model.roots.count == 1, "Overlapping roots are normalised")
    let collection = descendants(window.contentView!).compactMap { $0 as? ContactCollection }.first!
    let scroll = collection.enclosingScrollView!
    let root = model.roots[0]
    let first = model.items.first { $0.kind == "image" && $0.error == nil }!
    let video = model.items.first { $0.kind == "video" && $0.path.hasSuffix(".mp4") }!
    let audio = model.items.first { $0.kind == "audio" && $0.path.hasSuffix(".wav") }!
    model.setSelection([first.id, video.id, audio.id])
    await capture(window, "browsing-light", output: output)
    let offset = scroll.contentView.bounds.origin
    if let cell = collection.item(at: IndexPath(item: 0, section: 0))?.view as? TileView {
      check(cell.accessibilityPerformPress(), "Native accessible tile opens its preview")
    } else {
      model.openPreview(first.id)
    }
    await until { model.preview?.status == "ready" }
    await capture(window, "preview-image", output: output)
    if let image = descendants(window.contentView!).compactMap({ $0 as? ImageScroll }).first {
      image.setMagnification(2, centeredAt: NSPoint(x: 200, y: 200))
      check(image.magnification == 2, "Native image magnification works")
    }
    model.closePreview()
    await settle()
    check(
      scroll.contentView.bounds.origin == offset, "Preview close restores exact browsing position")
    model.filter = "video"
    model.changeView()
    await settle()
    check(
      model.items.count == 3 && model.hiddenSelected == 2,
      "Video filter retains hidden image/audio selections")
    model.openPreview(video.id)
    await until { model.preview?.status == "ready" && UITestMetrics.playback?.path == video.path }
    let player = UITestMetrics.playback!
    player.toggle()
    await until { player.position > 0.2 }
    player.seek(2)
    player.volume = 0.3
    player.player.volume = 0.3
    await until { player.position > 2.0 }
    check(
      player.player.currentItem?.status == .readyToPlay, "Video plays and seeks with audio in AVKit"
    )
    await capture(window, "preview-video", output: output)
    player.stop()
    model.closePreview()
    model.filter = "audio"
    model.changeView()
    await until { model.items.allSatisfy { !$0.waveform.isEmpty } }
    model.openPreview(audio.id)
    await until { model.preview?.status == "ready" && UITestMetrics.playback?.path == audio.path }
    let sound = UITestMetrics.playback!
    sound.toggle()
    await until { sound.position > 0.2 }
    sound.seek(3)
    await until { sound.position > 3 }
    check(sound.player.currentItem?.status == .readyToPlay, "Audio plays and seeks with a waveform")
    await capture(window, "preview-audio", output: output)
    sound.stop()
    model.closePreview()
    model.filter = "all"
    model.duplicates = "only"
    model.changeView()
    await settle()
    check(model.items.count == 4, "Show duplicates only returns the two exact groups")
    model.duplicates = "hide"
    model.changeView()
    await settle()
    check(model.items.count == 24, "Hide duplicates keeps one representative per group")
    model.duplicates = "all"
    model.query = "Room tone"
    model.changeView()
    await settle()
    check(model.items.count == 4, "Filename search spans nested folders")
    model.query = ""
    model.changeView()
    let destination = output.appendingPathComponent("ui-export")
    try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    model.exportSettings.destination = destination.path
    model.startExport(originals: false)
    await capture(window, "export-controls", output: output)
    model.send("export", ["settings": model.exportSettings.json])
    model.showingReport = true
    await until { !model.report.running && model.report.completed == 3 }
    check(
      model.report.failed == 0 && model.report.converted == 2 && model.report.copied == 1,
      "Mixed export converts image/video and keeps audio unchanged")
    await capture(window, "export-complete", output: output)
    model.exportVisible = false
    model.send("dismiss_report")
    model.poll()
    model.preferences.theme = "dark"
    model.savePreferences()
    model.poll()
    await capture(window, "browsing-dark", output: output)
    window.setContentSize(NSSize(width: 920, height: 660))
    await capture(window, "browsing-compact-dark", output: output)
    window.setContentSize(NSSize(width: 1220, height: 820))
    model.preferences.theme = "light"
    model.savePreferences()
    model.poll()
    UITestMetrics.reset()
    model.send("refresh")
    model.poll()
    await until { !model.scanning && model.items.count == 26 }
    await settle()
    let refreshedGrid = descendants(window.contentView!).compactMap { $0 as? ContactCollection }
      .first!
    refreshedGrid.enclosingScrollView!.contentView.scroll(to: .zero)
    print(
      "REFRESH STATE \(model.total) files, \(model.items.filter { $0.thumbnail != nil }.count) thumbnails, first paint \(String(describing: UITestMetrics.firstPaintMS))"
    )
    fflush(stdout)
    await until { UITestMetrics.firstPaintMS != nil }
    record("mixed-cached-thumbnails", model)
    if let large = ProcessInfo.processInfo.environment["LILTFOLD_UI_TEST_LARGE"] {
      model.send("clear")
      UITestMetrics.reset()
      model.add([large])
      await until { !model.scanning && model.total == 5000 && UITestMetrics.firstPaintMS != nil }
      record("5000-images-cold-thumbnail-cache", model)
      await settle()
      let largeGrid = descendants(window.contentView!).compactMap { $0 as? ContactCollection }
        .first!
      let key = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
        keyCode: 0)!
      largeGrid.keyDown(with: key)
      check(
        model.selected.count == 5000,
        "Command-A selects all 5000 matches, including offscreen files")
      largeGrid.scrollToItems(at: [IndexPath(item: 4200, section: 0)], scrollPosition: .top)
      await until { largeGrid.indexPathsForVisibleItems().contains { $0.item >= 4200 } }
      check(
        largeGrid.visibleItems().count < 60, "Large collection keeps the native grid virtualised")
      await capture(window, "large-collection", output: output)
      UITestMetrics.reset()
      model.send("refresh")
      model.poll()
      await until { !model.scanning && UITestMetrics.firstPaintMS != nil }
      record("5000-images-cached-thumbnails", model)
    }
    model.send("clear")
    model.add([root])
    model.preferences.theme = "light"
    model.savePreferences()
    model.poll()
    let result: [String: Any] = [
      "checks": checks, "measurements": measurements, "build": "Rust release + Swift -O, arm64",
      "ui_driver": "in-process native test runner; no global input automation",
    ]
    try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("ui-results.json"))
    print("UI TESTS COMPLETE")
    fflush(stdout)
  }
}
