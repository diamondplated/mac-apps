# AGENTS.md — Sift

Guidance for AI agents working inside `sift/`. Read this before editing. The narrative and
setup live in [README.md](README.md); this file is the working contract — what must not break, and
how to prove you didn't.

## What Sift is

A native Mac tool: drop a file in, explore it instantly. **One SwiftPM package, one binary** —
SwiftUI/AppKit window over a Swift engine (`Session`, an actor) over a vendored `libduckdb`.
No Python, no server, no web view: the 2026 rewrite deleted all three. DuckDB reads files
**in place**, so size is not the constraint.

Sift reaches **nothing until a user asks it to**: with no `connections.json` the posture is
`allowRemote: false`, DuckDB's network filesystems are disabled by name, and `httpfs`/`azure`
are never loaded — nor installed, which is a separate promise, because `harden()`'s deny list
gates DuckDB's VFS and **not** its extension installer. Saving a connection turns that on **from
the next launch** — the posture is frozen when the `Database` opens and cannot be widened or
narrowed inside it, so `addConnection` on a strict session writes the file and the Keychain and
stops there: it installs nothing (that would be the outbound request this paragraph forbids) and
registers no secret (RE-MEASURED: `CREATE SECRET (TYPE s3|azure)` is refused outright without the
extension — an earlier "it needs no extension" measurement was taken on a `Database` that had not
been `harden()`ed, so DuckDB autoloaded one behind it). Credentials live
in the Keychain; a SAS query string is memory-only for one open. The only listener anywhere is
`LoopbackHTTPServer` — the oracle every remote test and five `--verify` checks read their
verdict from — which binds 127.0.0.1 on an ephemeral port, is started only by tests or
`--verify`, and **must never grow a wildcard bind**.

## The one rule: tests are the spec

`Tests/**` is the source of truth for behavior — tests declared across `DuckDBKitTests`,
`SiftCoreTests`, `SiftEngineTests`, `SiftUITests`. The remote tests carry the `remoteFact` prefix and
are gated behind `SIFT_REMOTE_FACTS=1`: those are the ones allowed to `INSTALL` an extension over
the network, and CI runs them as a separate step.

🔴 **"Offline" means the default run makes no REQUEST, not that it passes without one**, and the
distinction is load-bearing: for the whole of Phase 1 the suite was offline-tolerant (its assertions
were written `!= nil` rather than `== .loaded`) while a dozen ungated tests fetched `httpfs` and
`azure` from `extensions.duckdb.org` on any machine that did not already have them. Two rules keep
it true now. A test that builds a **permissive** `Session`, or that needs `CREATE SECRET` to bind,
is gated on `extensionIsInstalled(_:)` — a bare `LOAD` against a `harden()`ed scratch database,
which answers from disk in microseconds and can never install. And `Database.networkInstalls`
records every name an `INSTALL` was issued for, so a test can assert what the process DID rather
than what is on disk afterwards; "the extension is present" has two provenances and a warm cache
makes them indistinguishable, which is exactly how a strict session's install survived the phase.

**Session startup never installs `delta` or `excel`.** It attempts LOAD only. Opening an
Excel workbook (`.xlsx`/`.xlsm`) or Delta directory when its extension is missing produces a
typed download request. The app asks **Download and Open** or **Cancel**, names the extension
and `extensions.duckdb.org`, and explains that local file contents are not uploaded. Only
explicit approval downloads that extension and retries the queued open. Installed extensions
need no prompt. The CLI refuses by default; `--allow-extension-download` explicitly permits the
required first-use download. `--verify` never accepts that permission and skips absent formats.
Default test helpers also LOAD only; cold extension installs belong to gated `remoteFact` tests.
**Never weaken a test to make a change pass.** If a test pins a symbol or an output string, that
is a contract, not an accident. The suite runs fully **in parallel** and nothing is
`.serialized`; a test that only passes serialized is a bug in the test.

The house bar is **mutation**: when you add a guard, delete it on purpose and confirm its test
goes red. This branch caught 15+ tests that passed while guarding nothing; the discipline is not
optional. Temp paths go through `Tests/TestSupport`'s `TestTemp` — a bare
`FileManager.default.temporaryDirectory` write is how this suite once leaked 24 GB.

