import Foundation
import Network

final class StaticHTTPServer: @unchecked Sendable {
  enum ServerError: LocalizedError {
    case invalidPort

    var errorDescription: String? {
      switch self {
      case .invalidPort:
        "Invalid server port."
      }
    }
  }

  private let rootDirectory: URL
  private let port: UInt16
  private let queue = DispatchQueue(label: "X4SyncServer.HTTPServer")
  private var listener: NWListener?

  init(rootDirectory: URL, port: UInt16) {
    self.rootDirectory = rootDirectory
    self.port = port
  }

  func start() throws {
    guard listener == nil else { return }
    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw ServerError.invalidPort
    }

    let listener = try NWListener(using: .tcp, on: nwPort)
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection)
    }
    listener.start(queue: queue)
    self.listener = listener
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
      guard let self else {
        connection.cancel()
        return
      }

      let response = self.response(for: data ?? Data())
      connection.send(content: response, completion: .contentProcessed { _ in
        connection.cancel()
      })
    }
  }

  private func response(for data: Data) -> Data {
    guard let request = String(data: data, encoding: .utf8),
          let firstLine = request.split(separator: "\r\n").first
    else {
      return httpResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8))
    }

    let parts = firstLine.split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET" else {
      return httpResponse(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("Only GET is supported".utf8))
    }

    let rawPath = String(parts[1])
    let path = sanitize(rawPath)
    guard !path.isEmpty else {
      return httpResponse(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8))
    }

    let fileURL = rootDirectory.appendingPathComponent(path, isDirectory: false)
    guard fileURL.path.hasPrefix(rootDirectory.path),
          let fileData = try? Data(contentsOf: fileURL)
    else {
      return httpResponse(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8))
    }

    return httpResponse(status: "200 OK", contentType: contentType(for: fileURL), body: fileData)
  }

  private func sanitize(_ rawPath: String) -> String {
    let noQuery = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
    let decoded = noQuery.removingPercentEncoding ?? noQuery
    let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    if trimmed.isEmpty || trimmed.contains("..") || trimmed.contains("\\") {
      return trimmed.isEmpty ? "manifest.json" : ""
    }
    return trimmed
  }

  private func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "json":
      return "application/json"
    case "bmp":
      return "image/bmp"
    case "epub":
      return "application/epub+zip"
    case "txt":
      return "text/plain; charset=utf-8"
    default:
      return "application/octet-stream"
    }
  }

  private func httpResponse(status: String, contentType: String, body: Data) -> Data {
    var header = ""
    header += "HTTP/1.1 \(status)\r\n"
    header += "Content-Type: \(contentType)\r\n"
    header += "Content-Length: \(body.count)\r\n"
    header += "Connection: close\r\n"
    header += "Access-Control-Allow-Origin: *\r\n"
    header += "\r\n"

    var data = Data(header.utf8)
    data.append(body)
    return data
  }
}
