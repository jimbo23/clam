# Mechanism and safety boundaries

Clam is a local, unsandboxed macOS 13+ menu-bar application. Its Foundation-only `ClamCore` separates command execution, sleep-setting control, power assertions, marker storage, and state transitions so the logic can be tested without macOS privileges. The app serializes controller operations; the core is synchronous and does not itself provide cross-process coordination.

## What actually prevents sleep?

Clam combines two different mechanisms:

1. `/usr/bin/pmset -a disablesleep 1` requests a system-wide sleep-disable setting. `pmset -g` exposes the `SleepDisabled` value on systems that support it. This is the part intended to affect lid-close sleep, including battery operation without an external display.
2. An IOKit `PreventUserIdleSystemSleep` assertion requests that inactivity not cause system sleep during Clam's active session. Clam releases that assertion when the session ends.

**The assertion alone is insufficient for closed-lid operation.** Apple's IOKit header explicitly says the system may still sleep for lid close, Apple-menu sleep, low battery, or other reasons. The assertion does not require the display to stay on and does not establish that closed-lid, no-external-display operation works. It is not interchangeable with `disablesleep`, and changing the idle timer with `pmset sleep 0` is not equivalent either. [1]

`disablesleep` is an undocumented implementation-level option, not a stable public promise of lid-close behavior on every Mac. Apple's `pmset` sources/man page provide implementation context, but do not constitute a compatibility guarantee. An exit code of zero and a displayed value of `1` confirm a command/state observation, not an end-to-end hardware result. Firmware, thermal limits, battery exhaustion, emergency sleep/shutdown, OS policy, and future releases remain outside Clam's control. Validate the intended use on the actual hardware and macOS version. [2]

## Privilege-mechanism comparison

| Mechanism | Setup and authorization | Advantages | Costs and limits | Clam 0.1.0 |
| --- | --- | --- | --- | --- |
| `SMAppService.daemon` with a signed privileged XPC helper | Bundle a daemon and launchd plist; sign the app/helper; register the daemon; obtain administrator approval in System Settings | Native service lifecycle, typed/narrow IPC, identity checks possible, app-bundled helper management | Requires a real daemon, authenticated XPC protocol, signing/distribution work, approval handling, updates/unregistration; registration is not instant authorization | Comparison/design alternative only; not implemented |
| Exact-command sudoers rule plus `sudo -n` | One administrator-approved installation for one local account | Small auditable surface, no custom long-running root server, subsequent toggles do not prompt when policy permits | Permission belongs to the account, not exclusively to this app; any process as that account can issue the two allowed commands; global-setting ownership still needed | Recommended local setup |
| AppleScript `do shell script … with administrator privileges` | macOS administrator authorization when needed; no sudoers installation required | Simple fallback; uses OS authentication UI; no password stored by Clam | Prompts may recur, cancellation/failure must be handled, unsuitable for guaranteed unattended cleanup; no boot reset without installing the daemon | Automatic fallback after failed noninteractive sudo |

### What a realistic SMAppService/XPC alternative would require

On macOS 13+, package the daemon executable inside the app, place its plist in `Contents/Library/LaunchDaemons`, and use `BundleProgram` to reference the bundled executable. A root launch daemon would publish a Mach service for a small XPC API such as “set sleep disabled to this Boolean,” not a general command runner. The app would register `SMAppService.daemon(plistName:)`, check its status, explain why the helper is needed, and guide the administrator to Login Items settings for approval when required. Apple's documentation states that a registered LaunchDaemon is **not bootstrapped until an administrator approves it**. Successful registration or possessing a signing certificate does not remove that approval requirement. [3]

For a realistic external distribution, use Developer ID Application signing for the app and daemon under the intended team, hardened runtime, correct nested-code signing, notarization, and verification of the final package. Local development signing and distribution trust are different concerns. `SMAppService` does not itself notarize code or implement an XPC authorization policy. [4]

