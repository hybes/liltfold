import AVKit
import AppKit
import SwiftUI

@MainActor final class Playback: ObservableObject {
  let player = AVPlayer()
  @Published var playing = false
  @Published var position = 0.0
  @Published var duration = 0.0
  @Published var volume = 0.8
  @Published var error: String?
  var path = ""
  var observer: Any?, statusObserver: NSKeyValueObservation?
  init() {
    player.volume = 0.8
    observer = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main
    ) { [weak self] time in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.position = time.seconds.isFinite ? time.seconds : 0
        self.playing = self.player.rate > 0
        if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite {
          self.duration = seconds
        }
      }
    }
  }
  func load(_ path: String, duration: Double) {
    guard self.path != path else { return }
    player.pause()
    self.path = path
    self.duration = duration
    position = 0
    error = nil
    let item = AVPlayerItem(url: URL(fileURLWithPath: path))
    player.replaceCurrentItem(with: item)
    #if UI_TESTING
      UITestMetrics.playback = self
    #endif
    statusObserver = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      if item.status == .failed {
        let message = item.error?.localizedDescription ?? "This media cannot be played by macOS."
        Task { @MainActor in self?.error = message }
      }
    }
  }
  func toggle() {
    if player.rate > 0 {
      player.pause()
    } else {
      if position >= duration - 0.1 { player.seek(to: .zero) }
      player.play()
    }
    playing = player.rate > 0
  }
  func seek(_ seconds: Double) {
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
    position = seconds
  }
  func stop() {
    player.pause()
    playing = false
  }
  deinit { if let observer { player.removeTimeObserver(observer) } }
}

struct NativePlayer: NSViewRepresentable {
  let player: AVPlayer
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .floating
    view.showsFullScreenToggleButton = true
    view.videoGravity = .resizeAspect
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
  }
  static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
    view.player?.pause()
    view.player = nil
  }
}

final class ImageScroll: NSScrollView {
  let picture = NSImageView()
  var loadedPath = "", fitSize = NSSize.zero
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    drawsBackground = false
    hasHorizontalScroller = true
    hasVerticalScroller = true
    autohidesScrollers = true
    allowsMagnification = true
    minMagnification = 0.25
    maxMagnification = 6
    picture.imageScaling = .scaleProportionallyUpOrDown
    picture.animates = true
    documentView = picture
    setAccessibilityLabel("Image preview. Pinch or use the zoom control to magnify.")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func layout() {
    super.layout()
    if fitSize != bounds.size, let image = picture.image {
      fitSize = bounds.size
      let ratio = min(
        bounds.width / max(image.size.width, 1), bounds.height / max(image.size.height, 1))
      picture.frame = NSRect(
        x: 0, y: 0, width: max(bounds.width, image.size.width * ratio),
        height: max(bounds.height, image.size.height * ratio))
    }
  }
  func load(_ path: String) {
    guard loadedPath != path else { return }
    loadedPath = path
    picture.image = NSImage(contentsOfFile: path)
    fitSize = .zero
    magnification = 1
    needsLayout = true
  }
}
struct ZoomImage: NSViewRepresentable {
  var path: String
  @Binding var zoom: Double
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> ImageScroll {
    let view = ImageScroll()
    let coordinator = context.coordinator
    coordinator.start = NotificationCenter.default.addObserver(
      forName: NSScrollView.willStartLiveMagnifyNotification, object: view, queue: .main
    ) { [weak coordinator] _ in MainActor.assumeIsolated { coordinator?.magnifying = true } }
    coordinator.end = NotificationCenter.default.addObserver(
      forName: NSScrollView.didEndLiveMagnifyNotification, object: view, queue: .main
    ) { [weak coordinator, weak view] _ in
      MainActor.assumeIsolated {
        guard let coordinator, let view else { return }
        coordinator.owner.zoom = view.magnification
        coordinator.magnifying = false
      }
    }
    return view
  }
  func updateNSView(_ view: ImageScroll, context: Context) {
    context.coordinator.owner = self
    view.load(path)
    if !context.coordinator.magnifying && abs(view.magnification - zoom) > 0.015 {
      view.setMagnification(
        zoom,
        centeredAt: NSPoint(x: view.documentVisibleRect.midX, y: view.documentVisibleRect.midY))
    }
  }
  static func dismantleNSView(_ view: ImageScroll, coordinator: Coordinator) {
    if let start = coordinator.start { NotificationCenter.default.removeObserver(start) }
    if let end = coordinator.end { NotificationCenter.default.removeObserver(end) }
  }
  @MainActor final class Coordinator {
    var owner: ZoomImage
    var magnifying = false
    var start: NSObjectProtocol?, end: NSObjectProtocol?
    init(_ owner: ZoomImage) { self.owner = owner }
  }
}

