# Mac Tools utilities

Mac Tools 1.2.0 adds eight tools for everyday Mac problems. Six run directly in
the manager; ScrollSplit and LinkRoutes are separate apps with centralized
settings. Diagnostic data stays local unless you explicitly copy a report or
run a website check. There is no cloud telemetry.

## Permission Doctor

Inspect installed identities, signatures, renamed duplicate copies, running
bundle paths, and each app's settings bridge. DockPeek and ScreenWren report
permission checks from their own diagnostic executable. ScrollSplit queries
the matching running app for live permission and event-tap state when available;
unknown status stays unknown. Permission Doctor provides System Settings links
and restart guidance. It does not edit privacy databases or reset grants.

## Startup Detective

Browse startup service definitions with executable paths and parent-app
attribution. Filter missing targets or include macOS services; reveal definitions
in Finder and open Login Items. A definition's presence is not proof that it is
enabled or running. Modern background registrations are shown separately when
available. The utility never disables arbitrary services.

## SleepPeek

See current sleep assertions, attributed applications, and recent sleep/wake
evidence from a bounded native power-management log. History keeps the newest
128 KB and at most 40 events; no recent event in this window does not establish
that the Mac never woke. Unknown attribution is shown explicitly.

## SpaceWatch

Choose a local folder and scan its allocated size, largest files, and subfolders.
Completed readable scans save a private local baseline for the next comparison;
growth is measured between scans, never invented from historical estimates.
Scanning stops at 50,000 entries or 30 seconds and retains 200 largest files.
Cloud items, dataless files, symlinks, packages, and other volumes are skipped;
the interface reports incomplete coverage. Allocated bytes can differ from
reclaimable space on APFS.

Review selected files before moving them to the native Trash. Their scan
membership, root, ancestor paths, device/inode, size, and modification time are
rechecked first. System and Library files are protected. There is no automatic
cache removal or permanent deletion.

## HogWatch

Inspect process CPU and memory without collecting command arguments or
environment variables. Optional watching samples only while the page is open;
interval and threshold are saved in Mac Tools preferences. Sustained activity
requires multiple readings and verified process identity. CPU readings do not
claim exact battery drain, energy use, temperature, or minutes remaining.

Graceful Quit is offered for identified apps owned by the current user, after
confirmation and a fresh process/app identity check. Apps can ask to save work
or refuse to quit. No background process is automatically killed.

## NetPeek

Run checks against an explicit HTTP/HTTPS website: active interfaces, system
network path, default route, DNS, and server response/TLS. HEAD requests read
headers only with bounded deadlines and no cookies, stored credentials, cache,
redirect following, or persistent browsing history. An optional, visible Apple
connection reference is off by default. HTTP errors distinguish a reachable
server from a transport failure; results do not guess that a VPN caused trouble.
Native DNS resolution has no safe cancellation API; caller waits are bounded
and only one outstanding resolver worker is allowed.

## ScrollSplit

Install and open ScrollSplit, then explicitly enable it and grant requested
Accessibility/Input Monitoring access. Vertical and horizontal wheel direction
and speed are configured in Tool Settings or its native settings. It starts
disabled and does not request consent from the CLI bridge or launch-at-login.
Continuous events—including trackpads and some high-resolution mice—pass through
unchanged. Wheel fractional deltas and unrelated event fields are preserved.
See [ScrollSplit's guide](../ScrollSplit/README.md).

## LinkRoutes

Choose a fallback browser, add ordered hostname rules, and select a supported
browser profile when needed. Preview a route before using it. Default-browser
registration and restoration are explicit native settings actions. Rules match
exact domains or bounded subdomains, never similar-looking suffixes. A missing
chosen profile blocks the route and opens settings instead of switching accounts.
No persistent link history is recorded. See [LinkRoutes' guide](../LinkRoutes/README.md)
for supported browsers and profile limitations.
