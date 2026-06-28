#include "StartupSync.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <mbedtls/sha256.h>

#include <algorithm>
#include <cctype>
#include <limits>
#include <string>
#include <vector>

#include "CrossPointSettings.h"
#include "HttpDownloader.h"
#include "WifiCredentialStore.h"
#include "util/BookCacheUtils.h"

namespace {
constexpr char LOG_TAG[] = "SYNC";
constexpr char MANIFEST_NAME[] = "manifest.json";
constexpr char MANIFEST_TMP[] = "/.crosspoint/startup_sync_manifest.tmp";
constexpr char DEFAULT_DEST_PATH[] = "/Sync/test.txt";
constexpr char SLEEP_IMAGE_PATH[] = "/sleep.bmp";
constexpr char HN_LATEST_PATH[] = "/HNLatest.epub";
constexpr int WIFI_CONNECT_TIMEOUT_MS = 8000;
constexpr int HTTP_TIMEOUT_MS = 5000;
constexpr int SLEEP_SYNC_WAIT_TIMEOUT_MS = 60000;
constexpr int CANCEL_WAIT_TIMEOUT_MS = HTTP_TIMEOUT_MS + 2000;
constexpr size_t MAX_MANIFEST_SIZE = 8192;
constexpr size_t MAX_MANIFEST_FILES = 8;
constexpr uint32_t TASK_STACK_SIZE = 8192;
TaskHandle_t syncTaskHandle = nullptr;
volatile bool cancelRequested = false;

enum class FileSyncState : uint8_t {
  Idle,
  Pending,
  Resolved,
};

volatile FileSyncState sleepSyncState = FileSyncState::Idle;
volatile FileSyncState hnLatestSyncState = FileSyncState::Idle;

struct SyncFile {
  std::string url;
  std::string destPath;
  std::string sha256;
  uint64_t size = 0;
};

std::string trim(const char* value) {
  if (!value) return {};
  std::string out = value;
  const auto first = out.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = out.find_last_not_of(" \t\r\n");
  return out.substr(first, last - first + 1);
}

std::string withoutTrailingSlashes(std::string value) {
  while (!value.empty() && value.back() == '/') {
    value.pop_back();
  }
  return value;
}

std::string toLowerAscii(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

bool isHexSha256(const std::string& value) {
  if (value.size() != 64) return false;
  return std::all_of(value.begin(), value.end(), [](unsigned char c) { return std::isxdigit(c); });
}

std::string joinUrl(const std::string& baseUrl, const std::string& path) {
  if (path.rfind("http://", 0) == 0 || path.rfind("https://", 0) == 0) {
    return path;
  }
  const std::string base = withoutTrailingSlashes(baseUrl);
  if (path.empty()) return base;
  if (path.front() == '/') return base + path;
  return base + "/" + path;
}

std::string manifestUrlFor(const std::string& baseUrl) { return joinUrl(baseUrl, MANIFEST_NAME); }

bool isSleepImage(const SyncFile& syncFile) { return syncFile.destPath == SLEEP_IMAGE_PATH; }

bool isHnLatest(const SyncFile& syncFile) { return syncFile.destPath == HN_LATEST_PATH; }

bool hasVersionInfo(const SyncFile& syncFile) { return !syncFile.sha256.empty() || syncFile.size > 0; }

uint64_t sortSize(const SyncFile& syncFile) {
  return syncFile.size > 0 ? syncFile.size : std::numeric_limits<uint64_t>::max();
}

bool isSafeSdPath(const std::string& path) {
  return path.size() > 1 && path.size() < 220 && path.front() == '/' && path.find("..") == std::string::npos &&
         path.find("//") == std::string::npos;
}

std::string parentDir(const std::string& path) {
  const auto slash = path.find_last_of('/');
  if (slash == std::string::npos || slash == 0) return "/";
  return path.substr(0, slash);
}

bool ensureParentDir(const std::string& path) {
  const std::string parent = parentDir(path);
  return parent == "/" || Storage.mkdir(parent.c_str());
}

bool computeFileSha256(const std::string& path, std::string& outSha256, uint64_t& outSize) {
  HalFile file;
  if (!Storage.openFileForRead(LOG_TAG, path, file)) {
    return false;
  }

  mbedtls_sha256_context shaCtx;
  mbedtls_sha256_init(&shaCtx);
  mbedtls_sha256_starts(&shaCtx, /*is224=*/0);

  uint8_t buffer[2048];
  uint64_t total = 0;
  bool ok = true;
  while (file.available()) {
    const int read = file.read(buffer, sizeof(buffer));
    if (read < 0) {
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    mbedtls_sha256_update(&shaCtx, buffer, static_cast<size_t>(read));
    total += static_cast<uint64_t>(read);
  }
  file.close();

  if (!ok) {
    mbedtls_sha256_free(&shaCtx);
    return false;
  }

  uint8_t digest[32];
  mbedtls_sha256_finish(&shaCtx, digest);
  mbedtls_sha256_free(&shaCtx);

  static constexpr char HEX_DIGITS[] = "0123456789abcdef";
  char hex[65];
  for (size_t i = 0; i < sizeof(digest); ++i) {
    hex[i * 2] = HEX_DIGITS[digest[i] >> 4];
    hex[i * 2 + 1] = HEX_DIGITS[digest[i] & 0x0F];
  }
  hex[64] = '\0';

  outSha256 = hex;
  outSize = total;
  return true;
}

bool fileMatchesManifest(const SyncFile& syncFile, const std::string& path) {
  if (syncFile.sha256.empty() && syncFile.size == 0) {
    return false;
  }

  HalFile file;
  if (!Storage.openFileForRead(LOG_TAG, path, file)) {
    return false;
  }
  const uint64_t actualSize = file.fileSize64();
  file.close();

  if (syncFile.size > 0 && actualSize != syncFile.size) {
    LOG_INF(LOG_TAG, "File size changed for %s: got %llu expected %llu", path.c_str(),
            static_cast<unsigned long long>(actualSize), static_cast<unsigned long long>(syncFile.size));
    return false;
  }

  if (syncFile.sha256.empty()) {
    return syncFile.size > 0;
  }

  std::string actualSha256;
  uint64_t hashedSize = 0;
  if (!computeFileSha256(path, actualSha256, hashedSize)) {
    return false;
  }

  if (syncFile.size > 0 && hashedSize != syncFile.size) {
    return false;
  }

  const bool matches = actualSha256 == syncFile.sha256;
  if (!matches) {
    LOG_INF(LOG_TAG, "SHA256 changed for %s", path.c_str());
  }
  return matches;
}

bool connectSavedWifi(const int timeoutMs) {
  if (WiFi.status() == WL_CONNECTED) {
    LOG_INF(LOG_TAG, "Wi-Fi already connected: %s", WiFi.localIP().toString().c_str());
    return true;
  }

  const std::string ssid = WIFI_STORE.getLastConnectedSsid();
  if (ssid.empty()) {
    LOG_ERR(LOG_TAG, "No saved Wi-Fi SSID");
    return false;
  }

  const WifiCredential* cred = WIFI_STORE.findCredential(ssid);
  if (!cred) {
    LOG_ERR(LOG_TAG, "No saved Wi-Fi credentials for %s", ssid.c_str());
    return false;
  }

  WiFi.persistent(false);
  WiFi.mode(WIFI_STA);
  WiFi.disconnect(true, true);
  delay(100);

  String mac = WiFi.macAddress();
  mac.replace(":", "");
  String hostname = "CrossPoint-Reader-" + mac;
  WiFi.setHostname(hostname.c_str());
  WiFi.setSleep(false);

  LOG_INF(LOG_TAG, "Connecting Wi-Fi: %s", ssid.c_str());
  if (cred->password.empty()) {
    WiFi.begin(cred->ssid.c_str());
  } else {
    WiFi.begin(cred->ssid.c_str(), cred->password.c_str());
  }

  const unsigned long start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < static_cast<unsigned long>(timeoutMs)) {
    delay(100);
  }

  if (WiFi.status() != WL_CONNECTED) {
    LOG_ERR(LOG_TAG, "Wi-Fi connect timeout/status=%d", WiFi.status());
    WiFi.disconnect(false);
    return false;
  }

  LOG_INF(LOG_TAG, "Wi-Fi connected: %s", WiFi.localIP().toString().c_str());
  return true;
}

bool readManifest(const std::string& serverUrl, std::vector<SyncFile>& syncFiles, volatile bool* cancelFlag,
                  const int timeoutMs) {
  syncFiles.clear();
  Storage.mkdir("/.crosspoint");
  Storage.remove(MANIFEST_TMP);

  const std::string url = manifestUrlFor(serverUrl);
  const auto result = HttpDownloader::downloadToFile(url, MANIFEST_TMP, nullptr, cancelFlag, "", "", timeoutMs);
  if (result != HttpDownloader::OK) {
    LOG_ERR(LOG_TAG, "Manifest fetch failed: %d", result);
    Storage.remove(MANIFEST_TMP);
    return false;
  }

  HalFile manifestFile;
  if (!Storage.openFileForRead(LOG_TAG, MANIFEST_TMP, manifestFile)) {
    LOG_ERR(LOG_TAG, "Manifest open failed");
    Storage.remove(MANIFEST_TMP);
    return false;
  }

  if (manifestFile.size() > MAX_MANIFEST_SIZE) {
    LOG_ERR(LOG_TAG, "Manifest too large: %zu", manifestFile.size());
    manifestFile.close();
    Storage.remove(MANIFEST_TMP);
    return false;
  }

  JsonDocument doc;
  const DeserializationError err = deserializeJson(doc, manifestFile);
  manifestFile.close();
  Storage.remove(MANIFEST_TMP);

  if (err) {
    LOG_ERR(LOG_TAG, "Manifest parse failed: %s", err.c_str());
    return false;
  }

  JsonArrayConst files = doc["files"].as<JsonArrayConst>();
  if (files.isNull() || files.size() == 0) {
    LOG_ERR(LOG_TAG, "Manifest has no files");
    return false;
  }

  for (JsonObjectConst entry : files) {
    if (syncFiles.size() >= MAX_MANIFEST_FILES) {
      LOG_INF(LOG_TAG, "Manifest file limit reached (%zu)", MAX_MANIFEST_FILES);
      break;
    }

    if (entry.isNull()) {
      LOG_ERR(LOG_TAG, "Skipping invalid manifest file entry");
      continue;
    }

    std::string destPath = entry["path"] | std::string("");
    if (destPath.empty() && syncFiles.empty()) {
      destPath = DEFAULT_DEST_PATH;
    }

    if (!isSafeSdPath(destPath)) {
      LOG_ERR(LOG_TAG, "Skipping unsafe manifest path: %s", destPath.c_str());
      continue;
    }

    std::string fileUrl = entry["url"] | "";
    if (fileUrl.empty()) {
      const auto slash = destPath.find_last_of('/');
      fileUrl = slash == std::string::npos ? destPath : destPath.substr(slash + 1);
    }
    fileUrl = joinUrl(serverUrl, fileUrl);

    std::string sha256 = toLowerAscii(trim(entry["sha256"] | ""));
    if (!sha256.empty() && !isHexSha256(sha256)) {
      LOG_ERR(LOG_TAG, "Ignoring invalid sha256 for %s", destPath.c_str());
      sha256.clear();
    }

    uint64_t size = 0;
    if (entry["size"].is<uint64_t>()) {
      size = entry["size"].as<uint64_t>();
    }

    syncFiles.push_back({fileUrl, destPath, sha256, size});
  }

  if (syncFiles.empty()) {
    LOG_ERR(LOG_TAG, "Manifest has no usable files");
    return false;
  }

  LOG_INF(LOG_TAG, "Manifest has %zu file(s)", syncFiles.size());
  return true;
}

bool deleteExistingDestination(const std::string& destPath) {
  if (!Storage.exists(destPath.c_str())) {
    return true;
  }

  LOG_INF(LOG_TAG, "Deleting existing file before replace: %s", destPath.c_str());
  for (int attempt = 0; attempt < 2; ++attempt) {
    if (Storage.remove(destPath.c_str()) || !Storage.exists(destPath.c_str())) {
      LOG_INF(LOG_TAG, "Deleted existing file: %s", destPath.c_str());
      return true;
    }
    delay(50);
  }

  LOG_ERR(LOG_TAG, "Failed to delete existing file: %s", destPath.c_str());
  return false;
}

bool copyDownloadedFileToNewDestination(const std::string& tempPath, const std::string& destPath) {
  HalFile src;
  if (!Storage.openFileForRead(LOG_TAG, tempPath, src)) {
    LOG_ERR(LOG_TAG, "Failed to open temp file for copy: %s", tempPath.c_str());
    return false;
  }

  if (src.size() == 0) {
    LOG_ERR(LOG_TAG, "Downloaded temp file is empty: %s", tempPath.c_str());
    src.close();
    return false;
  }

  if (!deleteExistingDestination(destPath)) {
    src.close();
    return false;
  }

  HalFile dst;
  if (!Storage.openFileForWrite(LOG_TAG, destPath, dst)) {
    LOG_ERR(LOG_TAG, "Failed to open destination after delete: %s", destPath.c_str());
    src.close();
    return false;
  }

  uint8_t buffer[2048];
  size_t copied = 0;
  bool ok = true;
  while (true) {
    const int read = src.read(buffer, sizeof(buffer));
    if (read < 0) {
      LOG_ERR(LOG_TAG, "Failed reading temp file: %s", tempPath.c_str());
      ok = false;
      break;
    }
    if (read == 0) {
      break;
    }
    if (dst.write(buffer, static_cast<size_t>(read)) != static_cast<size_t>(read)) {
      LOG_ERR(LOG_TAG, "Failed writing destination: %s", destPath.c_str());
      ok = false;
      break;
    }
    copied += static_cast<size_t>(read);
  }

  dst.flush();
  src.close();
  dst.close();

  if (!ok || copied == 0) {
    Storage.remove(destPath.c_str());
    return false;
  }

  LOG_INF(LOG_TAG, "Recreated %s (%zu bytes)", destPath.c_str(), copied);
  return true;
}

bool promoteDownloadedFile(const std::string& tempPath, const std::string& destPath) {
  if (!Storage.exists(tempPath.c_str())) {
    LOG_ERR(LOG_TAG, "Temp file missing: %s", tempPath.c_str());
    return false;
  }

  if (!copyDownloadedFileToNewDestination(tempPath, destPath)) {
    return false;
  }

  clearBookCache(destPath);
  Storage.remove(tempPath.c_str());
  return true;
}

bool downloadFile(const SyncFile& syncFile, volatile bool* cancelFlag, const int timeoutMs) {
  const std::string& fileUrl = syncFile.url;
  const std::string& destPath = syncFile.destPath;

  if (fileMatchesManifest(syncFile, destPath)) {
    LOG_INF(LOG_TAG, "Up to date: %s", destPath.c_str());
    return true;
  }

  if (!ensureParentDir(destPath)) {
    LOG_ERR(LOG_TAG, "Failed to create destination directory");
    return false;
  }

  const std::string tempPath = destPath + ".download";
  Storage.remove(tempPath.c_str());

  const auto result = HttpDownloader::downloadToFile(fileUrl, tempPath, nullptr, cancelFlag, "", "", timeoutMs);
  if (result != HttpDownloader::OK) {
    LOG_ERR(LOG_TAG, "File download failed: %d", result);
    Storage.remove(tempPath.c_str());
    return false;
  }

  if (hasVersionInfo(syncFile) && !fileMatchesManifest(syncFile, tempPath)) {
    LOG_ERR(LOG_TAG, "Downloaded file did not match manifest: %s", destPath.c_str());
    Storage.remove(tempPath.c_str());
    return false;
  }

  if (!promoteDownloadedFile(tempPath, destPath)) {
    Storage.remove(tempPath.c_str());
    return false;
  }

  LOG_INF(LOG_TAG, "Saved %s", destPath.c_str());
  return true;
}

enum class SyncMode {
  AllFiles,
  SleepImageOnly,
};

bool downloadFiles(std::vector<SyncFile>& syncFiles, SyncMode mode, volatile bool* cancelFlag, const int timeoutMs) {
  if (mode == SyncMode::AllFiles) {
    std::stable_sort(syncFiles.begin(), syncFiles.end(), [](const SyncFile& a, const SyncFile& b) {
      return sortSize(a) < sortSize(b);
    });
  }

  bool allOk = true;
  bool sawSleepImage = false;
  bool sawHnLatest = false;
  for (const auto& syncFile : syncFiles) {
    if (cancelFlag && *cancelFlag) {
      allOk = false;
      break;
    }

    if (mode == SyncMode::SleepImageOnly && !isSleepImage(syncFile)) {
      continue;
    }

    if (isSleepImage(syncFile)) {
      sawSleepImage = true;
      sleepSyncState = FileSyncState::Pending;
    }

    if (mode == SyncMode::AllFiles && isHnLatest(syncFile)) {
      sawHnLatest = true;
      hnLatestSyncState = FileSyncState::Pending;
    }

    if (!downloadFile(syncFile, cancelFlag, timeoutMs)) {
      allOk = false;
    }

    if (isSleepImage(syncFile)) {
      sleepSyncState = FileSyncState::Resolved;
    }

    if (mode == SyncMode::AllFiles && isHnLatest(syncFile)) {
      hnLatestSyncState = FileSyncState::Resolved;
    }
  }

  if (!sawSleepImage) {
    sleepSyncState = FileSyncState::Resolved;
  }

  if (mode == SyncMode::AllFiles && !sawHnLatest) {
    hnLatestSyncState = FileSyncState::Resolved;
  }

  return allOk;
}

void disconnectWifi() {
  if (WiFi.getMode() != WIFI_MODE_NULL) {
    WiFi.disconnect(false);
    delay(30);
    WiFi.setSleep(true);
    WiFi.mode(WIFI_OFF);
  }
}

StartupSync::Result runSync(SyncMode mode, const int wifiTimeoutMs, const int httpTimeoutMs, volatile bool* cancelFlag) {
  const std::string serverUrl = withoutTrailingSlashes(trim(SETTINGS.startupSyncServerUrl));
  if (serverUrl.empty()) {
    LOG_INF(LOG_TAG, "Sync skipped");
    sleepSyncState = FileSyncState::Resolved;
    if (mode == SyncMode::AllFiles) {
      hnLatestSyncState = FileSyncState::Resolved;
    }
    return StartupSync::Result::Skipped;
  }

  LOG_INF(LOG_TAG, "%s: %s", mode == SyncMode::SleepImageOnly ? "Sleep sync" : "Startup sync", serverUrl.c_str());

  bool ok = false;
  do {
    if (!connectSavedWifi(wifiTimeoutMs)) break;
    if (cancelFlag && *cancelFlag) break;

    std::vector<SyncFile> syncFiles;
    if (!readManifest(serverUrl, syncFiles, cancelFlag, httpTimeoutMs)) break;
    if (cancelFlag && *cancelFlag) break;

    ok = downloadFiles(syncFiles, mode, cancelFlag, httpTimeoutMs);
  } while (false);

  disconnectWifi();

  if (!ok) {
    sleepSyncState = FileSyncState::Resolved;
    if (mode == SyncMode::AllFiles) {
      hnLatestSyncState = FileSyncState::Resolved;
    }
    LOG_ERR(LOG_TAG, "Sync failed");
    return StartupSync::Result::Failed;
  }

  LOG_INF(LOG_TAG, "Sync OK");
  return StartupSync::Result::Ok;
}

void syncTask(void*) {
  StartupSync::runOnce();
  cancelRequested = false;
  sleepSyncState = FileSyncState::Resolved;
  hnLatestSyncState = FileSyncState::Resolved;
  syncTaskHandle = nullptr;
  vTaskDelete(nullptr);
}
}  // namespace

StartupSync::Result StartupSync::runOnce() {
  cancelRequested = false;
  sleepSyncState = FileSyncState::Idle;
  hnLatestSyncState = FileSyncState::Pending;
  return runSync(SyncMode::AllFiles, WIFI_CONNECT_TIMEOUT_MS, HTTP_TIMEOUT_MS, &cancelRequested);
}

StartupSync::Result StartupSync::prepareForSleep(bool waitForSleepImage) {
  if (!syncTaskHandle) {
    LOG_INF(LOG_TAG, "Startup sync stop skipped: no startup sync running");
    return Result::Skipped;
  }

  if (waitForSleepImage && sleepSyncState != FileSyncState::Resolved) {
    LOG_INF(LOG_TAG, "Waiting for startup sync sleep image before sleep");
    const unsigned long waitStart = millis();
    while (syncTaskHandle && sleepSyncState != FileSyncState::Resolved &&
           millis() - waitStart < SLEEP_SYNC_WAIT_TIMEOUT_MS) {
      delay(50);
    }

    if (sleepSyncState != FileSyncState::Resolved) {
      LOG_ERR(LOG_TAG, "Sleep image sync timed out before sleep");
      return Result::Failed;
    }

    LOG_INF(LOG_TAG, "Sleep image resolved before sleep");
  }

  LOG_INF(LOG_TAG, "Stopping startup sync before sleep");
  cancelRequested = true;
  const unsigned long cancelStart = millis();
  while (syncTaskHandle && millis() - cancelStart < CANCEL_WAIT_TIMEOUT_MS) {
    delay(25);
  }

  if (!syncTaskHandle) {
    LOG_INF(LOG_TAG, "Startup sync stopped before sleep");
    return Result::Ok;
  }

  LOG_ERR(LOG_TAG, "Startup sync stop timed out before sleep");
  return Result::Failed;
}

StartupSync::Result StartupSync::syncSleepImageBeforeSleep() { return prepareForSleep(true); }

bool StartupSync::isRunning() { return syncTaskHandle != nullptr; }

bool StartupSync::isSleepImageUpdating() {
  return syncTaskHandle != nullptr && sleepSyncState != FileSyncState::Resolved;
}

bool StartupSync::isHnLatestUpdating() {
  return syncTaskHandle != nullptr && hnLatestSyncState != FileSyncState::Resolved;
}

void StartupSync::start() {
  if (trim(SETTINGS.startupSyncServerUrl).empty()) {
    LOG_INF(LOG_TAG, "Sync skipped");
    return;
  }

  if (syncTaskHandle) {
    return;
  }

  const BaseType_t created = xTaskCreate(syncTask, "StartupSync", TASK_STACK_SIZE, nullptr, 1, &syncTaskHandle);
  if (created != pdPASS) {
    syncTaskHandle = nullptr;
    LOG_ERR(LOG_TAG, "Sync failed: task create failed");
  }
}
