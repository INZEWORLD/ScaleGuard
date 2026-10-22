#ifndef RUNNER_PROCESS_GUARD_H_
#define RUNNER_PROCESS_GUARD_H_

// Keeps the child processes of the client — above all the VPN core — from
// outliving it.
//
// A tunnel that keeps running after the window is gone is the one failure a VPN
// client must never have, and it is exactly what happens when the runner is
// ended in a way it cannot react to: "End task" in the task manager, a logoff,
// or a crash. Dart's shutdown path covers every orderly exit; the job object
// covers the rest, because the kernel closes the handle when the process dies
// and terminates what was left behind with it.
namespace ProcessGuard {

// Creates a job object that kills its members when its last handle closes and
// puts this process into it. Every process spawned from here on — including the
// core — is a member, because a child of a member belongs to the job as well.
//
// Failure is not fatal. Joining is refused when the process is already inside a
// job that forbids nesting; the application then relies on its own shutdown
// path only.
void InstallKillOnCloseJob();

// Lets processes created from now on leave the job.
//
// Needed by exactly one operation: restarting the client. The replacement is
// spawned by the instance that is about to exit, so without this the kernel
// would terminate it together with its parent the moment the job handle closes.
// The protection is therefore lifted only for the children of a process that is
// already on its way out.
void AllowChildrenToOutliveUs();

// Lifts or restores that protection, as a choice rather than a one-way door.
//
// Restarting is not the only hand-over, and it is not the one that can be
// decided in advance. The elevated copy the launcher starts for "always run as
// administrator" is a child of this process too, and it is only known to be
// wanted after Windows answers the request: a declined prompt leaves a session
// that carries on. Lifting the protection is therefore followed by restoring it
// whenever the child never arrives, so an ordinary session keeps the core under
// the job's cover — which is the whole point of the job.
void SetChildrenMayOutliveUs(bool allow);

}  // namespace ProcessGuard

#endif  // RUNNER_PROCESS_GUARD_H_
