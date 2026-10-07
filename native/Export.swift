import AppKit
import SwiftUI

struct ExportSheet: View {
  @ObservedObject var model: LibraryModel
  @State private var plan: [String: Any] = [:]
  @State private var preset = "high"
  @State private var details = false
  @State private var sourcePlan: [String: Any] = [:]
  var count: Int { plan["count"] as? Int ?? 0 }
  var settings: Binding<ExportSettings> { $model.exportSettings }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 7) {
          Text(model.exportSettings.originals ? "Copy originals" : "Copy as…").font(
            .system(size: 30, weight: .regular, design: .serif))
          Text(
            model.exportSettings.originals
              ? "Exactly as they are. Every byte preserved."
              : "Choose what comes with you, and how it arrives."
          ).font(.system(size: 12)).foregroundStyle(Palette.secondary)
        }
        Spacer()
        BrandMark(size: 37)
      }.padding(28)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          field("Files to include") {
            Picker("Export scope", selection: settings.all_matching) {
              Text("Selected (\(model.selected.count))").tag(false)
              Text("All matching (\(model.matching))").tag(true)
            }.pickerStyle(.segmented).labelsHidden()
            if !model.exportSettings.all_matching && model.hiddenSelected > 0 {
              Text("Includes \(model.hiddenSelected) selected files hidden by your filters.").font(
                .caption
              ).foregroundStyle(Palette.amber)
            }
            if model.exportSettings.all_matching && model.scanning {
              Text("Discovery must finish before exporting all matching files.").font(.caption)
                .foregroundStyle(Palette.amber)
            }
          }
          field("Destination") {
            HStack {
              Image(systemName: "folder").foregroundStyle(Palette.amber)
              Text(
                model.exportSettings.destination.isEmpty
                  ? "Choose a destination folder" : model.exportSettings.destination
              ).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
              Spacer()
              Button("Choose…", action: chooseDestination)
            }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
            if model.roots.contains(where: { model.exportSettings.destination.hasPrefix($0 + "/") })
            {
              Text(
                "This destination is inside a source folder. It will be excluded from further scans in this collection."
              ).font(.caption).foregroundStyle(Palette.secondary)
            }
          }
          if !model.exportSettings.originals {
            field("Formats") {
              formatRow(
                "Images", count: sourceCount("image"), selection: settings.image,
                formats: [("WebP", "webp"), ("JPEG", "jpeg"), ("PNG", "png")])
              formatRow(
                "Video", count: sourceCount("video"), selection: settings.video,
                formats: [("MP4 · H.264", "mp4"), ("WebM · VP9", "webm")])
              formatRow(
                "Audio", count: sourceCount("audio"), selection: settings.audio,
                formats: [("MP3", "mp3"), ("M4A · AAC", "m4a"), ("WAV", "wav"), ("FLAC", "flac")])
              if sourceCount("other") > 0 {
                Text("\(sourceCount("other")) other files will be copied unchanged.").font(.caption)
                  .foregroundStyle(Palette.secondary)
              }
            }
            field("Quality") {
              Picker("Quality preset", selection: $preset) {
                Text("High quality").tag("high")
                Text("Smaller files").tag("small")
                Text("Custom").tag("custom")
              }.pickerStyle(.segmented).labelsHidden().onChange(of: preset) { applyPreset() }
              Text(
                preset == "small"
                  ? "Images up to 2048 px · video up to 1080p · compact audio"
                  : preset == "high"
                    ? "Original dimensions · high quality encoding · no upscaling"
                    : "Set the controls below. Aspect ratios are always preserved."
              ).font(.caption).foregroundStyle(Palette.secondary)
              DisclosureGroup("Detailed controls", isExpanded: $details) {
                advanced.padding(.top, 12)
              }
            }
          }
          HStack(alignment: .top, spacing: 28) {
            field("Folders") {
              Picker("Folder layout", selection: settings.preserve_paths) {
                Text("Flatten into one folder").tag(false)
                Text("Preserve source paths").tag(true)
              }.labelsHidden().frame(maxWidth: .infinity)
            }
            field("Name conflicts") {
              Picker("Conflict handling", selection: settings.conflict) {
                Text("Generate unique names").tag("unique")
                Text("Skip existing files").tag("skip")
                Text("Replace existing files").tag("replace")
              }.labelsHidden().frame(maxWidth: .infinity)
            }
          }
          field("Filenames") {
            HStack {
              Picker("Filenames", selection: settings.sequence) {
                Text("Original filenames").tag(false)
                Text("Prefix + sequence").tag(true)
              }.labelsHidden().frame(width: 220)
              if model.exportSettings.sequence {
                TextField("Prefix", text: settings.prefix).textFieldStyle(.roundedBorder)
                  .accessibilityLabel("Filename prefix")
              }
            }
            if model.exportSettings.sequence {
              Text((plan["sample_names"] as? [String] ?? []).joined(separator: "   ·   ")).font(
                .caption.monospaced()
              ).foregroundStyle(Palette.secondary).lineLimit(2)
            }
          }
          Toggle("Export one file per exact duplicate group", isOn: settings.deduplicate).font(
            .system(size: 12))
          if model.exportSettings.deduplicate {
            Text(
              "Contents will be checked and verified before any files are written. The final count may be lower."
            ).font(.caption).foregroundStyle(Palette.secondary).padding(.top, -14)
          }
          if model.exportSettings.conflict == "replace" {
            Label(
              "Existing destination files will be replaced. Original source files are always protected.",
              systemImage: "exclamationmark.triangle"
            ).font(.caption).foregroundStyle(Palette.amber)
          }
          if !model.exportSettings.originals {
            Text(conversionNote).font(.system(size: 11)).foregroundStyle(Palette.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.padding(28)
      }
      Divider()
      VStack(alignment: .leading, spacing: 13) {
        Text(summary).font(.system(size: 12, weight: .medium)).fixedSize(
          horizontal: false, vertical: true)
        Text(
          "\(model.exportSettings.preserve_paths ? "Source paths" : "Flat folder") · \(model.exportSettings.sequence ? "Prefix + sequence" : "Original filenames") · \(model.exportSettings.conflict == "unique" ? "Unique names on conflict" : model.exportSettings.conflict == "skip" ? "Skip existing files" : "Replace existing files")"
        ).font(.system(size: 11)).foregroundStyle(Palette.secondary)
        HStack {
          Text(
            "\(sizeText((plan["bytes"] as? NSNumber)?.uint64Value ?? 0)) of source files\(model.exportSettings.originals ? "" : " · output size varies")"
          ).font(.system(size: 10.5)).foregroundStyle(Palette.secondary)
          Spacer()
          Button("Cancel") { model.exportVisible = false }.keyboardShortcut(.cancelAction)
          Button(model.exportSettings.originals ? "Copy \(count) files" : "Start export") {
            let response = model.send("export", ["settings": model.exportSettings.json])
            if response["error"] == nil {
              model.showingReport = true
              model.poll()
            }
          }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(
              count == 0 || model.exportSettings.destination.isEmpty
                || (model.scanning && model.exportSettings.all_matching))
        }
      }.padding(.horizontal, 28).padding(.vertical, 21)
    }.frame(width: 720, height: 760).background(Palette.background).tint(Palette.amber)
      .onAppear { updatePlan() }
      .onChange(of: model.exportSettings) { updatePlan() }
      .onChange(of: model.exportSettings.image) {
        if model.exportSettings.image == "jpeg" && model.exportSettings.transparency == "preserve" {
          model.exportSettings.transparency = "white"
        }
      }
  }
  @ViewBuilder func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 9) {
      Text(title).font(.system(size: 12, weight: .semibold))
      content()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  func formatRow(
    _ title: String, count: Int, selection: Binding<String>, formats: [(String, String)]
  ) -> some View {
    HStack {
      Text(title).frame(width: 62, alignment: .leading)
      Text("\(count)").foregroundStyle(Palette.secondary).monospacedDigit()
      Spacer()
      Image(systemName: "arrow.right").foregroundStyle(.tertiary)
      Picker(title + " output", selection: selection) {
        Text("Keep original").tag("original")
        ForEach(formats, id: \.1) { Text($0.0).tag($0.1) }
        Divider()
        Text("Exclude from export").tag("exclude")
      }.labelsHidden().frame(width: 205)
    }.font(.system(size: 12)).padding(.vertical, 3).opacity(count == 0 ? 0.5 : 1).disabled(
      count == 0)
  }
  var advanced: some View {
    VStack(alignment: .leading, spacing: 16) {
      if sourceCount("image") > 0 && !["original", "exclude"].contains(model.exportSettings.image) {
        Text("Images").font(.caption.bold())
        if model.exportSettings.image != "png" {
          HStack {
            Text("Quality")
            Slider(
              value: Binding(
                get: { Double(model.exportSettings.image_quality) },
                set: { model.exportSettings.image_quality = Int($0) }), in: 1...100, step: 1)
            Text("\(model.exportSettings.image_quality)").monospacedDigit().frame(width: 26)
          }
        }
        HStack {
          Text("Longest edge")
          Spacer()
          Picker("Maximum image dimension", selection: settings.max_dimension) {
            Text("Original dimensions").tag(0)
            Text("1280 px").tag(1280)
            Text("2048 px").tag(2048)
            Text("4096 px").tag(4096)
            Text("8192 px").tag(8192)
          }.labelsHidden().frame(width: 205)
        }
        HStack {
          Text("Transparency")
          Spacer()
          Picker("Transparency", selection: settings.transparency) {
            if model.exportSettings.image != "jpeg" { Text("Preserve").tag("preserve") }
            Text("White background").tag("white")
            Text("Black background").tag("black")
          }.labelsHidden().frame(width: 205)
        }
        Text("Aspect ratio preserved. Smaller images are never enlarged.").font(.caption)
          .foregroundStyle(Palette.secondary)
      }
      if sourceCount("video") > 0 && !["original", "exclude"].contains(model.exportSettings.video) {
        Text("Video").font(.caption.bold())
        if model.exportSettings.video == "mp4" {
          HStack {
            Text("Video bitrate")
            Spacer()
            Picker("Video bitrate", selection: settings.video_bitrate) {
              Text("3 Mbps").tag(3000)
              Text("8 Mbps").tag(8000)
              Text("15 Mbps").tag(15000)
              Text("30 Mbps").tag(30000)
            }.labelsHidden().frame(width: 205)
          }
        } else {
          HStack {
            Text("Compression (CRF)")
            Slider(
              value: Binding(
                get: { Double(model.exportSettings.video_crf) },
                set: { model.exportSettings.video_crf = Int($0) }), in: 15...45, step: 1)
            Text("\(model.exportSettings.video_crf)").monospacedDigit()
          }
          Text("Lower values retain more detail and produce larger files.").font(.caption)
            .foregroundStyle(Palette.secondary)
        }
        HStack {
          Text("Maximum height")
          Spacer()
          Picker("Video resolution", selection: settings.video_height) {
            Text("Original resolution").tag(0)
            Text("720p").tag(720)
            Text("1080p").tag(1080)
            Text("2160p").tag(2160)
          }.labelsHidden().frame(width: 205)
        }
        HStack {
          Text("Frame rate")
          Spacer()
          Picker("Frame rate", selection: settings.frame_rate) {
            Text("Original frame rate").tag(0)
            Text("24 fps").tag(24)
            Text("25 fps").tag(25)
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
          }.labelsHidden().frame(width: 205)
        }
        Toggle("Retain audio", isOn: settings.retain_audio)
      }
      if sourceCount("audio") > 0 && !["original", "exclude"].contains(model.exportSettings.audio) {
        Text("Audio").font(.caption.bold())
        if ["mp3", "m4a"].contains(model.exportSettings.audio) {
          HStack {
            Text("Bitrate")
            Spacer()
            Picker("Audio bitrate", selection: settings.audio_bitrate) {
              Text("128 kbps").tag(128)
              Text("160 kbps").tag(160)
              Text("192 kbps").tag(192)
              Text("256 kbps").tag(256)
              Text("320 kbps").tag(320)
            }.labelsHidden().frame(width: 205)
          }
        }
        HStack {
          Text("Sample rate")
          Spacer()
          Picker("Sample rate", selection: settings.sample_rate) {
            Text("Original sample rate").tag(0)
            Text("44.1 kHz").tag(44100)
            Text("48 kHz").tag(48000)
            Text("96 kHz").tag(96000)
          }.labelsHidden().frame(width: 205)
        }
        HStack {
          Text("Channels")
          Spacer()
          Picker("Audio channels", selection: settings.channels) {
            Text("Original channels").tag(0)
            Text("Mono").tag(1)
            Text("Stereo").tag(2)
          }.labelsHidden().frame(width: 205)
        }
      }
      Toggle("Keep metadata where supported (may include location)", isOn: settings.metadata)
    }.font(.system(size: 12))
  }
  var conversionNote: String {
    var notes: [String] = []
    if sourceCount("image") > 0 && !["original", "exclude"].contains(model.exportSettings.image) {
      notes.append(
        "Images use the first frame and 8-bit sRGB. Animation, HDR and some colour or camera metadata are not retained."
      )
      if model.exportSettings.image == "jpeg" {
        notes.append("JPEG flattens transparency onto the chosen background.")
      }
    }
    if sourceCount("video") > 0 && !["original", "exclude"].contains(model.exportSettings.video) {
      notes.append(
        "Video is re-encoded to 8-bit output; HDR is not preserved. Subtitles, chapters and extra audio tracks are omitted."
      )
    }
    if sourceCount("audio") > 0 && model.exportSettings.audio == "wav" {
      notes.append("WAV uses 16-bit PCM.")
    }
    if !model.exportSettings.metadata {
      notes.append("Conversion metadata is removed. Copies of originals stay unchanged.")
    }
    return notes.joined(separator: " ")
  }
  var summary: String {
    let types = [
      ("images", "image", model.exportSettings.image),
      ("videos", "video", model.exportSettings.video),
      ("audio", "audio file", model.exportSettings.audio), ("other", "other file", "original"),
    ].compactMap { key, label, format -> String? in
      guard let n = plan[key] as? Int, n > 0 else { return nil }
      return
        "\(n) \(label)\(n == 1 ? "" : "s") → \(model.exportSettings.originals || format == "original" ? "original" : format.uppercased())"
    }
    return (model.exportSettings.deduplicate ? "Up to " : "") + "\(count) files · "
      + types.joined(separator: " · ")
      + ((plan["excluded"] as? Int ?? 0) > 0 ? " · \(plan["excluded"]!) excluded" : "")
  }
  func updatePlan() {
    plan = model.send("export_plan", ["settings": model.exportSettings.json])
    var options = model.exportSettings
    options.originals = true
    sourcePlan = model.send("export_plan", ["settings": options.json], displayError: false)
  }
  func sourceCount(_ kind: String) -> Int {
    // Scope counts must include rows currently excluded, including hidden selected files.
    return sourcePlan[kind == "image" ? "images" : kind == "video" ? "videos" : kind] as? Int ?? 0
  }
  func chooseDestination() {
    let panel = NSOpenPanel()
    panel.title = "Choose export destination"
    panel.prompt = "Use this folder"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url { model.exportSettings.destination = url.path }
  }
  func applyPreset() {
    if preset == "custom" {
      details = true
      return
    }
    let small = preset == "small"
    model.exportSettings.image_quality = small ? 80 : 88
    model.exportSettings.max_dimension = small ? 2048 : 0
    model.exportSettings.video_bitrate = small ? 3000 : 8000
    model.exportSettings.video_crf = small ? 34 : 25
    model.exportSettings.video_height = small ? 1080 : 0
    model.exportSettings.audio_bitrate = small ? 160 : 256
  }
}

