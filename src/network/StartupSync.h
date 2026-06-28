#pragma once

namespace StartupSync {

enum class Result {
  Skipped,
  Ok,
  Failed,
};

void start();
Result runOnce();
Result syncSleepImageBeforeSleep();
bool isRunning();
bool isSleepImageUpdating();
bool isHnLatestUpdating();

}  // namespace StartupSync
