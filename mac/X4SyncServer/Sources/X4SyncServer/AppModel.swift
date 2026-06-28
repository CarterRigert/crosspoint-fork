import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
  @Published var serverEnabled: Bool = false
  @Published var sleepEnabled: Bool
  @Published var sleepOrientation: SleepTextOrientation
  @Published var hnEnabled: Bool
  @Published var hnIntervalMinutes: Int
  @Published var isBusy: Bool = false
  @Published var statusMessage: String = "Ready"
  @Published var lastError: String?
  @Published var serverURL: String = ""
  @Published var manifestStatus: String = "Not written"
  @Published var sleepStatus: String = "Not generated"
  @Published var hnStatus: String = "Not generated"

  let port: UInt16 = 8080

  private let defaults = UserDefaults.standard
  private let fileManager = FileManager.default
  private var server: StaticHTTPServer?
  private var hnTimer: Timer?
  private var didBootstrap = false

  private var supportDir: URL {
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base.appendingPathComponent("X4SyncServer", isDirectory: true)
  }

  var publicDir: URL {
    supportDir.appendingPathComponent("Public", isDirectory: true)
  }

  var inputsDir: URL {
    supportDir.appendingPathComponent("SleepInputs", isDirectory: true)
  }

  private var manifestURL: URL {
    publicDir.appendingPathComponent("manifest.json")
  }

  private var sleepBMPURL: URL {
    publicDir.appendingPathComponent("sleep.bmp")
  }

  private var hnEPUBURL: URL {
    publicDir.appendingPathComponent("HNLatest.epub")
  }

  init() {
    sleepEnabled = defaults.object(forKey: "sleepEnabled") as? Bool ?? true
    let storedOrientation = defaults.string(forKey: "sleepOrientation").flatMap(SleepTextOrientation.init(rawValue:))
    sleepOrientation = storedOrientation ?? .upsideDown
    hnEnabled = defaults.object(forKey: "hnEnabled") as? Bool ?? true
    let storedInterval = defaults.integer(forKey: "hnIntervalMinutes")
    hnIntervalMinutes = storedInterval == 0 ? 60 : storedInterval
  }

  func bootstrap() {
    guard !didBootstrap else { return }
    didBootstrap = true

    do {
      try prepareFolders()
      updateServerURL()
      try refreshGeneratedFilesIfNeeded()
      try refreshManifest()
      scheduleHNTimer()
      statusMessage = "Ready. Set the X4 Startup Sync URL to \(serverURL)."
      if hnEnabled && !fileManager.fileExists(atPath: hnEPUBURL.path) {
        updateHNNow()
      }
    } catch {
      showError(error)
    }
  }

  func setServerEnabled(_ enabled: Bool) {
    if enabled {
      startServer()
    } else {
      stopServer()
    }
  }

  func settingsChanged() {
    defaults.set(sleepEnabled, forKey: "sleepEnabled")
    defaults.set(sleepOrientation.rawValue, forKey: "sleepOrientation")
    defaults.set(hnEnabled, forKey: "hnEnabled")
    defaults.set(hnIntervalMinutes, forKey: "hnIntervalMinutes")
    scheduleHNTimer()

    let shouldFetchHN = hnEnabled && !fileManager.fileExists(atPath: hnEPUBURL.path)

    Task {
      do {
        if sleepEnabled && !fileManager.fileExists(atPath: sleepBMPURL.path) {
          try SleepRenderer.render(inputsDir: inputsDir, outputURL: sleepBMPURL, orientation: sleepOrientation)
        }
        try refreshManifest()
        await MainActor.run {
          statusMessage = "Settings saved."
          lastError = nil
        }
        if shouldFetchHN {
          await MainActor.run {
            self.updateHNNow()
          }
        }
      } catch {
        await MainActor.run {
          showError(error)
        }
      }
    }
  }

  func sleepOrientationChanged() {
    defaults.set(sleepOrientation.rawValue, forKey: "sleepOrientation")
    guard sleepEnabled else {
      statusMessage = "Settings saved."
      return
    }
    regenerateSleepScreen()
  }

  func regenerateSleepScreen() {
    runBusyTask("Generating sleep.bmp...") {
      try SleepRenderer.render(inputsDir: self.inputsDir, outputURL: self.sleepBMPURL, orientation: self.sleepOrientation)
      try self.refreshManifest()
      await MainActor.run {
        self.sleepStatus = self.fileStatus(self.sleepBMPURL)
        self.statusMessage = "Generated sleep.bmp."
      }
    }
  }

  func updateHNNow() {
    runBusyTask("Fetching Hacker News...") {
      let stories = try await HNClient().frontPageStories(limit: 12, commentsPerStory: 4)
      try EpubBuilder.buildHNLatest(stories: stories, outputURL: self.hnEPUBURL)
      try self.refreshManifest()
      await MainActor.run {
        self.hnStatus = self.fileStatus(self.hnEPUBURL)
        self.statusMessage = "Updated HNLatest.epub."
      }
    }
  }

  func copyServerURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(serverURL, forType: .string)
    statusMessage = "Copied server URL."
  }

  func openInputsFolder() {
    NSWorkspace.shared.open(inputsDir)
  }

  func openPublicFolder() {
    NSWorkspace.shared.open(publicDir)
  }

  private func startServer() {
    do {
      try prepareFolders()
      updateServerURL()
      try refreshManifest()
      let nextServer = StaticHTTPServer(rootDirectory: publicDir, port: port)
      try nextServer.start()
      server = nextServer
      serverEnabled = true
      statusMessage = "Server running at \(serverURL)."
      lastError = nil
    } catch {
      serverEnabled = false
      showError(error)
    }
  }

  private func stopServer() {
    server?.stop()
    server = nil
    serverEnabled = false
    statusMessage = "Server stopped."
  }

  private func prepareFolders() throws {
    try fileManager.createDirectory(at: publicDir, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: inputsDir, withIntermediateDirectories: true)
    try createDefaultInputFiles()
  }

  private func createDefaultInputFiles() throws {
    let defaults: [(String, String)] = [
      ("todos.txt", "- Review today's calendar\n- Drink water\n- Read for 20 minutes\n"),
      ("calendar.txt", "9:00 Coffee\n12:30 Lunch\n6:00 Family time\n"),
      ("weather.txt", "Weather source not connected yet\n"),
      ("notes.txt", "Edit these files, or add build_sleep_inputs.sh to generate them.\n")
    ]

    for (name, contents) in defaults {
      let url = inputsDir.appendingPathComponent(name)
      if !fileManager.fileExists(atPath: url.path) {
        try contents.write(to: url, atomically: true, encoding: .utf8)
      }
    }
  }

  private func refreshGeneratedFilesIfNeeded() throws {
    if sleepEnabled && !fileManager.fileExists(atPath: sleepBMPURL.path) {
      try SleepRenderer.render(inputsDir: inputsDir, outputURL: sleepBMPURL, orientation: sleepOrientation)
    }
    sleepStatus = fileStatus(sleepBMPURL)
    hnStatus = fileStatus(hnEPUBURL)
  }

  private func refreshManifest() throws {
    updateServerURL()
    let entries = manifestEntries()
    try ManifestWriter.write(entries: entries, serverURL: serverURL, outputURL: manifestURL)
    manifestStatus = "\(entries.count) file\(entries.count == 1 ? "" : "s")"
  }

  private func manifestEntries() -> [ManifestEntry] {
    var entries: [ManifestEntry] = []

    if sleepEnabled && fileManager.fileExists(atPath: sleepBMPURL.path) {
      entries.append(ManifestEntry(path: "/sleep.bmp", urlPath: "/sleep.bmp"))
    }

    if hnEnabled && fileManager.fileExists(atPath: hnEPUBURL.path) {
      entries.append(ManifestEntry(path: "/HNLatest.epub", urlPath: "/HNLatest.epub"))
    }

    return entries
  }

  private func scheduleHNTimer() {
    hnTimer?.invalidate()
    hnTimer = nil

    guard hnEnabled else { return }
    hnTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(hnIntervalMinutes * 60), repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.updateHNNow()
      }
    }
  }

  private func updateServerURL() {
    let ip = NetworkUtility.primaryIPv4Address() ?? "127.0.0.1"
    serverURL = "http://\(ip):\(port)"
  }

  private func fileStatus(_ url: URL) -> String {
    guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
          let size = attrs[.size] as? NSNumber
    else {
      return "Missing"
    }
    return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
  }

  private func runBusyTask(_ message: String, operation: @escaping () async throws -> Void) {
    guard !isBusy else { return }
    isBusy = true
    statusMessage = message
    lastError = nil

    Task {
      do {
        try await operation()
      } catch {
        await MainActor.run {
          self.showError(error)
        }
      }
      await MainActor.run {
        self.isBusy = false
      }
    }
  }

  private func showError(_ error: Error) {
    lastError = error.localizedDescription
    statusMessage = error.localizedDescription
  }
}