The daemon must authenticate connecting clients using their audit-token/code-signing identity and an explicit designated requirement/team-and-identifier policy, rather than trusting a caller-supplied bundle ID or only a PID subject to reuse. It must reject unauthorized callers, expose only fixed operations, validate arguments, and handle disconnects and service version mismatches. Installation approval authorizes the service to run; it is not sufficient authorization for every IPC request. Updates, uninstall/unregistration, denial/revocation of approval, and daemon failure are all engineering work. Apple's XPC security guidance is relevant to that boundary. [5]

This approach is reasonable for a maintained, signed product, but is not a magic single-API replacement for a root helper. Clam's local build chooses the smaller sudoers mechanism instead; it neither ships an XPC daemon nor claims that an ad-hoc build is a production Developer ID installation.

### Recommended sudoers mechanism

The policy is scoped to the selected local account's validated numeric UID and exactly these two commands as root. For example, **only if that account's UID is 501**:

```sudoers
#501 ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Use the installer rather than copying this example: it resolves the selected local account to its non-root numeric UID, validates the policy, and installs `/etc/sudoers.d/clam` with root ownership and restrictive permissions. The `#UID` sudoers syntax avoids interpreting an account name such as `ALL` as a policy keyword or alias; it is a numeric user specification, not a comment in this context. There are no command or argument wildcards, no shell permission, and no blanket `NOPASSWD: ALL`. A root-editable policy containing fixed executable paths avoids authorizing a user-writable helper as an arbitrary root program. Sudoers matches the specified command arguments, so the two permitted values are explicit. Permission follows the UID: remove this policy before deleting/reassigning the account. [6]

Reads are unprivileged:

```sh
/usr/bin/pmset -g
```

Writes use noninteractive sudo:

```sh
/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 1
/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0
```

`-n` prevents sudo from blocking for terminal input; an execution error or nonzero result activates the configured AppleScript fallback. It does not bypass sudoers or prove that the helper was installed correctly. File-presence detection in the app is only a hint, not an authorization test. [6]

The separate boot-reset daemon is not an IPC helper. The installer installs `/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist`, whose `RunAtLoad` invocation runs the fixed reset to `0`. Bootstrapping it during installation triggers the reset immediately, so install only while Clam is off. It is not a watcher and does not detect a mid-session crash.

### AppleScript administrator fallback

The app asks AppleScript to run only one of the two fixed `/usr/bin/pmset -a disablesleep N` commands with administrator privileges. It never incorporates arbitrary user command text into that sleep-setting command. The OS owns the authorization prompt; Clam neither requests nor saves a password. The prompt can be cancelled or fail, including when no usable interactive session exists. Authorization may be cached by the OS, so do not assume either a prompt on every call or a permanently prompt-free session. [7]

The **Install Helper…** menu action uses the same administrator mechanism for `/bin/sh <installer-path> --user <account>`. Unlike the fixed sleep command, this has variable path/account arguments; these must be independently shell-quoted, and the complete command must also be escaped correctly for AppleScript. The shipped installer is trusted code: inspect local sources before authorizing it.

## State, ownership, and restoration

A session starts by reading the current setting, not by assuming that normal sleep was previously enabled:

1. Read `/usr/bin/pmset -g`. Parse the `SleepDisabled` Boolean. If the successful output has no recognizable value, use the conservative prior-value default `0`; do not convert an execution/read failure into a successful observation.
2. Save `~/Library/Application Support/Clam/on.json`, recording the prior value, process ID, and timestamp, **before** changing `disablesleep`.
3. Request `disablesleep 1` and acquire the idle-sleep assertion. Only a completed transition counts as a successful On state. Repeating On for the same owned session is a no-op, so it must not overwrite the original snapshot with the newly enabled value.
4. If enabling/assertion acquisition fails after a possible setting change, attempt rollback to the saved prior value. Preserve recovery evidence if restoration fails.
5. On Off, quit, or recovery, restore the saved prior setting **before removing the marker**, and release the assertion. A failed restoration keeps the marker for retry; a marker-removal failure also remains visible rather than claiming complete cleanup.

