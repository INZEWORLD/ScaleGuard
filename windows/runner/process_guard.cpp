#include "process_guard.h"

#include <windows.h>

namespace {

// The only handle to the job. It is deliberately never closed: closing it is the
// signal that takes every member down, and that has to happen when the kernel
// tears the process down rather than at any point in the application's own
// shutdown.
HANDLE job_handle = nullptr;

}  // namespace

namespace ProcessGuard {

void InstallKillOnCloseJob() {
  HANDLE job = CreateJobObjectW(nullptr, nullptr);
  if (job == nullptr) {
    return;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                               sizeof(limits)) ||
      !AssignProcessToJobObject(job, GetCurrentProcess())) {
    CloseHandle(job);
    return;
  }
  job_handle = job;
}

void AllowChildrenToOutliveUs() { SetChildrenMayOutliveUs(true); }

void SetChildrenMayOutliveUs(bool allow) {
  if (job_handle == nullptr) {
    return;
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
      (allow ? JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK : 0);
  SetInformationJobObject(job_handle, JobObjectExtendedLimitInformation,
                          &limits, sizeof(limits));
}

}  // namespace ProcessGuard
