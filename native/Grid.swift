import AppKit
import SwiftUI

@MainActor
final class ThumbnailStore {
  static let shared = ThumbnailStore()
  let cache = NSCache<NSString, NSImage>()
  init() {
    cache.totalCostLimit = 96 * 1024 * 1024
    cache.countLimit = 180
  }
  func image(_ path: String?) -> NSImage? {
    guard let path else { return nil }
    if let image = cache.object(forKey: path as NSString) { return image }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    cache.setObject(
      image, forKey: path as NSString, cost: Int(image.size.width * image.size.height * 4))
    return image
  }
}

final class TileView: NSView {
  var item: MediaItem? {
    didSet {
      needsDisplay = true
      setAccessibilityLabel(item.map { "\($0.name), \($0.kind), \($0.detail)" })
    }
  }
  var chosen = false {
    didSet {
      needsDisplay = true
      setAccessibilityValue(chosen ? "Selected" : "Not selected")
    }
  }
  var open: (() -> Void)?
  override var isFlipped: Bool { true }
  override init(frame: NSRect) {
    super.init(frame: frame)
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func accessibilityPerformPress() -> Bool {
    open?()
    return true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let item else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let amber =
      dark
      ? NSColor(srgbRed: 0.93, green: 0.70, blue: 0.36, alpha: 1)
      : NSColor(srgbRed: 0.55, green: 0.34, blue: 0.03, alpha: 1)
    let rect = NSRect(x: 2, y: 2, width: bounds.width - 4, height: bounds.height - 45)
    let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    (dark
      ? NSColor(white: 0.185, alpha: 1)
      : NSColor(srgbRed: 0.916, green: 0.900, blue: 0.855, alpha: 1)).setFill()
    rect.fill()
    if let image = ThumbnailStore.shared.image(item.thumbnail) {
      #if UI_TESTING
        UITestMetrics.sawPreview()
      #endif
      let imageRatio = image.size.width / max(1, image.size.height)
      let targetRatio = rect.width / rect.height
      var source = NSRect(origin: .zero, size: image.size)
      if imageRatio > targetRatio {
        source.size.width = image.size.height * targetRatio
        source.origin.x = (image.size.width - source.width) / 2
      } else {
        source.size.height = image.size.width / targetRatio
        source.origin.y = (image.size.height - source.height) / 2
      }
      image.draw(
        in: rect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high])
    } else if item.kind == "audio" {
      let bars = item.waveform.isEmpty ? Array(repeating: Float(0.12), count: 64) : item.waveform
      let gap = rect.width * 0.76 / CGFloat(bars.count)
      amber.withAlphaComponent(item.waveform.isEmpty ? 0.28 : 0.68).setFill()
      for (i, value) in bars.enumerated() {
        let height = max(3, CGFloat(value) * rect.height * 0.42)
        NSBezierPath(
          roundedRect: NSRect(
            x: rect.minX + rect.width * 0.12 + CGFloat(i) * gap, y: rect.midY - height / 2,
            width: max(1, gap * 0.52), height: height), xRadius: 1, yRadius: 1
        ).fill()
      }
    } else {
      let symbol = NSImage(
        systemSymbolName: item.error == nil || item.kind == "other"
          ? item.symbol : "exclamationmark.triangle", accessibilityDescription: nil)
      symbol?.withSymbolConfiguration(.init(paletteColors: [Palette.secondaryNS]))?.draw(
        in: NSRect(x: rect.midX - 16, y: rect.midY - 16, width: 32, height: 32), from: .zero,
        operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
    }
    NSGraphicsContext.restoreGraphicsState()
    if chosen {
      amber.setStroke()
      let border = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 8, yRadius: 8)
      border.lineWidth = 2
      border.stroke()
    }
    if chosen || item.copies > 1 {
      let label = chosen ? "✓" : "\(item.copies) copies"
      let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
      let width = chosen ? 21.0 : (label as NSString).size(withAttributes: [.font: font]).width + 14
      let badge = NSRect(x: rect.maxX - width - 8, y: rect.minY + 8, width: width, height: 21)
      (chosen ? amber : NSColor.black.withAlphaComponent(0.68)).setFill()
      NSBezierPath(roundedRect: badge, xRadius: chosen ? 10.5 : 5, yRadius: chosen ? 10.5 : 5)
        .fill()
      (label as NSString).draw(
        at: NSPoint(x: badge.minX + (chosen ? 6 : 7), y: badge.minY + 3),
        withAttributes: [
          .font: font, .foregroundColor: chosen && dark ? NSColor.black : NSColor.white,
        ])
    }
    if item.kind == "video" {
      let text = item.info.duration > 0 ? "▶  " + timeText(item.info.duration) : "▶  Video"
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
      ]
      let size = (text as NSString).size(withAttributes: attrs)
      let badge = NSRect(x: rect.minX + 8, y: rect.maxY - 25, width: size.width + 12, height: 18)
      NSColor.black.withAlphaComponent(0.6).setFill()
      NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
      (text as NSString).draw(
        at: NSPoint(x: badge.minX + 6, y: badge.minY + 2), withAttributes: attrs)
    }
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingMiddle
    (item.name as NSString).draw(
      in: NSRect(x: 3, y: rect.maxY + 9, width: rect.width - 2, height: 16),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: chosen ? .semibold : .medium),
        .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
      ])
    paragraph.lineBreakMode = .byTruncatingTail
    let subtitle = item.error != nil ? item.detail : item.relativeLocation
    (subtitle as NSString).draw(
      in: NSRect(x: 3, y: rect.maxY + 26, width: rect.width - 2, height: 15),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 10.5), .foregroundColor: Palette.secondaryNS,
        .paragraphStyle: paragraph,
      ])
  }
}

