# Clam

Clam 0.1.0 is a local menu-bar app for macOS 13 or later. It requests that a Mac stay awake with its lid closed, including on battery without an external display, by changing the system-wide `pmset disablesleep` setting and holding an IOKit idle-sleep assertion. Its bundle identifier is `com.jimbo23.clam`.

**This is not a guarantee that every Mac or macOS release will remain awake.** `disablesleep` is not a documented, stable public lid-sleep API. Firmware, thermal protection, battery state, system policy, and OS changes can override or alter the result. The Foundation core also builds on Linux; Linux cannot run the menu-bar app, IOKit, `pmset`, or the macOS helper.

**Never put an enabled Mac in a bag or other enclosed space.** A closed lid does not make a running Mac safe to store. Expect heat and battery drain. Turn Clam off and verify sleep is restored before transport. Do not rely on Clam for critical unattended work or as a substitute for thermal or low-battery protection.

## Install

### Homebrew

```sh
brew tap jimbo23/tap
brew install --cask jimbo23/tap/clam
```

Releases are built by GitHub Actions and are **ad-hoc signed only** (no Developer ID, no notarization).

> **Gatekeeper / quarantine note.** Because Clam is not notarized, macOS blocks it on first launch after `brew install` (or after downloading the zip) with a "cannot be opened" / "Apple could not verify" dialog. To allow it, either:
>
> ```sh
> xattr -dr com.apple.quarantine /Applications/Clam.app
> ```
>
> or try to open Clam once, then go to **System Settings → Privacy & Security** and click **Open Anyway** (macOS 15+ requires this route instead of right-click → Open).
>
> After it launches, pick **Install Helper…** from the menu (while Clam is Off) for the one-time admin step.

