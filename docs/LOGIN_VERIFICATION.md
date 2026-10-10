# Verify startup at a real login

The startup toggle reports ServiceManagement's current state. A running process
in the current session is a useful preflight, but does not prove that the app
started at a new login.

Run the read-only current-session check:

```sh
./scripts/verify-login.sh --current
```

It prints JSON without creating a report file, launching or stopping either app,
changing startup settings, or capturing the screen. It checks DockPeek and
ScreenWren in `/Applications`, falling back to the current user's `~/Applications`.
It validates bundle IDs, code signatures, settings protocol support,
actual ServiceManagement state through each app's native settings CLI, and current
user process executable paths through macOS `proc_pidpath`. A same-name process
from another copy does not count as the expected installed app. ScreenWren requires
its persistent signing identity. DockPeek may use its existing verified ad-hoc
signature with its stable expected identifier. The report records `signingMode`
as `adhoc` or `persistent` for each app.

To arm one check for the **next login**, run:

```sh
./scripts/install-login-check.sh
```

The installer copies the verifier into the current user's private
`~/Library/Application Support/Mac Tools/Verification` directory and writes
`~/Library/LaunchAgents/com.andrew.mactools.verify-login.plist`. It deliberately
does **not** bootstrap or kickstart the job. It does not log out, reboot, modify
ServiceManagement settings, or start/stop apps. The job uses the native macOS
LaunchAgent mechanism and does not depend on Codex, this checkout, or a running
Mac Tools manager.

After the user chooses to log out and back in, macOS loads the job. It requires
launchd as its parent and compares the current GUI audit-session ID and boot
session UUID with the install baseline. The session must have changed. It then
checks the installed signed apps and waits up to 90 seconds for enabled apps to
appear as current-user processes running the expected executables. Signature and
settings inspection have separate bounded command timeouts before that wait.

Read the result here:

```text
~/Library/Application Support/Mac Tools/Verification/login-check.json
```

The report includes phase, UTC timestamps, session identity, bundle/signature
checks, startup status, matching process IDs, whether another copy is running,
and an overall result. It excludes screenshots, clipboard contents, shortcuts,
and unrelated preferences. `phase: preflight` always has `loginVerified: false`.
Only an observed check in a new login session can set `loginVerified: true`.
A pass means both apps had startup enabled and were observed running from their
expected installed bundles after login; it cannot prove that neither was also
launched manually during the observation window.

After its final report, success or failure, the job records a completion marker
and removes its matching LaunchAgent plist. It will not run again unless the
installer is explicitly run again. Logs are retained beside the report for
failures that occur before reporting. Reinstalling arms a fresh token; the previous
report remains available until the next check replaces it. Do not manually
bootstrap the job: a current-session invocation cannot establish login evidence.

To cancel a pending, unloaded check, remove only its plist:

```sh
rm ~/Library/LaunchAgents/com.andrew.mactools.verify-login.plist
```

The helper's deterministic tests require no app installation or login operation:

```sh
./scripts/verify-login.sh --self-test
```

They cover delayed startup, wrong executable paths, timeouts, disabled startup,
rejection of unchanged sessions or a caller other than launchd, and each app's
signing policy. Test output
is explicitly marked simulated and always has `loginVerified: false`.
