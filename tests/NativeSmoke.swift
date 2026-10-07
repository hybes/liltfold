import CryptoKit
import Foundation

@main struct NativeSmoke {
  static func command(_ action: String, _ values: [String: Any] = [:]) -> [String: Any] {
    var value = values
    value["action"] = action
    let data = try! JSONSerialization.data(withJSONObject: value)
    return String(data: data, encoding: .utf8)!.withCString { p in
      let result = lilt_command(p)!
      defer { lilt_free(result) }
      let object =
        try! JSONSerialization.jsonObject(with: Data(String(cString: result).utf8))
        as! [String: Any]
      precondition(object["error"] == nil, "Command failed: \(object)")
      return object
    }
  }
  static func wait(_ predicate: ([String: Any]) -> Bool) -> [String: Any] {
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let state = command("poll")
      if predicate(state) { return state }
      Thread.sleep(forTimeInterval: 0.03)
    }
    fatalError("Timed out waiting for native engine")
  }
  static func process(_ executable: URL, _ args: [String]) -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    precondition(process.terminationStatus == 0, "Process failed: \(args)")
    return data
  }
  static func main() {
    precondition(CommandLine.arguments.count == 4, "NativeSmoke BUNDLE FIXTURES OUTPUT")
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    let tools = app.appendingPathComponent("Contents/Resources/bin")
    let cache = output.appendingPathComponent("cache")
    try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    cache.path.withCString { c in tools.path.withCString { t in lilt_init(c, t, nativeImage) } }
    _ = command(
      "add_roots", ["paths": [root.path, root.appendingPathComponent("01 · Still").path]])
    let state = wait { $0["scanning"] as? Bool == false }
    let items = state["items"] as! [[String: Any]]
    let allPaths = items.map { URL(fileURLWithPath: $0["path"] as! String) }
    let originals = Dictionary(
      uniqueKeysWithValues: allPaths.map {
        ($0.path, SHA256.hash(data: try! Data(contentsOf: $0)).description)
      })
    _ = command("thumbnails", ["ids": items.map { $0["id"]! }])
    _ = wait { state in
      let items = state["items"] as! [[String: Any]]
      return items.allSatisfy {
        $0["thumbnail"] is String || !(($0["waveform"] as? [Double]) ?? []).isEmpty
          || $0["error"] is String
      }
    }
    var results: [[String: Any]] = []
    let cases: [(String, [String], [String])] = [
      ("image", ["jpg", "png", "heic", "webp", "tiff", "gif"], ["webp", "jpeg", "png"]),
      ("video", ["mp4", "mov", "webm"], ["mp4", "webm"]),
      ("audio", ["mp3", "m4a", "wav", "flac"], ["mp3", "m4a", "wav", "flac"]),
    ]
    for (kind, inputs, formats) in cases {
      for ext in inputs {
        let item = items.first {
          ($0["path"] as! String).lowercased().hasSuffix("." + ext)
            && !($0["name"] as! String).contains("Unreadable")
        }!
        for format in formats {
          _ = command("selection", ["ids": [item["id"]!]])
          let destination = output.appendingPathComponent("\(ext)-to-\(format)")
          try! FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
          var options: [String: Any] = [
            "originals": false, "destination": destination.path, "image": "exclude",
            "video": "exclude", "audio": "exclude", "transparency": "white", "max_dimension": 600,
            "video_height": 360, "sample_rate": 44100, "channels": 1,
          ]
          options[kind] = format
          _ = command("export", ["settings": options])
          let finished = wait { ($0["report"] as? [String: Any])?["running"] as? Bool == false }
          let report = finished["report"] as! [String: Any]
          precondition(
            report["failed"] as? Int == 0 && report["converted"] as? Int == 1,
            "Conversion failed: \(report)")
          let path = (report["outputs"] as! [String])[0]
          let probe = process(
            tools.appendingPathComponent("ffprobe"),
            ["-v", "error", "-show_streams", "-show_format", "-of", "json", path])
          let info = try! JSONSerialization.jsonObject(with: probe) as! [String: Any]
          let streams = info["streams"] as! [[String: Any]]
          if kind == "image" {
            let video = streams.first { $0["codec_type"] as? String == "video" }!
            precondition(max(video["width"] as! Int, video["height"] as! Int) <= 600)
          }
          if kind == "video" {
            let video = streams.first { $0["codec_type"] as? String == "video" }!
            precondition((video["height"] as! Int) <= 360)
            precondition(streams.contains { $0["codec_type"] as? String == "audio" })
          }
          if kind != "image" {
            let duration = Double((info["format"] as! [String: Any])["duration"] as! String)!
            precondition(abs(duration - (kind == "video" ? 4 : 8)) < 0.2)
          }
          if kind == "audio" {
            precondition(streams[0]["channels"] as? Int == 1)
            precondition(streams[0]["sample_rate"] as? String == "44100")
          }
          _ = process(
            tools.appendingPathComponent("ffmpeg"),
            ["-v", "error", "-threads", "1", "-i", path, "-f", "null", "-"])
          results.append([
            "input": ext, "output": format, "verified": true, "streams": streams, "file": path,
          ])
          print("PASS \(ext) → \(format)")
          fflush(stdout)
        }
      }
    }
    let corrupt = items.first { ($0["name"] as! String).contains("Unreadable") }!
    _ = command("selection", ["ids": [corrupt["id"]!]])
    _ = command(
      "export", ["settings": ["originals": false, "destination": output.path, "image": "png"]])
    let failed = wait { ($0["report"] as? [String: Any])?["running"] as? Bool == false }
    precondition((failed["report"] as! [String: Any])["failed"] as? Int == 1)
    for path in allPaths {
      precondition(
        SHA256.hash(data: try! Data(contentsOf: path)).description == originals[path.path],
        "Original changed")
    }
    let contents =
      FileManager.default.enumerator(at: output, includingPropertiesForKeys: nil)!.allObjects
      as! [URL]
    precondition(
      !contents.contains { $0.lastPathComponent.hasPrefix(".liltfold-") },
      "Unfinished output left behind")
    try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("results.json"))
    print(
      "PASS \(results.count) conversions, corrupt-file failure, recursive/overlapping roots and unchanged original hashes"
    )
  }
}
