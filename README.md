# Mac Apps

Andrew's native macOS apps, one repository:

- **Mac Tools**, one app to install, update, open, and configure **DockPeek**,
  **ScreenWren**, **ScrollSplit**, **LinkRoutes**, and **StayLit**, and to install, update, and
  open **Latent** and **Sift**. Public downloads and automatic updates use
  [diamondplated/mac-tools-releases](https://github.com/diamondplated/mac-tools-releases/releases),
  a separate repository containing release artifacts, not app source.
- **[Latent](Latent/README.md)**, a folder-first photo viewer with a local AI
  enhancement pipeline. Formerly `diamondplated/latent`.
- **[Sift](Sift/README.md)**, drop a data file in and explore it instantly.
  Formerly `diamondplated/sift`.

Latent and Sift build and test on their own, and Mac Tools bundles a signed copy of
each. Their Homebrew casks in the
[diamondplated Homebrew tap](https://github.com/diamondplated/homebrew-tap) still
point at the archived standalone releases; Mac Tools updates a cask-installed copy
in place.
Everything here is MIT licensed.

| App | What it does | Requires |
| --- | --- | --- |
| Mac Tools | Install apps and manage all tool settings | macOS 14+ |
| [DockPeek](DockPeek/README.md) | Dock window previews, an ⌥Tab window switcher, Dock click actions, and window layouts that survive display changes | macOS 14+ |
| [ScreenWren](ScreenWren/README.md) | Precise screenshots, region recording, markup, redaction, text recognition, and a colour picker | macOS 26+ |
| [ScrollSplit](ScrollSplit/README.md) | Mouse fixes (wheel direction, speed, smoothing, side buttons, pointer acceleration) and keyboard overrides | macOS 14+ |
| [LinkRoutes](LinkRoutes/README.md) | Send links to chosen browsers and profiles by site or source app, and files to chosen apps by folder | macOS 14+ |
| [StayLit](StayLit/README.md) | Keep the Mac awake on your terms, and use the brightness and volume keys with an external display | macOS 14+ |
| [Latent](Latent/README.md) | Folder-first photo viewer with keyboard culling, burst grouping, and local enhancement | macOS 14+ |
| [Sift](Sift/README.md) | Explore CSV, Parquet, JSON, and Excel files instantly, with a Quick Look preview in Finder | macOS 14+ |

## Use the manager

Get **Mac Tools.app** from the [public downloads](https://github.com/diamondplated/mac-tools-releases/releases).
Releases use the project's persistent local signing certificate and are
**not notarized**. The update feed and archives are also signed with the
project's separate Sparkle key. Initial installation on another Mac may require
manual approval in macOS Privacy & Security.

Open **Mac Tools.app**. The **Library** lists every app with one action: Install,
Update, or Open. Select an app for its own page, which holds its settings, the
macOS permissions it needs, and a menu with Show in Finder, Quit, and Uninstall.
Uninstall moves the app to the Trash and keeps preferences and saved captures.
Choose another default browser in LinkRoutes before uninstalling it if it is your
current link handler; Mac Tools blocks removal until this is resolved.
Updates quit a running app, replace its bundle, and reopen it. A failed update
restores the previous bundle and reopens that copy.

In **Mac Tools → Settings…** (`⌘,`), choose **Only me** to install new apps in
`~/Applications`, or **All users** for `/Applications`. Updates keep each app's current location, including renamed
bundles. A conflicting bundle or multiple installed copies must be resolved
before installation; the manager never silently overwrites another app.

The app installers are included inside Mac Tools, so installing them works
offline and requires no development tools. Update Mac Tools itself to receive
new included app versions. The manager compares versions/builds and app contents
to recognize local rebuilds, and prevents downgrades. It reports unsupported
macOS versions before installation.

**Mac Tools → Settings…** (`⌘,`) has automatic daily checks and optional automatic
download and installation of manager updates. **Mac Tools → Check for Updates…**
also checks on demand. Sparkle verifies both the update feed and downloaded
archive against the release signing key. After a manager update, use **Update**
in the Library to install its newer tool versions.

## Tool settings

Select a menu bar tool in the sidebar, or choose **Settings…** in the tool's own
menu bar menu, which opens the same page. The page shows the tool's settings,
which use its existing preferences and apply to the running tool as soon as you
change them. Three things wait for a button: LinkRoutes rules (edit the list, then save
it), and ScreenWren's fixed size and saved sizes.

- **DockPeek:** launch at login, enable previews, include tabs, and preview
  dismissal delay.
- **ScreenWren:** launch at login, capture destination, quick-action thumbnail,
  selection adjustment, exact dimensions, aspect ratio, saved size presets,
  and all seven keyboard shortcuts, including clearing and restoring defaults.
- **ScrollSplit:** startup, enable state, vertical/horizontal direction, mouse-wheel
  speed, and current permission/runtime status. Turning it on for the first time
  happens in ScrollSplit's menu bar menu (**Turn On**), because macOS must ask the
  app itself for access.
- **LinkRoutes:** startup, fallback browser, ordered domain rules, subdomain
  matching, and supported browser profiles. Making it the default link handler is
  an explicit action in LinkRoutes' menu bar menu (**Make Default Browser…**).
- **macOS permissions:** each page lists the access its tool needs, with a direct
  link to the right System Settings pane. macOS owns approval. A permission shows
  a status only when the running tool itself reports it, so a tool that is not
  running, or an older version of one, shows the link alone.

Tools must be installed from a current Mac Tools build to expose centralized
settings. ScrollSplit and LinkRoutes have no settings window of their own; their
page here is their settings.

## Build and install from source

Building the full suite requires macOS 26+, Swift 6.2+, and the matching macOS SDK.
The build creates Universal 2 binaries for Apple silicon and Intel (Latent is Apple
silicon only; Mac Tools won't offer it on Intel) and preserves
each tool's bundle identity and signing requirements.

```sh
./build-app.sh
./install-app.sh --no-build
```

Output is `dist/Mac Tools.app` and `dist/Mac-Tools-<version>.zip`. The installer stages
and verifies the manager, backs up an existing copy, installs to `/Applications`,
and opens it. Use the manager to install or update the apps.

ScreenWren uses its saved persistent signing identity and timestamp preferences
in ignored `ScreenWren/.screenwren-signing-identity` and
`ScreenWren/.screenwren-signing-timestamp` files. Alternatively set
`SCREENWREN_SIGNING_IDENTITY` and `SCREENWREN_SIGNING_TIMESTAMP` (`secure` or `none`).
The enclosing manager uses that identity too, without re-signing its payloads.
Without a persistent identity, builds use ad-hoc signatures for verification;
interactive manager/ScreenWren installation requires a persistent certificate.
Local signed builds are not automatically notarized.
The manager's pinned Sparkle dependency is downloaded during the first build.
The update signing key is stored in the native Keychain, separate from the app's
code-signing certificate. See [release packaging](docs/RELEASING.md) for Developer
ID signing, notarization, signed feeds, and publication to the public downloads
repository. Developer ID credentials are not currently provisioned; the notarized
release command fails until they are available.

To reuse already verified Universal 2 tool builds when changing only the manager:

```sh
./build-app.sh --reuse-payloads
```

Individual tools still build independently. DockPeek supports
`./DockPeek/build_app.sh --no-install --arch universal`; its original no-argument
build-and-install behavior is retained. ScreenWren's build and installation
instructions remain in its own README.

## Verify

```sh
./verify.sh
```

This tests all six packages, builds the suite, checks app identities, deployment
targets, Universal 2 architectures, nested signatures, archive extraction, and
ScreenWren, ScrollSplit, LinkRoutes, and StayLit headless self-checks. Use `./verify.sh --no-build` to verify a package
that was just built. Live screen captures are opt-in in ScreenWren's QA workflow.
GitHub Actions uses only Andrew's self-hosted macOS runners, with no hosted fallback
and no installation step.

For actual launch-at-login verification, see
[the one-time native login check](docs/LOGIN_VERIFICATION.md). Current-session
process checks are only a preflight; the final evidence comes from your next login.

## Repository layout

- `MacTools/`: native SwiftUI manager, installation/settings core, and tests.
- `DockPeek/`: independently runnable Dock preview utility and regression tests.
- `ScreenWren/`: complete screenshot app, login helper, resources, and tests.
- `ScrollSplit/`: menu-bar scrolling app, settings bridge, icon, and event tests.
- `LinkRoutes/`: browser routing app, settings bridge, icon, and rule tests.
- `StayLit/`: keep-awake and external display keys, settings bridge, icon, and tests.
- `Latent/`: standalone photo viewer, with its own README, CLAUDE.md, and CI (`latent.yml`).
- `Sift/`: standalone data explorer, with its own README, AGENTS.md, and CI (`sift.yml`).
- Root scripts and `.github/`: suite packaging, installation, and shared CI.

ScreenWren's, Latent's, and Sift's previous Git histories are retained as merge
ancestry; Latent's and Sift's old tags carry `latent-` and `sift-` prefixes. Its current
working-tree changes were imported too; see
[migration details](ScreenWren/docs/MIGRATION.md). The previous checkout remains
available as a migration backup. Continue development in this repository.
Build products, local signing choices, and credentials are excluded from Git.