final class MediaCell: NSCollectionViewItem {
  override func loadView() { view = TileView() }
  override var isSelected: Bool { didSet { (view as? TileView)?.chosen = isSelected } }
}
final class ContactCollection: NSCollectionView {
  var previewAction: (() -> Void)?, allAction: (() -> Void)?, clearAction: (() -> Void)?
  var menuAction: ((NSEvent) -> NSMenu?)?
  override func setFrameSize(_ newSize: NSSize) {
    let changed = abs(frame.width - newSize.width) > 1
    super.setFrameSize(newSize)
    if changed { collectionViewLayout?.invalidateLayout() }
  }
  override func keyDown(with event: NSEvent) {
    if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
      previewAction?()
    } else if event.charactersIgnoringModifiers == "a" && event.modifierFlags.contains(.command) {
      allAction?()
    } else if event.keyCode == 53 {
      clearAction?()
    } else {
      super.keyDown(with: event)
    }
  }
  override func menu(for event: NSEvent) -> NSMenu? { menuAction?(event) }
}

struct ContactSheet: NSViewRepresentable {
  @ObservedObject var model: LibraryModel
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let collection = ContactCollection()
    collection.isSelectable = true
    collection.allowsMultipleSelection = true
    collection.backgroundColors = [.clear]
    collection.autoresizingMask = [.width]
    let flow = NSCollectionViewFlowLayout()
    flow.minimumInteritemSpacing = 16
    flow.minimumLineSpacing = 19
    flow.sectionInset = NSEdgeInsets(top: 10, left: 28, bottom: 24, right: 28)
    collection.collectionViewLayout = flow
    collection.dataSource = context.coordinator
    collection.delegate = context.coordinator
    collection.register(
      MediaCell.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("media"))
    collection.setAccessibilityLabel(
      "Media collection. Use arrow keys to browse, Space to preview, Command-A to select all matching files."
    )
    scroll.documentView = collection
    let c = context.coordinator
    c.collection = collection
    c.scroll = scroll
    collection.previewAction = { [weak c] in c?.openSelection() }
    collection.allAction = { [weak model] in
      model?.send("select_all")
      model?.poll()
    }
    collection.clearAction = { [weak model] in
      model?.send("deselect_all")
      model?.poll()
    }
    collection.menuAction = { [weak c] event in c?.contextMenu(event) }
    let doubleClick = NSClickGestureRecognizer(
      target: c, action: #selector(Coordinator.doubleClick(_:)))
    doubleClick.numberOfClicksRequired = 2
    collection.addGestureRecognizer(doubleClick)
    scroll.contentView.postsBoundsChangedNotifications = true
    c.observer = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak c] _ in MainActor.assumeIsolated { c?.requestVisible() } }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update() }
  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
  }

  @MainActor
  final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout
  {
    let model: LibraryModel
    weak var collection: ContactCollection?, scroll: NSScrollView?
    var entries: [MediaItem] = [], ids: [Int] = []
    var observer: NSObjectProtocol?, lastSize: Double = 0, updating = false, lastRevision = -1
    var lastView = ""
    var menuID: Int?
    init(_ model: LibraryModel) { self.model = model }
    func update() {
      guard let collection, let scroll else { return }
      updating = true
      let newIDs = model.items.map(\.id)
      let changed = ids != newIDs
      let viewKey = [model.filter, model.query, model.sort, model.duplicates] + model.roots
      let resetPosition = lastView != viewKey.joined(separator: "\n")
      lastView = viewKey.joined(separator: "\n")
      let position = scroll.contentView.bounds.origin
      let anchorIndex = collection.indexPathsForVisibleItems().sorted().first
      let anchorID = anchorIndex.flatMap {
        entries.indices.contains($0.item) ? entries[$0.item].id : nil
      }
      let anchorY = anchorIndex.flatMap { collection.layoutAttributesForItem(at: $0)?.frame.minY }
      entries = model.items
      ids = newIDs
      if changed {
        collection.reloadData()
        collection.layoutSubtreeIfNeeded()
        if resetPosition {
          scroll.contentView.scroll(to: .zero)
        } else if let id = anchorID, let oldY = anchorY, let index = ids.firstIndex(of: id),
          let frame = collection.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?
            .frame
        {
          scroll.contentView.scroll(
            to: NSPoint(x: position.x, y: max(0, frame.minY + position.y - oldY)))
        }
      }
      if lastSize != model.preferences.thumbnail_size {
        lastSize = model.preferences.thumbnail_size
        collection.collectionViewLayout?.invalidateLayout()
      }
      if lastRevision != model.gridRevision || changed {
        for cell in collection.visibleItems() {
          if let index = collection.indexPath(for: cell)?.item, entries.indices.contains(index) {
            let tile = cell.view as! TileView
            tile.item = entries[index]
            tile.chosen = model.selected.contains(entries[index].id)
          }
        }
        lastRevision = model.gridRevision
      }
      let selection = Set(
        entries.enumerated().filter { model.selected.contains($0.element.id) }.map {
          IndexPath(item: $0.offset, section: 0)
        })
      if collection.selectionIndexPaths != selection { collection.selectionIndexPaths = selection }
      updating = false
      DispatchQueue.main.async { [weak self] in self?.requestVisible() }
    }
    func requestVisible() {
      guard let collection, !entries.isEmpty else { return }
      let visible = collection.indexPathsForVisibleItems().map(\.item).sorted()
      guard let first = visible.first, let last = visible.last else { return }
      let near = Array(max(0, first - 12)...min(entries.count - 1, last + 12))
      let indices = visible + near.filter { !visible.contains($0) }
      model.send(
        "thumbnails",
        ["ids": indices.filter { entries.indices.contains($0) }.map { entries[$0].id }],
        displayError: false)
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
      -> Int
    { entries.count }
    func collectionView(
      _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
      let cell = collectionView.makeItem(
        withIdentifier: NSUserInterfaceItemIdentifier("media"), for: indexPath)
      let tile = cell.view as! TileView
      let item = entries[indexPath.item]
      tile.item = item
      tile.chosen = model.selected.contains(item.id)
      tile.open = { [weak model] in model?.openPreview(item.id) }
      return cell
    }
    func collectionView(
      _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
      sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
      let width = max(100, collectionView.bounds.width - 56)
      let count = max(1, floor((width + 16) / (model.preferences.thumbnail_size + 16)))
      let itemWidth = floor((width - (count - 1) * 16) / count)
      return NSSize(width: itemWidth, height: itemWidth * 0.76 + 45)
    }
    func collectionView(
      _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
    ) { selectionChanged() }
    func collectionView(
      _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
    ) { selectionChanged() }
    func selectionChanged() {
      guard !updating, let collection else { return }
      let hidden = model.selected.subtracting(Set(ids))
      let visible = Set(
        collection.selectionIndexPaths.compactMap {
          entries.indices.contains($0.item) ? entries[$0.item].id : nil
        })
      model.setSelection(hidden.union(visible))
    }
    func openSelection() {
      guard let collection, let index = collection.selectionIndexPaths.sorted().first?.item,
        entries.indices.contains(index)
      else { return }
      model.openPreview(entries[index].id)
    }
    @objc func doubleClick(_ gesture: NSClickGestureRecognizer) {
      guard let collection,
        let index = collection.indexPathForItem(at: gesture.location(in: collection))?.item,
        entries.indices.contains(index)
      else { return }
      model.openPreview(entries[index].id)
    }
    func contextMenu(_ event: NSEvent) -> NSMenu? {
      guard let collection,
        let index = collection.indexPathForItem(
          at: collection.convert(event.locationInWindow, from: nil))?.item,
        entries.indices.contains(index)
      else { return nil }
      let item = entries[index]
      menuID = item.id
      let menu = NSMenu()
      let preview = menu.addItem(
        withTitle: "Open preview", action: #selector(menuPreview), keyEquivalent: "")
      preview.target = self
      let reveal = menu.addItem(
        withTitle: "Reveal in Finder", action: #selector(menuReveal), keyEquivalent: "")
      reveal.target = self
      if item.copies > 1 {
        menu.addItem(.separator())
        let title = NSMenuItem(
          title: "\(item.copies) identical copies", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        // This command returns an array; use the bridge directly for the duplicate locations.
        let input = "{\"action\":\"duplicates\",\"id\":\(item.id)}"
        let copies: [MediaItem] = input.withCString { p in
          guard let result = lilt_command(p) else { return [] }
          defer { lilt_free(result) }
          return
            (try? JSONDecoder().decode([MediaItem].self, from: Data(String(cString: result).utf8)))
            ?? []
        }
        for copy in copies {
          let row = menu.addItem(
            withTitle: "Use \(copy.path)", action: #selector(useRepresentative(_:)),
            keyEquivalent: "")
          row.target = self
          row.tag = copy.id
          row.toolTip = copy.path
        }
      }
      return menu
    }
    @objc func menuPreview() { if let id = menuID { model.openPreview(id) } }
    @objc func menuReveal() {
      if let id = menuID, let item = entries.first(where: { $0.id == id }) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
      }
    }
    @objc func useRepresentative(_ sender: NSMenuItem) {
      model.send("representative", ["id": sender.tag])
      model.poll()
    }
  }
}
