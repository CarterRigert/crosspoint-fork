import Darwin
import Foundation

enum DeviceManager {
  enum DeviceError: LocalizedError {
    case noDevice
    case firmwareMissing
    case flashHelperMissing
    case incompatiblePython
    case serialOpenFailed(String)
    case serialConfigureFailed
    case serialWriteFailed
    case commandRejected(String)
    case commandTimedOut(String)
    case flashFailed(String)

    var errorDescription: String? {
      switch self {
      case .noDevice:
        return "No X4 USB serial device found."
      case .firmwareMissing:
        return "Bundled firmware.bin was not found."
      case .flashHelperMissing:
        return "No compatible esptool helper found. Install Python 3.10+ with esptool, or rebuild the app bundle."
      case .incompatiblePython:
        return "A bundled esptool helper exists, but no Python 3.10+ executable was found."
      case .serialOpenFailed(let path):
        return "Could not open \(path)."
      case .serialConfigureFailed:
        return "Could not configure the USB serial connection."
      case .serialWriteFailed:
        return "Could not write to the USB serial connection."
      case .commandRejected(let message):
        return message
      case .commandTimedOut(let output):
        return output.isEmpty ? "Timed out waiting for the X4 to accept the sync URL." : "Timed out: \(output)"
      case .flashFailed(let output):
        return output.isEmpty ? "Firmware flash failed." : output
      }
    }
  }

