#pragma once

namespace StartupSync {

enum class Result {
  Skipped,
  Ok,
  Failed,
};

void start();
Result runOnce();
Result prepareForSleep(bool waitForSleepImage);
Result syncSleepImageBeforeSleep();
bool isRunning();
bool isSleepImageUpdating();
bool isHnLatestUpdating();

}  // namespace StartupSync