## How to build, test, verify — run these, don't assume

```bash
./scripts/fetch-duckdb.sh          # once, needs network — the pinned prebuilt libduckdb
swift build && swift test          # warning-free is the bar
swift run sift --verify            # the engine end to end: 26 checks, every format
SIFT_REMOTE_FACTS=1 swift test     # includes tests that may INSTALL an extension over the network
./build-app.sh                     # -> ./Sift.app; verify by MOVING it away from the repo
```

`--verify` has six remote checks: five use `LoopbackHTTPServer`, while cache sweep uses
local files. Four skip when `httpfs` is not installed; strict posture and cache sweep
always run. HTTP checks cap their own `http_timeout`/`http_retries`. A check that cannot
run is not a check that passed. The verifier never installs missing local-format or remote
extensions; its scratch sessions only use extensions already present on disk.

After any engine or UI change, exercise it end to end against a **multi-million-row file** —
several real bugs here were invisible on small files. The window cannot be screenshotted on this
machine (no Screen Recording); the working capture is `cacheDisplay(in:to:)` on a live `NSView`,
control-render-first. `ImageRenderer` is measurably unstable for pixel comparison — don't.

**CI is a self-hosted MacBook Air; its toolchain step records the selected SDK**, not GitHub's `macos-15` any more, so
nothing now catches a break only an older SDK would reject (hosted macos-15 caught Sendable
inference and system-color resolution breaks multiple times). It runs on PRs and on pushes to
`main`; loopback-HTTP tests flake when the Air is busy (#5). Push and read CI anyway.

## Architecture, and where the state lives

- `Sources/SiftCore/` is **pure, Foundation-only** (enforced by the package graph): identifier
  quoting, SQL generation, the SELECT-only gate's pure half, format detection, profiling policy,
  staging policy, snippets. Logic goes here, where it costs milliseconds to test.
- `Sources/SiftEngine/Session.swift` is the **only** stateful module: an actor owning the
  catalog, background jobs, staging, profiling. Read its header before touching concurrency —
  the `pagingConnection` invariant (**eight** users, no suspension between acquire and last use)
  is measured, load-bearing, and documented there — and the count is part of the contract, because
  it said six through the two commits that made it eight.
- `Sources/DuckDBKit/` wraps the C API: `Database`, `Connection`, chunk decoding, `harden()`.
- `Sources/SiftUI/` is every view and view-model; `Sources/SiftApp/` is `@main` + menus +
  LaunchServices **and is untestable by construction** (a test target cannot import an
  executable target) — nothing with a decision in it goes there. Same for `Sources/sift/`
  (the CLI): logic lives in `SiftEngine/Verification.swift`.

## Frozen contracts — changing these breaks the app silently

Run `python3 scripts/check-contracts.py` for the formatter ban and no-new-`try?` gate.
The reasoned `scripts/optional-try-baseline.json` records existing sites, including
unresolved debt; it does not certify that every suppressed failure is safe. New sites or
copies need explicit review, and removed sites must be removed from the baseline.
`python3 scripts/test-contracts.py` proves the gate rejects representative mutations.

- Security/safety: the SELECT-only guard **plus** the newline subquery-wrap (the wrap is the
  real enforcement — a keyword blocklist is not); `harden()`'s settings, whose deny list names
  four filesystems and is skipped **only** by `harden(allowRemote: true)`, chosen once from a
  config file read before the `Database` opens; `~/.sift` and `remote-cache/` at `0700` with
  downloaded objects at `0600`; the atomic view→table swap; staged-data and downloaded-copy
  age-out/budget; one `Session` per home (`OpenHomes` — two on one home are two databases
  overwriting each other).
- Credentials: the Keychain is the only store; `connections.json` (0600) carries account names
  and key ids and no secret material; `CREATE SECRET` is engine-side, `TEMPORARY`, and bound
  never interpolated; a SAS query string is memory-only for one open — `RemoteURL.sanitized` is
  the display and persistence form and `wireURL(_:)` is the single choke point that re-attaches
  it. See `SECURITY.md` for the full list and `--verify`'s `remote credential` check for the
  greps that hold it.
- Data truth: NULL vs `''` vs `'N/A'` stay distinct end to end (`allow_quoted_nulls=false`,
  `glyph(for:kind:)` — the UI never calls `Cell.display`); `ignore_errors` + `TRY_CAST`
  bad-row accounting; exact counts via the all-varchar relation, never a bare `count(*)` on
  the typed view; approx-distinct is clamped; a `_delta_log/` dir is read via `delta_scan`,
  never a raw parquet glob; cell rendering lives in the engine so the app and the CLI cannot
  disagree; no `NumberFormatter`/`DateFormatter`/`ISO8601DateFormatter` anywhere user-visible
  (four locale bugs shipped that way, one deleted user data).
- Every engine error is **one clean sentence** (`SiftError.description`) — never a parser dump,
  never swallowed with `try?`. That contract was broken and repaired four times; don't be five.

## DuckDB facts this code depends on (re-verify before bumping the pin)

The current library pin is **2.0.0**. `Database.openingSettings` preserves 1.5.6 storage
compatibility and bounds the new async I/O pool at four workers; SQL worker defaults stay intact. The observations below were first measured on
1.5.5; `DuckDB155FactsTests.swift` keeps that historical name while enforcing them
against the current library. `linkedLibraryIsThePinnedDuckDBVersion` checks the loaded pin.

Executable pins live in `Tests/DuckDBKitTests/DuckDB155FactsTests.swift`; extension loading
is also covered by `SmokeTests.swift` and the gated `RemoteFactsTests.swift`. Re-verify against
the vendored dylib — not folklore:

- `sniff_csv` reports an absent quote/escape/comment as the literal string `'(empty)'` —
  normalize before feeding it back to `read_csv`.
- `reject_scans()` / `reject_errors()` **do not exist**; bad rows are found with `TRY_CAST`
  against an all-varchar read.
- `count(*)` on a CSV view uses projection pushdown and ignores uncastable rows, so it
  disagrees with `SELECT *`. Count the all-varchar relation.
- `read_xlsx` takes `sheet =>` (not `sheet_name`) and can't list sheets — hence
  `XLSXSheets.swift` parsing the OOXML directly.
- Delta time travel is `version => n`; `AT (VERSION => n)` does not parse.
- The `delta` and `excel` extensions need one approved online `INSTALL` when missing;
  `loadExtensions(..., installMissing: false)` performs LOAD only. Explicitly authorized
  installs use LOAD→INSTALL→LOAD; autoloading is deliberately off.
- `approx_count_distinct` overshoots (102 for 100 distinct on 2.0.0; historically 340 for 300 on 1.5.6) — clamped in the profile.
- `duckdb_tables().estimated_size` is a **row count, not bytes** — staged bytes are measured
  from storage blocks instead.
- `duckdb_interrupt` before execution starts is **swallowed**; cancelling means hammering it
  in a loop until the job reports stopped (`StageJob`).
- `sortedRelation`'s TEMP TABLE is visible only to the connection that created it — the reason
  `pagingConnection` exists at all.

The remote measurement document has twelve sections (including CI and shipped-path
observations), rather than twelve independent test cases:
`docs/superpowers/specs/2026-08-16-duckdb-remote-facts.md` with executable pins for sections 1–9 and 11 in
`Tests/DuckDBKitTests/RemoteFactsTests.swift`. The four the rest of the engine is built on:
`disabled_filesystems` only ever GROWS inside a `Database` and reads back `''`, so a posture is
chosen at open and never toggled; `CREATE SECRET` binds every value but not its own name, and
secrets are Database-scoped and `TEMPORARY`; remote CSV is a whole-object download (100 % to
sniff, 200 % to scan) while remote parquet really does range-read (0.2 % for a `count(*)`); and
`enable_external_file_cache` is **on by default**, so a request-count assertion proves nothing
about Sift's own download decision unless the test turns it off first.

## Style

Ponytail is on: prefer the shortest change that keeps behavior, delete over add, reuse what's
here. But never simplify away validation, security, error handling, or accessibility, and never
delete a comment that records a **measured fact** — compress it if you must, keep the fact.
Cuts, not churn: don't reformat code you're keeping, don't rename public symbols.