A prior value of `0` restores normal sleep; a prior value of `1` restores `1`. Off means Clam no longer owns a completed active session, not that another tool's sleep-disable choice has been undone. An error state may still have an owned active session or unresolved recovery work; the UI must not equate “error” with “safe to close and store.”

The marker survives ordinary process lifetime and provides best-effort crash recovery. It is not a lease recognized by macOS, a watchdog, or a transaction with the power-management subsystem. There is an unavoidable interval between separate disk and system-setting operations. Atomic file replacement can prevent partial ordinary writes, but is not a guarantee that data survives every filesystem/hardware/power-loss scenario. Corrupt/unreadable markers must be reported, not silently treated as “nothing to restore.”

On launch, Clam restores any remaining marker before accepting a new session. The app enforces a single running instance for its normal launch context; the PID/timestamp are recovery metadata, not a system-wide lock. Another account or unrelated sleep tool can still modify the same global setting. There is no compare-and-swap or ownership token in `pmset`: restoring the snapshot can overwrite another actor's newer decision. Use one owner, do not interleave tools, and inspect the actual setting when diagnosing a conflict.

### Low-battery policy

The core optionally accepts a `BatteryReader` and exposes `checkBattery()`. The app supplies an IOKit internal-battery reader and invokes the check on its serialized work queue immediately after enabling and every 30 seconds. During an owned active session, an on-battery reading strictly below 10% triggers the ordinary Off/restoration path. Exactly 10%, AC power, and an absent usable battery reading do not trigger a low-charge transition. Read errors and restoration failures are surfaced.

This policy restores the saved prior setting rather than forcing `0`: a prior `1` stays `1`. It cannot guarantee emergency sleep, timely delivery of a timer, successful authorization, or safety when the process has crashed. If noninteractive sudo fails, a low-battery restoration can need the AppleScript administrator prompt. It is a best-effort safeguard, not permission to leave a running Mac in a bag.

## Failure and recovery coverage

“Covered” below describes the intended recovery path, not a guarantee that the OS, authorization, disk, or hardware will cooperate.

| Event | Covered path | Not guaranteed / residual risk |
| --- | --- | --- |
| Ordinary Off or menu Quit | Restore saved prior setting, release assertion, then remove recovery evidence after successful restoration | Authorization, `pmset`, or storage can fail; do not treat the failed operation as successful cleanup |
| Repeated On | Preserve the first snapshot; no second owned session | Does not stop external writers |
| Enable or assertion failure | Attempt rollback to prior value; retain marker when restoration fails | Rollback itself can fail; requested state may have partially changed |
| Handled termination signals | Route supported signals to serialized cleanup rather than doing Foundation/process work inside an unsafe signal handler | Cannot cover unhandled signals, blocked/hung cleanup, or an imminent forced termination |
| Normal application termination/logout/shutdown | Attempt cleanup through application termination handling | macOS may terminate before completion; administrator UI may be unavailable; not a shutdown guarantee |
| Crash, Force Quit, `kill -9` | A later launch can restore the saved marker; installed daemon resets to `0` at the next successful boot | No cleanup at death; the global setting can stay `1` until relaunch, reboot, or manual repair; the process assertion disappearing does not reset `pmset` |
| Relaunch with marker | Restore its saved prior value before a new active session | Requires readable marker, functioning commands, and authorization; may prompt |
| Successful installed boot daemon | Reset `disablesleep` to `0`, deliberately favoring normal sleep regardless of prior value | Requires daemon installed, enabled, and actually executed; not a continuous watchdog; does not clear a user's marker |
| Kernel panic or sudden power loss | On the next boot, the installed daemon attempts reset; later app launch can use surviving marker | No code can clean up during the failure itself; data may not survive; no Clam boot reset without the daemon |
| Prior setting was `1` | Normal Off/relaunch recovery preserves `1` | Boot reset intentionally differs: it writes `0`; a surviving marker may restore `1` again at relaunch |
| Other tools or users change `disablesleep` | Read-before-enable preserves the observed starting value | No global exclusivity; later restore/reset may overwrite their setting |
| Charge below 10% while on battery | Best-effort serialized polling attempts ordinary Off and restores the saved prior value | Up to a polling interval or longer before action; reads/authorization/restore may fail; prior `1` stays `1`; not emergency protection |
| Thermal emergency, exhausted battery, or unsupported hardware/OS | Document and manually verify the actual platform | No promise to suppress emergency sleep/shutdown or keep unsupported hardware awake |

