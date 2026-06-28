import Foundation

struct ManifestEntry: Codable {
  let path: String
  let urlPath: String
}

enum ManifestWriter {
  private struct FileEntry: Codable {
    let path: String
    let url: String
    let sha256: String
  }

  private struct Manifest: Codable {
    let updated: String
    let files: [FileEntry]
  }

  static func write(entries: [ManifestEntry], serverURL: String, outputURL: URL) throws {
    let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let files = entries.map { entry in
      let urlPath = entry.urlPath.hasPrefix("/") ? entry.urlPath : "/" + entry.urlPath
      return FileEntry(path: entry.path, url: base + urlPath, sha256: "")
    }

    let manifest = Manifest(updated: ISO8601DateFormatter().string(from: Date()), files: files)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: outputURL, options: .atomic)
  }
}