struct ExportProgressView: View {
  @ObservedObject var model: LibraryModel
  var report: ExportReport { model.report }
  var body: some View {
    VStack(alignment: .leading, spacing: 23) {
      HStack {
        BrandMark(size: 40)
        Spacer()
        if !report.running {
          Image(
            systemName: report.failed > 0
              ? "exclamationmark.circle" : report.cancelled ? "stop.circle" : "checkmark.circle"
          ).font(.system(size: 29, weight: .light)).foregroundStyle(Palette.amber)
        }
      }
      VStack(alignment: .leading, spacing: 9) {
        Text(
          report.running
            ? "Gathering your files…"
            : report.cancelled
              ? "Stopped safely."
              : report.failed > 0 ? "Some files need attention." : "All gathered."
        ).font(.system(size: 31, design: .serif))
        Text(report.stage).font(.system(size: 12)).foregroundStyle(Palette.secondary)
      }
      if report.running {
        VStack(alignment: .leading, spacing: 12) {
          if report.stage.contains("duplicates") {
            ProgressView().progressViewStyle(.linear)
          } else {
            ProgressView(value: Double(report.completed), total: Double(max(1, report.total)))
          }
          HStack {
            Text(report.current).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("\(report.completed) / \(report.total)").monospacedDigit()
          }.font(.caption)
        }
      } else {
        HStack(spacing: 24) {
          result("Copied", report.copied)
          result("Converted", report.converted)
          result("Skipped", report.skipped)
          result("Failed", report.failed)
        }
        if report.cancelled {
          Text("Completed files were kept. No unfinished files were left in the destination.").font(
            .caption
          ).foregroundStyle(Palette.secondary)
        }
      }
      Text(report.destination).font(.system(size: 11)).foregroundStyle(Palette.secondary).lineLimit(
        2
      ).textSelection(.enabled)
      if !report.errors.isEmpty {
        ScrollView {
          Text(report.errors.joined(separator: "\n\n")).font(.system(size: 11)).textSelection(
            .enabled
          ).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 155)
      }
      HStack {
        if report.running {
          Button("Cancel export", role: .destructive) { model.send("cancel_export") }
          Spacer()
          Button("Keep browsing") { model.exportVisible = false }
        } else {
          Button("Open destination", systemImage: "folder") {
            NSWorkspace.shared.open(URL(fileURLWithPath: report.destination))
          }
          Spacer()
          Button("Done") {
            model.exportVisible = false
            model.send("dismiss_report")
            model.poll()
          }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      }
    }.padding(32).frame(width: 590).background(Palette.background).tint(Palette.amber)
      .interactiveDismissDisabled(report.running)
  }
  func result(_ title: String, _ count: Int) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("\(count)").font(.system(size: 26, design: .serif)).monospacedDigit()
      Text(title).font(.caption).foregroundStyle(Palette.secondary)
    }
  }
}