  static func serialPorts() -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
    return entries
      .filter { $0.hasPrefix("cu.usbmodem") }
      .sorted()
      .map { "/dev/\($0)" }
  }

  static func firstSerialPort() throws -> String {
    guard let port = serialPorts().first else { throw DeviceError.noDevice }
    return port
  }

  static func bundledFirmwareURL() throws -> URL {
    let fileManager = FileManager.default
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("firmware.bin"),
       fileManager.fileExists(atPath: resourceURL.path) {
      return resourceURL
    }

    let bundleRelative = repoRootFromDevBundle().appendingPathComponent("dist/firmware.bin")
    if fileManager.fileExists(atPath: bundleRelative.path) {
      return bundleRelative
    }

    let cwdRelative = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent("dist/firmware.bin")
    if fileManager.fileExists(atPath: cwdRelative.path) {
      return cwdRelative
    }

    throw DeviceError.firmwareMissing
  }

  static func pushSyncURL(_ syncURL: String, port explicitPort: String? = nil) throws -> String {
    let port = try explicitPort ?? firstSerialPort()
    if syncURL.contains("\n") || syncURL.utf8.count >= 120 {
      throw DeviceError.commandRejected("Sync URL is too long for the X4 setting.")
    }

    let fd = open(port, O_RDWR | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else { throw DeviceError.serialOpenFailed(port) }
    defer { close(fd) }

    var options = termios()
    guard tcgetattr(fd, &options) == 0 else { throw DeviceError.serialConfigureFailed }
    cfmakeraw(&options)
    cfsetspeed(&options, speed_t(B115200))
    options.c_cflag |= tcflag_t(CLOCAL | CREAD)
    guard tcsetattr(fd, TCSANOW, &options) == 0 else { throw DeviceError.serialConfigureFailed }

    let command = "CMD:SET_SYNC_URL \(syncURL)\n"
    let bytes = Array(command.utf8)
    let written = bytes.withUnsafeBytes { ptr in
      Darwin.write(fd, ptr.baseAddress, bytes.count)
    }
    guard written == bytes.count else { throw DeviceError.serialWriteFailed }
    tcdrain(fd)

    var output = ""
    let deadline = Date().addingTimeInterval(4)
    var buffer = [UInt8](repeating: 0, count: 512)
    let bufferSize = buffer.count
    while Date() < deadline {
      let count = buffer.withUnsafeMutableBytes { ptr in
        Darwin.read(fd, ptr.baseAddress, bufferSize)
      }
      if count > 0 {
        output += String(decoding: buffer.prefix(count), as: UTF8.self)
        if output.contains("OK:SET_SYNC_URL") {
          return "Pushed sync URL to \(port)."
        }
        if let line = output.split(separator: "\n").first(where: { $0.contains("ERR:SET_SYNC_URL") }) {
          throw DeviceError.commandRejected(String(line))
        }
      } else {
        usleep(50_000)
      }
    }

    throw DeviceError.commandTimedOut(output.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  static func flashFirmware(port explicitPort: String? = nil, firmwareURL explicitFirmwareURL: URL? = nil) throws -> String {
    let port = try explicitPort ?? firstSerialPort()
    let firmwareURL = try explicitFirmwareURL ?? bundledFirmwareURL()
    let helper = try flashHelper()

    let process = Process()
    switch helper {
    case .python(let pythonURL, let pythonPath):
      process.executableURL = pythonURL
      process.arguments = [
        "-m", "esptool",
        "--chip", "esp32c3",
        "--port", port,
        "--baud", "921600",
        "--before", "default-reset",
        "--after", "hard-reset",
        "write-flash",
        "-z",
        "--flash-mode", "dio",
        "--flash-freq", "80m",
        "--flash-size", "16MB",
        "0x10000",
        firmwareURL.path
      ]
      process.environment = mergedEnvironment(extra: [
        "PYTHONPATH": pythonPath,
        "PYTHONUNBUFFERED": "1"
      ])
    case .esptool(let esptoolURL):
      process.executableURL = esptoolURL
      process.arguments = [
        "--chip", "esp32c3",
        "--port", port,
        "--baud", "921600",
        "--before", "default-reset",
        "--after", "hard-reset",
        "write-flash",
        "-z",
        "--flash-mode", "dio",
        "--flash-freq", "80m",
        "--flash-size", "16MB",
        "0x10000",
        firmwareURL.path
      ]
      process.environment = mergedEnvironment()
    }

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
      throw DeviceError.flashFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return "Flashed \(firmwareURL.lastPathComponent) to \(port)."
  }

  private enum FlashHelper {
    case python(URL, String)
    case esptool(URL)
  }

  private static func flashHelper() throws -> FlashHelper {
    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("python/esptool"),
       FileManager.default.fileExists(atPath: resourceURL.path),
       let pythonURL = compatiblePythonExecutable() {
      return .python(pythonURL, resourceURL.deletingLastPathComponent().path)
    }

    if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("python/esptool"),
       FileManager.default.fileExists(atPath: resourceURL.path) {
      if let esptool = executableInPath("esptool") {
        return .esptool(esptool)
      }
      throw DeviceError.incompatiblePython
    }

    if let esptool = executableInPath("esptool") {
      return .esptool(esptool)
    }

    throw DeviceError.flashHelperMissing
  }

  private static func compatiblePythonExecutable() -> URL? {
    let candidates = [
      repoRootFromDevBundle().appendingPathComponent(".venv/bin/python").path,
      "/opt/homebrew/bin/python3",
      "/usr/local/bin/python3",
      "/usr/bin/python3"
    ]

    return candidates
      .map { URL(fileURLWithPath: $0) }
      .first { isCompatiblePython($0) }
  }

  private static func isCompatiblePython(_ url: URL) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
    let process = Process()
    process.executableURL = url
    process.arguments = ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else { return false }
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let parts = version.split(separator: ".").compactMap { Int($0) }
      return parts.count == 2 && (parts[0] > 3 || (parts[0] == 3 && parts[1] >= 10))
    } catch {
      return false
    }
  }

  private static func executableInPath(_ name: String) -> URL? {
    let path = mergedEnvironment()["PATH"] ?? ""
    for directory in path.split(separator: ":") {
      let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: url.path) {
        return url
      }
    }
    return nil
  }

  private static func mergedEnvironment(extra: [String: String] = [:]) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/opt/local/bin"
    if let existing = environment["PATH"], !existing.isEmpty {
      environment["PATH"] = "\(standardPath):\(existing)"
    } else {
      environment["PATH"] = standardPath
    }
    for (key, value) in extra {
      environment[key] = value
    }
    return environment
  }

  private static func repoRootFromDevBundle() -> URL {
    Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}
