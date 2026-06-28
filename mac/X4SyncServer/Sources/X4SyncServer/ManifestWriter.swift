import Foundation
import CryptoKit

struct ManifestEntry: Codable {
  let path: String
  let urlPath: String
}

enum ManifestWriter {
  private struct FileEntry: Codable {
    let path: String
    let url: String
    let sha256: String
    let size: Int64
    let deleteFirst: Bool
  }

  private struct Manifest: Codable {
    let updated: String
    let files: [FileEntry]
  }

  static func write(entries: [ManifestEntry], serverURL: String, outputURL: URL) throws {
    let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let rootDirectory = outputURL.deletingLastPathComponent()
    let files = entries.map { entry in
      let urlPath = entry.urlPath.hasPrefix("/") ? entry.urlPath : "/" + entry.urlPath
      let fileURL = rootDirectory.appendingPathComponent(String(urlPath.drop(while: { $0 == "/" })))
      return FileEntry(
        path: entry.path,
        url: base + urlPath,
        sha256: sha256Hex(fileURL),
        size: fileSize(fileURL),
        deleteFirst: true
      )
    }

    let manifest = Manifest(updated: ISO8601DateFormatter().string(from: Date()), files: files)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: outputURL, options: .atomic)
  }

  private static func sha256Hex(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url) else { return "" }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func fileSize(_ url: URL) -> Int64 {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber
    else {
      return 0
    }
    return size.int64Value
  }
}
