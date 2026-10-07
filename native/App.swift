import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
  @ObservedObject var model: LibraryModel
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  @State private var dropping = false
  var body: some View {
    ZStack {
      Palette.background.ignoresSafeArea()
      VStack(spacing: 0) {
        header
        Rectangle().fill(Palette.line).frame(height: 1)
        filters
        if model.roots.isEmpty {
          welcome
        } else if model.items.isEmpty {
          empty
        } else {
          ContactSheet(model: model)
        }
        footer
      }
      .allowsHitTesting(model.preview == nil)
      .accessibilityHidden(model.preview != nil)
      if let preview = model.preview {
        PreviewView(model: model, preview: preview)
          .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985)))
          .zIndex(2)
      }
      if dropping {
        RoundedRectangle(cornerRadius: 16).strokeBorder(
          Palette.amber, style: StrokeStyle(lineWidth: 3, dash: [10, 7])
        ).padding(12).allowsHitTesting(false)
      }
    }
    .tint(Palette.amber)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: model.preview != nil)
    .onDrop(of: [UTType.fileURL], isTargeted: $dropping, perform: model.acceptDrop)
    .sheet(isPresented: $model.exportVisible) {
      if model.showingReport { ExportProgressView(model: model) } else { ExportSheet(model: model) }
    }
    .sheet(isPresented: $model.showIssues) { IssuesView(model: model) }
    .alert(
      "Liltfold couldn’t finish that action",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("OK", role: .cancel) { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
  var header: some View {
    HStack(spacing: 14) {
      BrandMark(size: 42)
      VStack(alignment: .leading, spacing: 3) {
        Text("Liltfold").font(.system(size: 25, weight: .medium, design: .serif)).tracking(-0.6)
        Text(
          model.roots.isEmpty
            ? "A little order. Room to explore."
            : "\(model.total.formatted()) files · every subfolder, together"
        ).font(.system(size: 11)).foregroundStyle(Palette.secondary)
      }
      Spacer(minLength: 24)
      if !model.roots.isEmpty {
        Menu {
          ForEach(model.roots, id: \.self) { root in
            Section(URL(fileURLWithPath: root).lastPathComponent) {
              Text(root)
              Button("Reveal in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: root)) }
              Button("Remove from collection") {
                model.send("remove_root", ["path": root])
                model.poll()
              }
            }
          }
          Divider()
          Button("Refresh folders", systemImage: "arrow.clockwise") {
            model.send("refresh")
            model.poll()
          }
          Button("Clear collection") {
            model.send("clear")
            model.poll()
          }
        } label: {
          Label(
            model.roots.count == 1
              ? URL(fileURLWithPath: model.roots[0]).lastPathComponent
              : "\(model.roots.count) folders", systemImage: "folder")
        }
        .menuStyle(.borderlessButton).fixedSize().frame(maxWidth: 220).help(
          "Manage source folders. All subfolders are included.")
      }
      Button(action: model.addFolders) { Label("Add folders", systemImage: "plus") }.controlSize(
        .large
      ).keyboardShortcut("o")
      Menu {
        Picker("Appearance", selection: $model.preferences.theme) {
          Text("System appearance").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        .onChange(of: model.preferences.theme) { model.savePreferences() }
        Divider()
        Text("All processing stays on this Mac")
      } label: {
        Image(systemName: "circle.lefthalf.filled").frame(width: 22, height: 24)
      }
      .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Appearance")
    }.padding(.horizontal, 28).padding(.top, 38).padding(.bottom, 20)
  }
  var filters: some View {
    VStack(spacing: 14) {
      HStack(spacing: 18) {
        Picker("Media filter", selection: $model.filter) {
          Text("All").tag("all")
          Text("Images").tag("image")
          Text("Video").tag("video")
          Text("Audio").tag("audio")
        }.pickerStyle(.segmented).labelsHidden().frame(width: 302).onChange(of: model.filter) {
          model.changeView()
        }
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
          TextField("Search filenames", text: $model.query).textFieldStyle(.plain)
            .accessibilityLabel("Search filenames")
          if !model.query.isEmpty {
            Button {
              model.query = ""
            } label: {
              Image(systemName: "xmark.circle.fill")
            }.buttonStyle(.plain).accessibilityLabel("Clear search")
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 7).background(
          .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6)
        ).frame(minWidth: 140, maxWidth: 320)
        .onChange(of: model.query) { model.changeView() }
        Spacer(minLength: 0)
        Picker("Sort", selection: $model.sort) {
          Text("Name").tag("name")
          Text("Newest first").tag("date")
          Text("Largest first").tag("size")
          Text("Media type").tag("type")
        }
        .labelsHidden().frame(width: 125).onChange(of: model.sort) { model.changeView() }
        .accessibilityLabel("Sort files")
        HStack(spacing: 7) {
          Image(systemName: "square.grid.3x3").font(.system(size: 10)).foregroundStyle(
            Palette.secondary)
          Slider(value: $model.preferences.thumbnail_size, in: 132...280).frame(width: 76)
            .accessibilityLabel("Thumbnail size").onChange(of: model.preferences.thumbnail_size) {
              model.savePreferences()
            }
          Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(
            Palette.secondary)
        }
      }
      if !model.roots.isEmpty {
        HStack(spacing: 18) {
          Text(
            model.scanning
              ? "Discovering… \(model.total.formatted()) files"
              : "\(model.matching.formatted()) \(model.matching == 1 ? "file" : "files") in view"
          ).font(.system(size: 11, weight: .medium)).monospacedDigit()
          Toggle(
            "Hide exact duplicates",
            isOn: Binding(
              get: { model.duplicates == "hide" },
              set: {
                model.duplicates = $0 ? "hide" : "all"
                model.changeView()
              })
          ).toggleStyle(.checkbox).font(.system(size: 11))
          Toggle(
            "Show duplicates only",
            isOn: Binding(
              get: { model.duplicates == "only" },
              set: {
                model.duplicates = $0 ? "only" : "all"
                model.changeView()
              })
          ).toggleStyle(.checkbox).font(.system(size: 11))
          Spacer(minLength: 8)
          if model.scanning {
            Button("Stop discovery") {
              model.send("cancel_scan")
              model.poll()
            }.font(.system(size: 11))
          } else {
            Text(model.duplicateStatus).font(.system(size: 10.5)).foregroundStyle(Palette.secondary)
              .lineLimit(1).help(model.duplicateStatus)
          }
        }
      }
    }.padding(.horizontal, 28).padding(.top, 19).padding(.bottom, model.roots.isEmpty ? 0 : 9)
  }
  var welcome: some View {
    VStack(spacing: 0) {
      Spacer()
      BrandMark(size: 74).padding(.bottom, 25)
      Text("Let your folders unfold.").font(.system(size: 36, weight: .regular, design: .serif))
        .tracking(-0.9)
      Text("Drop a folder here. Find every image, film and sound inside.")
        .font(.system(size: 14)).foregroundStyle(Palette.secondary).padding(.top, 14)
      Text("Your originals stay exactly where they are.").font(.system(size: 12)).foregroundStyle(
        Palette.secondary
      ).padding(.top, 7)
      Button("Choose folders…", action: model.addFolders).buttonStyle(.borderedProminent)
        .controlSize(.large).padding(.top, 28)
      HStack(spacing: 20) {
        Label("Images", systemImage: "photo")
        Label("Video", systemImage: "play.rectangle")
        Label("Audio", systemImage: "waveform")
      }.font(.system(size: 11)).foregroundStyle(Palette.secondary).padding(.top, 30)
      Spacer()
      Spacer().frame(height: 35)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  var empty: some View {
    VStack(spacing: 14) {
      if model.scanning {
        ProgressView().controlSize(.small)
        Text("Opening the collection…").font(.system(size: 23, design: .serif))
      } else {
        Image(systemName: "rectangle.stack").font(.system(size: 30, weight: .light))
          .foregroundStyle(Palette.secondary)
        Text(model.total == 0 ? "Nothing to unfold here yet." : "No files match this view.").font(
          .system(size: 25, design: .serif))
        Text(
          model.total == 0
            ? "Add another folder, or check folder access."
            : "Try another filter or a shorter filename search."
        ).foregroundStyle(Palette.secondary)
        if model.total > 0 {
          Button("Reset filters") {
            model.filter = "all"
            model.query = ""
            model.duplicates = "all"
            model.changeView()
          }
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }
  var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Palette.line).frame(height: 1)
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 4) {
          Text(
            model.selected.isEmpty
              ? "Select files to copy or convert."
              : "\(model.selected.count.formatted()) selected\(model.hiddenSelected > 0 ? " · \(model.hiddenSelected) hidden by filters" : "")"
          ).font(.system(size: 12, weight: model.selected.isEmpty ? .regular : .semibold))
            .foregroundStyle(model.selected.isEmpty ? .secondary : .primary)
          if !model.roots.isEmpty {
            HStack(spacing: 12) {
              Button("Select all matching") {
                model.send("select_all")
                model.poll()
              }
              if !model.selected.isEmpty {
                Button("Clear selection") {
                  model.send("deselect_all")
                  model.poll()
                }
              }
              if !model.issues.isEmpty {
                Button("\(model.issues.count) folder issues") { model.showIssues = true }
              }
            }.buttonStyle(.plain).foregroundStyle(Palette.amber).font(.system(size: 11))
          }
        }
        Spacer(minLength: 12)
        if model.report.running {
          Button("Exporting \(model.report.completed)/\(model.report.total)…") {
            model.showingReport = true
            model.exportVisible = true
          }
        } else {
          Button("Copy originals") { model.startExport(originals: true) }.controlSize(.large)
            .disabled(model.total == 0)
          Button("Copy as…") { model.startExport(originals: false) }.buttonStyle(.borderedProminent)
            .controlSize(.large).disabled(model.total == 0)
        }
      }.padding(.horizontal, 28).padding(.vertical, 17)
    }
  }
}

struct IssuesView: View {
  @ObservedObject var model: LibraryModel
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Folders that need attention").font(.title2)
      Text("These locations could not be read. Accessible files are still available.")
        .foregroundStyle(Palette.secondary)
      ScrollView {
        Text(model.issues.joined(separator: "\n\n")).textSelection(.enabled).frame(
          maxWidth: .infinity, alignment: .leading)
      }
      HStack {
        Button("Refresh folders") {
          model.send("refresh")
          model.showIssues = false
        }
        Spacer()
        Button("Done") { model.showIssues = false }.keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 600, height: 380).background(Palette.background)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var window: NSWindow!
  var model: LibraryModel!
  var pendingFiles: [String] = []
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.applicationIconImage = NSImage(
      contentsOf: Bundle.main.url(forResource: "Liltfold", withExtension: "icns")!)
    model = LibraryModel()
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Liltfold"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = false
    window.minSize = NSSize(width: 900, height: 640)
    window.center()
    window.setFrameAutosaveName("LiltfoldLibrary")
    window.contentView = NSHostingView(rootView: LibraryView(model: model))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    makeMenu()
    let paths = CommandLine.arguments.dropFirst().filter {
      !$0.hasPrefix("-") && FileManager.default.fileExists(atPath: $0)
    }
    #if UI_TESTING
      UITestMetrics.start = ProcessInfo.processInfo.systemUptime
    #endif
    if !paths.isEmpty || !pendingFiles.isEmpty { model.add(Array(Set(paths + pendingFiles))) }
    #if UI_TESTING
      Task { await UITestRunner.run(self) }
    #endif
  }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    if let model { model.add(filenames) } else { pendingFiles += filenames }
    sender.reply(toOpenOrPrint: .success)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard model?.report.running == true else { return .terminateNow }
    let alert = NSAlert()
    alert.messageText = "Cancel the export and quit?"
    alert.informativeText =
      "Completed files will be kept. The file currently being written will be discarded."
    alert.addButton(withTitle: "Keep exporting")
    alert.addButton(withTitle: "Cancel export and quit")
    if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
    model.send("cancel_export")
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
      MainActor.assumeIsolated {
        self?.model.poll()
        if self?.model.report.running != true {
          timer.invalidate()
          NSApp.reply(toApplicationShouldTerminate: true)
        }
      }
    }
    return .terminateLater
  }
  func makeMenu() {
    let main = NSMenu()
    let app = NSMenu()
    app.addItem(withTitle: "About Liltfold", action: #selector(about), keyEquivalent: "").target =
      self
    app.addItem(.separator())
    app.addItem(
      withTitle: "Hide Liltfold", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    app.addItem(
      withTitle: "Quit Liltfold", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
    )
    let appItem = NSMenuItem()
    appItem.submenu = app
    main.addItem(appItem)
    let file = NSMenu(title: "File")
    file.addItem(withTitle: "Add folders…", action: #selector(add), keyEquivalent: "o").target =
      self
    file.addItem(withTitle: "Refresh folders", action: #selector(refresh), keyEquivalent: "r")
      .target = self
    file.addItem(.separator())
    file.addItem(withTitle: "Copy originals…", action: #selector(copyOriginals), keyEquivalent: "")
      .target = self
    file.addItem(withTitle: "Copy as…", action: #selector(copyAs), keyEquivalent: "e").target = self
    let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
    fileItem.submenu = file
    main.addItem(fileItem)
    let edit = NSMenu(title: "Edit")
    for (title, selector, key) in [
      ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"),
      ("Paste", #selector(NSText.paste(_:)), "v"),
    ] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
    edit.addItem(
      withTitle: "Select all matching files", action: #selector(selectAll), keyEquivalent: "a"
    ).target = self
    let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    editItem.submenu = edit
    main.addItem(editItem)
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimise", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
    let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    NSApp.mainMenu = main
  }
  @objc func add() { model.addFolders() }
  @objc func refresh() {
    model.send("refresh")
    model.poll()
  }
  @objc func copyOriginals() { model.startExport(originals: true) }
  @objc func copyAs() { model.startExport(originals: false) }
  @objc func selectAll() {
    if let text = window.firstResponder as? NSTextView {
      text.selectAll(nil)
    } else {
      model.send("select_all")
      model.poll()
    }
  }
  @objc func about() {
    NSApp.orderFrontStandardAboutPanel(options: [
      .applicationName: "Liltfold", .applicationVersion: "0.1.0",
      .credits: NSAttributedString(
        string:
          "Made for the media already on your Mac.\nRust · AppKit · ImageIO · AVKit\nIncludes FFmpeg (GPL v3) and libwebp.\nSee Resources/Licenses for notices."
      ),
    ])
  }
}

@main struct LiltfoldMain {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
  }
}
