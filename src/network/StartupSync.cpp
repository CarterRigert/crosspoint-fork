#include "StartupSync.h"

#include <Arduino.h>
#include <ArduinoJson.h>
#include <HalStorage.h>
#include <Logging.h>
#include <WiFi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>

#include <string>

#include "CrossPointSettings.h"
#include "HttpDownloader.h"
#include "WifiCredentialStore.h"

namespace {
constexpr char LOG_TAG[] = "SYNC";
constexpr char MANIFEST_NAME[] = "manifest.json";
constexpr char MANIFEST_TMP[] = "/.crosspoint/startup_sync_manifest.tmp";
constexpr char DEFAULT_DEST_PATH[] = "/Sync/test.txt";
constexpr int WIFI_CONNECT_TIMEOUT_MS = 8000;
constexpr int HTTP_TIMEOUT_MS = 5000;
constexpr size_t MAX_MANIFEST_SIZE = 8192;
constexpr uint32_t TASK_STACK_SIZE = 8192;
TaskHandle_t syncTaskHandle = nullptr;

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

bool readManifest(const std::string& serverUrl, std::string& fileUrl, std::string& destPath) {
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

  JsonObjectConst first = files[0].as<JsonObjectConst>();
  if (first.isNull()) {
    LOG_ERR(LOG_TAG, "Manifest first file is invalid");
    return false;
  }

  destPath = first["path"] | DEFAULT_DEST_PATH;
  if (!isSafeSdPath(destPath)) {
    LOG_ERR(LOG_TAG, "Unsafe manifest path, using %s", DEFAULT_DEST_PATH);
    destPath = DEFAULT_DEST_PATH;
  }

  fileUrl = first["url"] | "";
  if (fileUrl.empty()) {
    const auto slash = destPath.find_last_of('/');
    fileUrl = slash == std::string::npos ? destPath : destPath.substr(slash + 1);
  }
  fileUrl = joinUrl(serverUrl, fileUrl);

  if (!first["sha256"].isNull()) {
    LOG_INF(LOG_TAG, "sha256 present but validation is not implemented yet");
  }
  return true;
}

bool promoteDownloadedFile(const std::string& tempPath, const std::string& destPath) {
  if (!Storage.exists(tempPath.c_str())) {
    LOG_ERR(LOG_TAG, "Temp file missing: %s", tempPath.c_str());
    return false;
  }

  if (!Storage.exists(destPath.c_str())) {
    return Storage.rename(tempPath.c_str(), destPath.c_str());
  }

  const std::string backupPath = tempPath + ".old";
  Storage.remove(backupPath.c_str());

  if (!Storage.rename(destPath.c_str(), backupPath.c_str())) {
    LOG_ERR(LOG_TAG, "Failed to stage existing file: %s", destPath.c_str());
    return false;
  }

  if (Storage.rename(tempPath.c_str(), destPath.c_str())) {
    Storage.remove(backupPath.c_str());
    return true;
  }

  LOG_ERR(LOG_TAG, "Failed to promote temp file: %s", destPath.c_str());
  Storage.rename(backupPath.c_str(), destPath.c_str());
  return false;
}

bool downloadFirstFile(const std::string& fileUrl, const std::string& destPath) {
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

    std::string fileUrl;
    std::string destPath;
    if (!readManifest(serverUrl, fileUrl, destPath)) break;

    ok = downloadFirstFile(fileUrl, destPath);
  } while (false);

  disconnectWifi();

  if (ok) {
    LOG_INF(LOG_TAG, "Sync OK");
    return Result::Ok;
  }

  LOG_ERR(LOG_TAG, "Sync failed");
  return Result::Failed;
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