### The uncatchable-crash window

`SIGKILL` cannot be handled. The OS releases process-owned assertion resources, but the global `pmset` setting is not process-owned and can remain changed. Clam does not install a continuous watchdog. The available recovery paths are relaunch, manual `sudo pmset -a disablesleep 0`, or the installed boot-reset daemon at the next boot. A panic or power loss has the same fundamental absence of user-space cleanup, with additional storage durability uncertainty.

The boot job intentionally favors a known `0` over preserving an unknown or stale global value. It cannot read every user's private recovery marker and does not coordinate with other tools. A saved prior `1` remains meaningful to relaunch recovery and can therefore be re-applied after the boot reset. If manually resolving recovery, restore the desired setting first and then deliberately discard stale marker state; deleting the marker alone does not change system power policy.

## Safety and platform verification

Keeping a closed Mac awake can drain the battery and produce substantial heat. Never leave it enabled inside a bag or enclosure, and never assume a low-battery or thermal safeguard will make that safe. Turn Clam off, inspect the setting, and verify that the Mac can sleep before transport. Keep tests brief, attended, ventilated, and noncritical.

Linux core tests can establish state-machine and parser behavior against controlled dependencies, not real macOS power behavior. Even macOS unit tests do not establish lid-close operation. The [README's manual verification procedure](../README.md#safe-macos-verification) uses `pmset -g | grep SleepDisabled`, a brief battery/no-external-display lid-close test, and `pmset -g log | grep -i sleep`; these are instructions to the operator, not claimed results. Repeat verification after relevant OS/hardware changes.

## Primary references

1. Apple IOKit [`PreventUserIdleSystemSleep` documentation](https://developer.apple.com/documentation/iokit/kiopmassertiontypepreventuseridlesystemsleep) and [IOPMLib.h source, including explicit lid-close/low-battery exceptions](https://github.com/apple-oss-distributions/IOKitUser/blob/main/pwr_mgt.subproj/IOPMLib.h).
2. Apple open-source PowerManagement [`pmset` implementation](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.m) and [`pmset` manual source](https://github.com/apple-oss-distributions/PowerManagement/blob/main/pmset/pmset.1). Also consult `man pmset` on the actual target Mac; source from another OS generation is not a promise of local behavior.
3. Apple [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice), [`register()` and daemon approval requirements](https://developer.apple.com/documentation/servicemanagement/smappservice/register()), and [updating helper executables/bundle layout](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos).
4. Apple [notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).
5. Apple [Creating XPC Services](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingXPCServices.html) and [TN3127: Inside Code Signing — Requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). These describe the building blocks; a secure privileged protocol still requires explicit implementation and review.
6. Sudo project [`sudoers` manual](https://www.sudo.ws/docs/man/sudoers.man/) and [`sudo` manual, including `-n`](https://www.sudo.ws/docs/man/sudo.man/). Consult the installed macOS manuals for the shipped version.
7. Apple [TN2065: `do shell script` in AppleScript](https://developer.apple.com/library/archive/technotes/tn2065/_index.html), including administrator privileges and shell quoting.
