#include "StartupSync.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

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
constexpr int WIFI_CONNECT_TIMEOUT_MS = 8000;
constexpr int HTTP_TIMEOUT_MS = 5000;
constexpr size_t MAX_MANIFEST_SIZE = 8192;
constexpr size_t MAX_MANIFEST_FILES = 8;
constexpr uint32_t TASK_STACK_SIZE = 8192;
TaskHandle_t syncTaskHandle = nullptr;

struct SyncFile {
  std::string url;
  std::string destPath;
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

bool connectSavedWifi() {
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
  while (WiFi.status() != WL_CONNECTED && millis() - start < WIFI_CONNECT_TIMEOUT_MS) {
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

bool readManifest(const std::string& serverUrl, std::vector<SyncFile>& syncFiles) {
  syncFiles.clear();
  Storage.mkdir("/.crosspoint");
  Storage.remove(MANIFEST_TMP);

  const std::string url = manifestUrlFor(serverUrl);
  const auto result = HttpDownloader::downloadToFile(url, MANIFEST_TMP, nullptr, nullptr, "", "", HTTP_TIMEOUT_MS);
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

    if (!entry["sha256"].isNull()) {
      LOG_INF(LOG_TAG, "sha256 present but validation is not implemented yet");
    }

    syncFiles.push_back({fileUrl, destPath});
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

bool downloadFile(const SyncFile& syncFile) {
  const std::string& fileUrl = syncFile.url;
  const std::string& destPath = syncFile.destPath;

  if (!ensureParentDir(destPath)) {
    LOG_ERR(LOG_TAG, "Failed to create destination directory");
    return false;
  }

  const std::string tempPath = destPath + ".download";
  Storage.remove(tempPath.c_str());

  const auto result = HttpDownloader::downloadToFile(fileUrl, tempPath, nullptr, nullptr, "", "", HTTP_TIMEOUT_MS);
  if (result != HttpDownloader::OK) {
    LOG_ERR(LOG_TAG, "File download failed: %d", result);
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

bool downloadFiles(const std::vector<SyncFile>& syncFiles) {
  bool allOk = true;
  for (const auto& syncFile : syncFiles) {
    if (!downloadFile(syncFile)) {
      allOk = false;
    }
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

void syncTask(void*) {
  StartupSync::runOnce();
  syncTaskHandle = nullptr;
  vTaskDelete(nullptr);
}
}  // namespace

StartupSync::Result StartupSync::runOnce() {
  const std::string serverUrl = withoutTrailingSlashes(trim(SETTINGS.startupSyncServerUrl));
  if (serverUrl.empty()) {
    LOG_INF(LOG_TAG, "Sync skipped");
    return Result::Skipped;
  }

  LOG_INF(LOG_TAG, "Startup sync: %s", serverUrl.c_str());

  bool ok = false;
  do {
    if (!connectSavedWifi()) break;

    std::vector<SyncFile> syncFiles;
    if (!readManifest(serverUrl, syncFiles)) break;

    ok = downloadFiles(syncFiles);
  } while (false);

  disconnectWifi();

  if (ok) {
    LOG_INF(LOG_TAG, "Sync OK");
    return Result::Ok;
  }

  LOG_ERR(LOG_TAG, "Sync failed");
  return Result::Failed;
}

bool StartupSync::isRunning() { return syncTaskHandle != nullptr; }

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