Release zips and their `.sha256` files are on the [Releases page](https://github.com/jimbo23/clam/releases).

### Manual local installation

Build the local ZIP as described below, unzip `dist/Clam-0.1.0.zip`, and copy `Clam.app` into `/Applications`. Do not run the app from inside the ZIP or from a temporary unpacking location.

A locally built/ad-hoc-signed app is not Developer ID signed or notarized and may be blocked by Gatekeeper. Only after inspecting and trusting the app, a local quarantine removal is:

```sh
xattr -dr com.apple.quarantine /Applications/Clam.app
open /Applications/Clam.app
```

Removing quarantine is a deliberate bypass of a security check, not signing, notarization, or proof that the software is safe. Organizational policy may still prevent execution. See Apple's [Gatekeeper guidance](https://support.apple.com/102445).

### Recommended one-time helper installation

Start with Clam **Off**, then select **Install Helper…** in its menu and approve the macOS administrator dialog. This installs the narrow sudoers permission and the boot-reset daemon. It is not a general-purpose root helper or a persistent privileged XPC service.

Alternatively, from the source checkout:

```sh
sudo /bin/sh scripts/install-helper.sh
```

The script normally selects `SUDO_USER`. When installing for a specific local account, supply its short account name explicitly:

```sh
sudo /bin/sh scripts/install-helper.sh --user "$(id -un)"
```

The menu invokes the same installer with an explicit user, safely quotes the script path and account name, and asks AppleScript to run it with administrator privileges. Installation is allowed only while Clam is off: bootstrapping the daemon immediately resets `disablesleep` to `0`.

Installed system files:

- `/etc/sudoers.d/clam`: grants the selected user only the two fixed `pmset` commands shown in [Mechanism](docs/MECHANISM.md).
- `/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist`: a root `RunAtLoad` job that resets `disablesleep` to `0` when bootstrapped and at boot.

Without the helper, or if noninteractive sudo fails, Clam automatically falls back to an AppleScript administrator prompt for the fixed sleep-setting command. Cancelling or failing authorization is an error, not a successful toggle. Without the installed boot daemon, there is no Clam-provided boot reset.

## Use and recovery

Use the menu toggle to turn Clam on and off. The menu reports state/errors; **Quit** first attempts to restore the prior setting. Before enabling, Clam reads `pmset -g`, saves the prior `SleepDisabled` value to a recovery marker, and only then changes the global setting. An absent/unrecognized value defaults to `0`; a readable prior value of `1` is preserved and restored as `1`. A command/read failure is not treated as a successful read.

The marker is `~/Library/Application Support/Clam/on.json` and records the prior value, process ID, and timestamp. Turning off restores the prior value before deleting the marker. If restoration fails, keep that marker and resolve the reported authorization or command error. Relaunching Clam attempts recovery from a remaining marker rather than silently starting another active session.

Ordinary quit and handled termination signals attempt restoration. Force Quit/`kill -9`, a crash, kernel panic, or power loss cannot run reliable cleanup. The global setting can remain enabled until successful relaunch recovery, manual reset, or a successful installed boot-reset job. The daemon deliberately resets to `0`, not the saved prior value. See the [coverage table and recovery caveats](docs/MECHANISM.md#failure-and-recovery-coverage), including interaction with a prior value of `1`.

| Event | Fail-safe path | Not guaranteed |
| --- | --- | --- |
| Off, Quit, SIGTERM/SIGINT, application termination | Restore the saved prior value and release the assertion | Authorization/command failures or forced termination can prevent cleanup |
| Crash or Force Quit/SIGKILL | Restore a surviving marker on next launch | No immediate reset; sleep can remain disabled until relaunch or reboot |
| Reboot after crash, kernel panic, or power loss | Installed RunAtLoad daemon resets `disablesleep` to `0` | Requires a working, enabled daemon; no cleanup during the failure itself |
| Battery below 10% while On | Best-effort polling attempts Off | Delayed/failed reads, prompts, or saved prior `1` can prevent normal sleep |
| Other tools, thermal protection, unsupported hardware | No exclusive control or hardware guarantee | Never rely on Clam to make enclosed/bag operation safe |

Clam does not exclusively own this system-wide setting. Avoid running other sleep-control tools or enabling Clam in multiple user sessions. Restoration can overwrite another tool's later change; Clam's single-instance app behavior does not provide a system-wide cross-user lock. **Off means Clam no longer owns an active session, not necessarily that `SleepDisabled` is `0`.**

If you need to restore normal sleep manually, first quit Clam and stop other sleep-control tools, then run:

```sh
sudo pmset -a disablesleep 0
pmset -g | grep SleepDisabled
```

A remaining recovery marker can cause a subsequent launch to restore its saved value, including `1`. Do not delete the marker as a substitute for restoring the setting. After a successful manual reset, remove a stale marker only if you deliberately want to discard that saved recovery state.

### Launch at Login

The optional **Launch at Login** menu toggle registers/unregisters `SMAppService.mainApp` for the current user. Use the packaged `Clam.app` in `/Applications`, not `swift run Clam`. This opens the menu-bar app at login; it does **not** automatically turn Keep Mac Awake on. Startup recovery still restores any stale marker.

The menu reads macOS's actual registration status rather than saving its own preference. A checked toggle with an approval hint means registration is pending, not enabled: choose **Open Login Items Settings…** to open **System Settings > Login Items** and approve Clam. You can also uncheck it to cancel registration. Status refreshes when the menu opens or the app becomes active, including changes made in System Settings. Registration/unregistration failures remain visible in the menu. Turn this option off before uninstalling Clam.

### Best-effort low-battery safeguard

While Clam owns an active session, the app checks the internal battery immediately after enabling and then every 30 seconds. If the Mac is running on battery and the reported charge is **strictly below 10%**, it attempts to turn Clam off and restore the prior setting. AC power does not trigger this policy; exactly 10% is not below the threshold.

This is polling, not emergency battery protection. A read failure or failed restoration is reported, and restoration may require an administrator prompt if the helper is unavailable. A saved prior `1` restores `1`, so the safeguard does **not** promise to enable sleep. It cannot protect a crashed/hung app, prevent heat, guarantee a timely sample, or make bag storage safe.

## Build and test

Requirements: Swift tools 5.9 or newer, using Swift 5 language mode (including with Swift 6). The macOS application requires macOS 13+ and Apple's SDK/command-line development tools.

```sh
swift build
swift test
```

On macOS, run the development executable with `swift run Clam`, or build the installable application:

```sh
./scripts/build.sh
```

Outputs are `build/Clam.app` and `dist/Clam-0.1.0.zip`. Local builds use ad-hoc signing unless a signing identity is supplied. On Linux, use `swift build`/`swift test` for the Foundation core and platform-conditional executable stub; do not try to package or run the macOS UI there. Core tests do not validate real administrator authorization, launchd installation, IOKit behavior, or lid-close behavior.

Local verification: `swift build && swift test` passed with the installed Swift 6.4.1 toolchain in Swift 5 language mode: 41 XCTest cases, zero failures; the Linux executable stub also ran. A temporary smoke harness exercised the actual login-item model's registration, approval, cancellation, error, and external-status transitions against simulated framework interfaces, not macOS services. The old `.local-tools` toolchain was removed.

Earlier verification exercised real subprocess execution and JSON marker storage through On/Off, prior-value restoration, stale recovery, sudo-failure fallback, low-battery policy, and signal cleanup; shell syntax, Linux platform guards, and plist parsing also passed. macOS compilation, menu UI, actual login-item registration/approval, administrator dialogs, helper installation, universal signing/packaging, and physical lid-close behavior remain unverified on this Linux host.

### Signing and notarization — documentation only

A future distributable macOS build should sign nested code and the application with a valid **Developer ID Application** certificate, enable the hardened runtime, and use secure timestamps and only necessary entitlements. The build interface accepts an existing local identity:

```sh
DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)' ./scripts/build.sh
```

This is an example, not an identity supplied by the project. Ad-hoc signing cannot replace Developer ID trust. Signing alone does not notarize an app. For distribution, the maintainer would submit the signed archive with `xcrun notarytool submit … --keychain-profile … --wait`, inspect the result/log, staple the accepted ticket to the app with `xcrun stapler staple …`, and recreate the final ZIP from that stapled app. Keep credentials out of the repository. These are documentation-only instructions: no submission, publication, credentials, or notarization are provided or implied. Follow Apple's [notarization guide](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution).

## Publishing the tap (for later)

These are future maintainer instructions only; no repository creation, upload, or publication is performed by the build script.

1. Create the GitHub source repository `jimbo23/clam` and tap repository `jimbo23/homebrew-tap`.
2. Keep the version in `Resources/Info.plist` and `Casks/clam.rb` aligned. On macOS, run `./scripts/build.sh`; follow the signing/notarization guidance above before distribution.
3. Upload the final `dist/Clam-<version>.zip` to the `v<version>` release in `jimbo23/clam`, matching the cask's existing download URL. If notarization/stapling changes the archive, use the final archive for the checksum.
4. Run `shasum -a 256 dist/Clam-<version>.zip` and replace the `sha256 "TODO..."` placeholder in `Casks/clam.rb` with that checksum. Remove the now-obsolete unpublished/TODO comments and caveats.
5. Copy the completed cask to `homebrew-tap/Casks/clam.rb`. Verify with `brew style ./Casks/clam.rb` and, with the tap available, `brew audit --cask --online jimbo23/tap/clam`; resolve findings before publishing the tap.

Homebrew already has an official [`clamshell`](https://formulae.brew.sh/cask/clamshell) cask with a similar purpose. Its token is `clamshell`, not `clam`, so there is no token conflict; use `jimbo23/tap/clam` to identify this cask explicitly.


## Safe macOS verification

These are **manual verification instructions, not claims of tests already performed**. Run on the intended Mac and OS version, save work first, use a ventilated hard surface, and keep the test brief and attended. Record the prior setting so that a deliberate prior `1` is not mistaken for a restoration failure.

1. With Clam off, inspect the baseline:

   ```sh
   pmset -g | grep SleepDisabled
   ```

   No matching line is inconclusive, not proof of either setting. Inspect the complete `pmset -g` output if necessary.
2. Turn Clam on, complete any administrator prompt, and run the same command. Check for `SleepDisabled 1` and confirm the menu does not report an error.
3. With **battery power and no external display**, briefly close the lid while a harmless, observable background task runs. Reopen the lid promptly and assess whether the task actually continued. Do not use a bag, a critical job, or an unattended overnight run as a test. A successful command or menu state alone does not prove the Mac remained awake.
4. Inspect power-management history, correlating timestamps with the test:

   ```sh
   pmset -g log | grep -i sleep
   ```

   Logs contain unrelated events; a matching line alone is not a verdict.
5. Turn Clam off and confirm the original setting is restored. Repeat with normal Quit if needed. If authorization/restoration fails, use the manual reset above and retain recovery evidence until resolved.
6. Separately verify helper installation and reboot reset only when you can safely reboot and no other tool depends on a prior `1`. The boot job intentionally resets to `0`. A stale marker with prior `1` may restore `1` again on the next Clam launch.
7. From `/Applications/Clam.app`, enable **Launch at Login**. If approval is required, verify the settings button opens Login Items and approve Clam. Reopen the menu after changing the setting externally and confirm its status refreshes. Disable the toggle and verify the login item is unregistered; enable it again and, when safe to log out, confirm login opens Clam without automatically enabling Keep Mac Awake.

Do not infer coverage of other hardware, macOS versions, emergency sleep, thermal shutdown, or sudden power loss from one successful test.

## Uninstall

Turn Clam off and quit it first. Explicitly reset normal sleep, then remove the helper using the supplied uninstaller:

```sh
sudo pmset -a disablesleep 0
sudo /bin/sh '/Applications/Clam.app/Contents/Resources/uninstall-helper.sh'
```

The uninstaller removes `/etc/sudoers.d/clam` and unloads/removes `/Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist`. Run it before deleting the app. From a source checkout, the equivalent is `sudo /bin/sh scripts/uninstall-helper.sh`; a checkout is not required when the installed app is still available. Removing just `Clam.app` does not remove system-wide helper files.

If the script has been lost, the manual recovery sequence is:

```sh
sudo pmset -a disablesleep 0
sudo launchctl bootout system /Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist
sudo rm -f /etc/sudoers.d/clam
sudo rm -f /Library/LaunchDaemons/com.jimbo23.clam.bootreset.plist
```

`bootout` can report that an already-unloaded job is absent; investigate other failures rather than assuming the job stopped. Do not remove unrelated launchd or sudoers files.

After successful restoration and helper removal, delete `/Applications/Clam.app` and, if desired, the now-unneeded `~/Library/Application Support/Clam` directory. Do not discard a failed-restoration marker until the machine's setting has been repaired.

For a future published cask, `brew uninstall --cask jimbo23/tap/clam` uses the cask's uninstall actions to quit the app, unload the daemon, reset `disablesleep` to `0`, and remove the helper files. Approve any required authorization and resolve uninstall errors. The explicit script procedure above is also available before cask removal.

## Design details

See [Mechanism and safety boundaries](docs/MECHANISM.md) for the privilege-mechanism comparison, state/recovery ordering, limitations, and primary references.
