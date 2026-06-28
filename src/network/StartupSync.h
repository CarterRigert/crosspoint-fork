#pragma once

namespace StartupSync {

enum class Result {
  Skipped,
  Ok,
  Failed,
};

void start();
Result runOnce();
bool isRunning();

}  // namespace StartupSync