struct Waveform: Shape {
  var values: [Float]
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let values = values.isEmpty ? Array(repeating: Float(0.06), count: 128) : values
    let gap = rect.width / CGFloat(values.count)
    for (index, value) in values.enumerated() {
      let height = max(3, CGFloat(value) * rect.height)
      path.addRoundedRect(
        in: CGRect(
          x: CGFloat(index) * gap, y: (rect.height - height) / 2, width: max(1, gap * 0.48),
          height: height), cornerSize: CGSize(width: 2, height: 2))
    }
    return path
  }
}

struct PreviewView: View {
  @ObservedObject var model: LibraryModel
  let preview: PreviewState
  @StateObject private var playback = Playback()
  @State private var zoom = 1.0
  var item: MediaItem { model.items.first(where: { $0.id == preview.id }) ?? preview.item }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        Button {
          playback.stop()
          model.closePreview()
        } label: {
          Label("Back to collection", systemImage: "arrow.left")
        }.keyboardShortcut(.escape, modifiers: [])
        Spacer()
        Button {
          playback.stop()
          model.nextPreview(-1)
          zoom = 1
        } label: {
          Image(systemName: "chevron.left")
        }.accessibilityLabel("Previous file").keyboardShortcut(.leftArrow, modifiers: [])
        Text(
          "\((model.items.firstIndex(where: { $0.id == item.id }) ?? 0) + 1) of \(model.items.count)"
        ).font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondary)
        Button {
          playback.stop()
          model.nextPreview(1)
          zoom = 1
        } label: {
          Image(systemName: "chevron.right")
        }.accessibilityLabel("Next file").keyboardShortcut(.rightArrow, modifiers: [])
      }.padding(.horizontal, 28).padding(.top, 43).padding(.bottom, 22)
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 7) {
          Text(item.name).font(.system(size: 27, weight: .regular, design: .serif)).lineLimit(1)
            .truncationMode(.middle).textSelection(.enabled)
          Text(item.path).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(1)
            .truncationMode(.middle).textSelection(.enabled).help(item.path)
        }
        Spacer(minLength: 20)
        Button(
          model.selected.contains(item.id) ? "Selected" : "Select file",
          systemImage: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle"
        ) {
          var ids = model.selected
          if ids.contains(item.id) { ids.remove(item.id) } else { ids.insert(item.id) }
          model.setSelection(ids)
        }
      }.padding(.horizontal, 32).padding(.bottom, 22)
      ZStack {
        if let error = preview.error ?? playback.error {
          VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle)
            Text("Preview unavailable").font(.title2)
            Text(error).font(.callout).foregroundStyle(Palette.secondary).multilineTextAlignment(
              .center
            ).frame(maxWidth: 500)
            Text("The original can still be copied.").font(.caption).foregroundStyle(
              Palette.secondary)
          }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == "image" {
          if let path = preview.path ?? item.thumbnail {
            ZoomImage(path: path, zoom: $zoom).padding(.horizontal, 30).padding(.bottom, 12)
          }
        } else if item.kind == "video" {
          if preview.status == "ready" {
            NativePlayer(player: playback.player).padding(.horizontal, 30).padding(.bottom, 12)
          } else if let image = ThumbnailStore.shared.image(item.thumbnail) {
            Image(nsImage: image).resizable().scaledToFit().padding(30)
          }
        } else if item.kind == "audio" {
          audioPreview
        }
        if preview.status == "loading" {
          VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(item.kind == "video" ? "Preparing playback…" : "Opening preview…").font(.caption)
          }.padding(18).background(
            Palette.background.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
      Rectangle().fill(Palette.line).frame(height: 1)
      HStack(spacing: 18) {
        Text(item.detail).font(.system(size: 12, weight: .medium))
        Text(sizeText(item.size)).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        if item.copies > 1 {
          Text("\(item.copies) exact copies").font(.caption).foregroundStyle(Palette.amber)
        }
        Spacer()
        if item.kind == "image" {
          Button("Fit") { zoom = 1 }
          Slider(value: $zoom, in: 0.5...4).frame(width: 115).accessibilityLabel("Image zoom")
          Text(String(format: "%.1f×", zoom)).font(.caption.monospacedDigit()).frame(width: 38)
            .help("Zoom relative to fit. Large previews are limited to 4096 pixels.")
          if item.info.frames > 1 {
            Text("Frame 1 of \(item.info.frames)").font(.caption).foregroundStyle(Palette.secondary)
          }
        }
        Button("Reveal in Finder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
      }.padding(.horizontal, 30).padding(.vertical, 18)
    }
    .background(Palette.background)
    .onChange(of: preview.path, initial: true) {
      if let path = preview.path, item.kind == "audio" || item.kind == "video" {
        playback.load(path, duration: item.info.duration)
      }
    }
    .onChange(of: preview.id) {
      playback.stop()
      zoom = 1
    }
    .onDisappear { playback.stop() }
  }
  var audioPreview: some View {
    VStack(spacing: 28) {
      Image(systemName: "waveform").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(
        Palette.amber
      ).padding(.bottom, 2)
      VStack(spacing: 8) {
        Text(item.info.title.isEmpty ? item.name : item.info.title).font(
          .system(size: 30, design: .serif))
        Text(
          item.info.artist.isEmpty
            ? "\(item.info.codec.uppercased()) · \(item.info.sample_rate.formatted()) Hz · \(item.info.channels) channels"
            : item.info.artist
        ).font(.system(size: 12)).foregroundStyle(Palette.secondary)
      }
      Waveform(values: item.waveform).fill(Palette.amber.opacity(0.72)).frame(height: 105).padding(
        .vertical, 12
      ).accessibilityLabel(item.waveform.isEmpty ? "Waveform loading" : "Audio waveform")
      VStack(spacing: 15) {
        Slider(
          value: Binding(
            get: { min(playback.position, max(playback.duration, 0.1)) }, set: playback.seek),
          in: 0...max(playback.duration, 0.1)
        ).accessibilityLabel("Playback position")
        HStack {
          Text(timeText(playback.position)).monospacedDigit()
          Spacer()
          Button {
            playback.toggle()
          } label: {
            Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.system(size: 21))
              .frame(width: 52, height: 35)
          }.buttonStyle(.borderedProminent).accessibilityLabel(playback.playing ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])
          Spacer()
          Text(timeText(playback.duration)).monospacedDigit()
        }.font(.caption)
        HStack(spacing: 10) {
          Image(systemName: "speaker.fill")
          Slider(value: $playback.volume, in: 0...1).frame(width: 130).accessibilityLabel("Volume")
            .onChange(of: playback.volume) { playback.player.volume = Float(playback.volume) }
          Image(systemName: "speaker.wave.3.fill")
        }.font(.caption).foregroundStyle(Palette.secondary).padding(.top, 8)
      }
    }.frame(maxWidth: 640).padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
