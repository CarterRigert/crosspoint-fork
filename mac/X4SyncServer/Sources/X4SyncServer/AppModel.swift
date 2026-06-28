import AppKit
import Foundation
import IOKit.pwr_mgt
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
  @Published var serverEnabled: Bool
  @Published var keepAwakeEnabled: Bool
  @Published var launchAtLoginEnabled: Bool
  @Published var sleepEnabled: Bool
  @Published var sleepOrientation: SleepTextOrientation
  @Published var sleepWeatherEnabled: Bool
  @Published var sleepCalendarEnabled: Bool
  @Published var sleepTodoEnabled: Bool
  @Published var sleepNotesEnabled: Bool
  @Published var sleepHNEnabled: Bool
  @Published var sleepRegenerateTimerEnabled: Bool
  @Published var sleepRegenerateIntervalMinutes: Int
  @Published var hnEnabled: Bool
  @Published var hnIntervalMinutes: Int
  @Published var isBusy: Bool = false
  @Published var statusMessage: String = "Ready"
  @Published var lastError: String?
  @Published var serverURL: String = ""
  @Published var manifestStatus: String = "Not written"
  @Published var sleepStatus: String = "Not generated"
  @Published var sleepRegenerationStatus: String = "No trigger yet"
  @Published var hnStatus: String = "Not generated"
  @Published var lastRequestStatus: String = "No requests yet"
  @Published var devicePort: String?
  @Published var deviceStatus: String = "No USB device detected"

  let port: UInt16 = 8080

  private let defaults = UserDefaults.standard
  private let fileManager = FileManager.default
  private var server: StaticHTTPServer?
  private var hnTimer: Timer?
  private var sleepTimer: Timer?
  private var didBootstrap = false
  private var keepAwakeAssertionID = IOPMAssertionID(0)
  private var pendingSleepRegenerationSource: String?

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

  private var sleepHNInputURL: URL {
    inputsDir.appendingPathComponent("hn.txt")
  }

  private var sleepSections: SleepRenderSections {
    SleepRenderSections(
      weather: sleepWeatherEnabled,
      calendar: sleepCalendarEnabled,
      todo: sleepTodoEnabled,
      notes: sleepNotesEnabled,
      hn: sleepHNEnabled
    )
  }

  var sleepTriggerURL: String {
    "\(serverURL)/api/regenerate-sleep"
  }

  init() {
    serverEnabled = defaults.object(forKey: "serverEnabled") as? Bool ?? false
    keepAwakeEnabled = defaults.object(forKey: "keepAwakeEnabled") as? Bool ?? false
    launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    sleepEnabled = defaults.object(forKey: "sleepEnabled") as? Bool ?? true
    let storedOrientation = defaults.string(forKey: "sleepOrientation").flatMap(SleepTextOrientation.init(rawValue:))
    sleepOrientation = storedOrientation ?? .upsideDown
    sleepWeatherEnabled = defaults.object(forKey: "sleepWeatherEnabled") as? Bool ?? true
    sleepCalendarEnabled = defaults.object(forKey: "sleepCalendarEnabled") as? Bool ?? true
    sleepTodoEnabled = defaults.object(forKey: "sleepTodoEnabled") as? Bool ?? true
    sleepNotesEnabled = defaults.object(forKey: "sleepNotesEnabled") as? Bool ?? true
    sleepHNEnabled = defaults.object(forKey: "sleepHNEnabled") as? Bool ?? true
    sleepRegenerateTimerEnabled = defaults.object(forKey: "sleepRegenerateTimerEnabled") as? Bool ?? false
    let storedSleepInterval = defaults.integer(forKey: "sleepRegenerateIntervalMinutes")
    sleepRegenerateIntervalMinutes = storedSleepInterval == 0 ? 15 : storedSleepInterval
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
      refreshDeviceConnection()
      scheduleSleepTimer()
      scheduleHNTimer()
      if serverEnabled {
        startServer()
      } else {
        statusMessage = "Ready. Set the X4 Startup Sync URL to \(serverURL)."
      }
      if hnEnabled && !fileManager.fileExists(atPath: hnEPUBURL.path) {
        updateHNNow()
      }
    } catch {
      showError(error)
    }
  }

  func setServerEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: "serverEnabled")
    if enabled {
      startServer()
    } else {
      stopServer()
    }
  }

  func setKeepAwakeEnabled(_ enabled: Bool) {
    defaults.set(enabled, forKey: "keepAwakeEnabled")
    keepAwakeEnabled = enabled
    updateKeepAwakeAssertion()
  }

  func setLaunchAtLoginEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLoginEnabled = enabled
      statusMessage = enabled ? "App will launch at login." : "Launch at login disabled."
      lastError = nil
    } catch {
      launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
      showError(error)
    }
  }

  func settingsChanged() {
    defaults.set(sleepEnabled, forKey: "sleepEnabled")
    defaults.set(sleepOrientation.rawValue, forKey: "sleepOrientation")
    saveSleepSectionSettings()
    defaults.set(sleepRegenerateTimerEnabled, forKey: "sleepRegenerateTimerEnabled")
    defaults.set(sleepRegenerateIntervalMinutes, forKey: "sleepRegenerateIntervalMinutes")
    defaults.set(hnEnabled, forKey: "hnEnabled")
    defaults.set(hnIntervalMinutes, forKey: "hnIntervalMinutes")
    scheduleSleepTimer()
    scheduleHNTimer()

    let shouldFetchHN = hnEnabled && !fileManager.fileExists(atPath: hnEPUBURL.path)

    Task {
      do {
        if sleepEnabled {
          try renderSleepScreen()
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

  func sleepTimerSettingsChanged() {
    defaults.set(sleepRegenerateTimerEnabled, forKey: "sleepRegenerateTimerEnabled")
    defaults.set(sleepRegenerateIntervalMinutes, forKey: "sleepRegenerateIntervalMinutes")
    scheduleSleepTimer()
    sleepRegenerationStatus = sleepRegenerateTimerEnabled ? "Timer every \(sleepRegenerateIntervalMinutes) min" : "Timer off"
    statusMessage = "Sleep timer settings saved."
  }

  func sleepOrientationChanged() {
    defaults.set(sleepOrientation.rawValue, forKey: "sleepOrientation")
    guard sleepEnabled else {
      statusMessage = "Settings saved."
      return
    }
    regenerateSleepScreen()
  }

  func sleepSectionSettingsChanged() {
    saveSleepSectionSettings()
    guard sleepEnabled else {
      statusMessage = "Sleep section settings saved."
      return
    }
    regenerateSleepScreen()
  }

  func regenerateSleepScreen() {
    requestSleepRegeneration(source: "Manual")
  }

  func regenerateSleepScreenFromAPI() {
    requestSleepRegeneration(source: "API")
  }

  private func requestSleepRegeneration(source: String) {
    guard sleepEnabled else {
      sleepRegenerationStatus = "\(source) ignored; sleep screen off"
      statusMessage = "Sleep screen is disabled."
      return
    }

    if isBusy {
      pendingSleepRegenerationSource = source
      sleepRegenerationStatus = "\(source) queued"
      statusMessage = "Sleep regeneration queued."
      return
    }

    sleepRegenerationStatus = "\(source) running"
    runBusyTask("Generating sleep.bmp...") {
      try self.renderSleepScreen()
      try self.refreshManifest()
      await MainActor.run {
        self.sleepStatus = self.fileStatus(self.sleepBMPURL)
        self.sleepRegenerationStatus = "\(source) \(self.shortTimestamp())"
        self.statusMessage = "Generated sleep.bmp."
      }
    }
  }

  func updateHNNow() {
    runBusyTask("Fetching Hacker News...") {
      let stories = try await HNClient().frontPageStories(limit: 30, commentsPerStory: 4)
      try EpubBuilder.buildHNLatest(stories: stories, outputURL: self.hnEPUBURL)
      try self.writeSleepHNPreview(stories: stories)
      if self.sleepEnabled {
        try self.renderSleepScreen()
      }
      try self.refreshManifest()
      await MainActor.run {
        if self.sleepEnabled {
          self.sleepStatus = self.fileStatus(self.sleepBMPURL)
          self.sleepRegenerationStatus = "HN \(self.shortTimestamp())"
        }
        self.hnStatus = self.fileStatus(self.hnEPUBURL)
        self.statusMessage = self.sleepEnabled ? "Updated HNLatest.epub and sleep.bmp." : "Updated HNLatest.epub."
      }
    }
  }

  func copyServerURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(serverURL, forType: .string)
    statusMessage = "Copied server URL."
  }

  func copySleepTriggerURL() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(sleepTriggerURL, forType: .string)
    statusMessage = "Copied sleep trigger URL."
  }

  func refreshDeviceConnection() {
    let ports = DeviceManager.serialPorts()
    devicePort = ports.first
    if let port = devicePort {
      deviceStatus = ports.count == 1 ? port : "\(port) (+\(ports.count - 1) more)"
    } else {
      deviceStatus = "No USB device detected"
    }
  }

  func flashConnectedX4() {
    let alert = NSAlert()
    alert.messageText = "Flash X4 firmware?"
    alert.informativeText = "This will write the bundled firmware to the connected X4 over USB."
    alert.addButton(withTitle: "Flash")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let port = devicePort
    runBusyTask("Flashing X4 firmware...") {
      let message = try await Task.detached {
        try DeviceManager.flashFirmware(port: port)
      }.value
      await MainActor.run {
        self.statusMessage = message
        self.lastError = nil
        self.refreshDeviceConnection()
      }
    }
  }

  func pushServerURLToDevice() {
    updateServerURL()
    let url = serverURL
    let port = devicePort
    runBusyTask("Pushing sync URL to X4...") {
      let message = try await Task.detached {
        try DeviceManager.pushSyncURL(url, port: port)
      }.value
      await MainActor.run {
        self.statusMessage = message
        self.deviceStatus = "Sync URL saved on X4"
        self.lastError = nil
      }
    }
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
      nextServer.onRequest = { [weak self] request in
        Task { @MainActor in
          self?.recordRequest(request)
        }
      }
      nextServer.onSleepRegenerateRequest = { [weak self] in
        Task { @MainActor in
          self?.regenerateSleepScreenFromAPI()
        }
      }
      try nextServer.start()
      server = nextServer
      serverEnabled = true
      defaults.set(true, forKey: "serverEnabled")
      statusMessage = "Server running at \(serverURL)."
      lastError = nil
      updateKeepAwakeAssertion()
    } catch {
      serverEnabled = false
      defaults.set(false, forKey: "serverEnabled")
      showError(error)
    }
  }

  private func stopServer() {
    server?.stop()
    server = nil
    serverEnabled = false
    defaults.set(false, forKey: "serverEnabled")
    updateKeepAwakeAssertion()
    statusMessage = "Server stopped."
  }

  private func updateKeepAwakeAssertion() {
    let shouldKeepAwake = keepAwakeEnabled && serverEnabled

    if shouldKeepAwake && keepAwakeAssertionID == 0 {
      let reason = "X4 Sync Server is serving files" as CFString
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn),
        reason,
        &keepAwakeAssertionID
      )
      if result != kIOReturnSuccess {
        keepAwakeAssertionID = 0
        lastError = "Could not keep Mac awake."
        statusMessage = "Could not keep Mac awake."
      }
    } else if !shouldKeepAwake && keepAwakeAssertionID != 0 {
      IOPMAssertionRelease(keepAwakeAssertionID)
      keepAwakeAssertionID = 0
    }
  }

  private func recordRequest(_ request: HTTPRequestLog) {
    let time = DateFormatter.localizedString(from: request.timestamp, dateStyle: .none, timeStyle: .medium)
    lastRequestStatus = "\(time) \(request.method) \(request.path) -> \(request.status)"
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
      ("notes.txt", "Edit these files, or add build_sleep_inputs.sh to generate them.\n"),
      ("hn.txt", "HN has not updated yet\n")
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
      try renderSleepScreen()
    }
    sleepStatus = fileStatus(sleepBMPURL)
    sleepRegenerationStatus = sleepRegenerateTimerEnabled ? "Timer every \(sleepRegenerateIntervalMinutes) min" : "Timer off"
    hnStatus = fileStatus(hnEPUBURL)
  }

  private func refreshManifest() throws {
    updateServerURL()
    let entries = manifestEntries()
    try ManifestWriter.write(entries: entries, serverURL: serverURL, outputURL: manifestURL)
    manifestStatus = "\(entries.count) file\(entries.count == 1 ? "" : "s")"
  }

  private func renderSleepScreen() throws {
    try SleepRenderer.render(inputsDir: inputsDir, outputURL: sleepBMPURL, orientation: sleepOrientation, sections: sleepSections)
  }

  private func saveSleepSectionSettings() {
    defaults.set(sleepWeatherEnabled, forKey: "sleepWeatherEnabled")
    defaults.set(sleepCalendarEnabled, forKey: "sleepCalendarEnabled")
    defaults.set(sleepTodoEnabled, forKey: "sleepTodoEnabled")
    defaults.set(sleepNotesEnabled, forKey: "sleepNotesEnabled")
    defaults.set(sleepHNEnabled, forKey: "sleepHNEnabled")
  }

  private func writeSleepHNPreview(stories: [HNStory]) throws {
    let lines = stories.prefix(3).enumerated().map { index, story in
      let points = story.score ?? 0
      let comments = story.commentCount ?? 0
      return "\(index + 1). \(story.title) (\(points) pts, \(comments) comments)"
    }
    let text = lines.isEmpty ? "HN has no stories right now\n" : lines.joined(separator: "\n") + "\n"
    try text.write(to: sleepHNInputURL, atomically: true, encoding: .utf8)
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

  private func scheduleSleepTimer() {
    sleepTimer?.invalidate()
    sleepTimer = nil

    guard sleepEnabled && sleepRegenerateTimerEnabled else { return }
    sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(sleepRegenerateIntervalMinutes * 60), repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.requestSleepRegeneration(source: "Timer")
      }
    }
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

  private func shortTimestamp() -> String {
    DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
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
        if let pending = self.pendingSleepRegenerationSource {
          self.pendingSleepRegenerationSource = nil
          self.requestSleepRegeneration(source: pending)
        }
      }
    }
  }

  private func showError(_ error: Error) {
    lastError = error.localizedDescription
    statusMessage = error.localizedDescription
  }
}
