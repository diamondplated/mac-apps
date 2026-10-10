# Releasing Mac Tools

Mac Tools bundles DockPeek, ScreenWren, and Sparkle 2.10.0. Source stays private in `diamondplated/mac-tools`. Public binaries and signed update feeds live in [diamondplated/mac-tools-releases](https://github.com/diamondplated/mac-tools-releases/releases), a downloads-only repository. Ordinary `./build-app.sh` produces a universal local package; `./scripts/release.sh` prepares an isolated, verified distribution in `dist/release/`. Neither command installs apps. All CI runs on Andrew's `air` self-hosted Mac.

Version **1.1.0**, build **2**, uses the persistent local signing certificate and is **not notarized**. The `mac-tools` Sparkle key is already in the native Keychain, and its public key is committed in the manager plist. No private key was exported. Developer ID notarization remains unavailable until the Apple credentials below are provisioned.

## Native keychain setup

Preserve the existing credentials on Andrew's release runner. When enabling notarization or preparing another runner:

1. Install a valid **Developer ID Application** certificate and its private key in the runner user's login keychain. An Apple Development or self-signed certificate cannot substitute for Developer ID notarization. Set `DEVELOPER_ID_APPLICATION_IDENTITY` to that identity's name or fingerprint.
2. Run `xcrun notarytool store-credentials mac-tools-notary` interactively and provide the Apple credentials there. Set `NOTARYTOOL_PROFILE=mac-tools-notary`. Passwords and private keys remain in the native keychain.
3. Use the official [Sparkle 2.10.0 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0). Set `SPARKLE_TOOLS_DIR` to its `bin` directory; resolved SwiftPM artifact `bin` directories are also detected automatically. The existing key uses account `mac-tools`; `"$SPARKLE_TOOLS_DIR/generate_keys" --account mac-tools -p` prints only its public key for comparison with `SUPublicEDKey`. Keep using that key for subsequent releases. Do not generate a replacement key or commit private key material.
4. Permit the official Sparkle signing tools to read that key when Keychain Access asks. Unattended runs need an unlocked, accessible login keychain. Never work around this by copying private keys into GitHub Secrets.

The initial machine inspection found no valid Developer ID Application identity. Notarized release preflight fails until a certificate/private key and working notary profile are provisioned. A successful local package does not establish notarization.

Configure these nonsecret **repository variables on the private source repository**, where `.github/workflows/release.yml` runs:

| Variable | Value or purpose |
| --- | --- |
| `MACTOOLS_RELEASE_REPOSITORY` | `diamondplated/mac-tools-releases` (also derived from the plist if unset). |
| `LOCAL_SIGNING_IDENTITY` | Name or fingerprint of the existing persistent local certificate; required for `signedlocal` workflow runs because ignored signing files are absent from a fresh checkout. |
| `SPARKLE_TOOLS_DIR` | Optional absolute path to the official 2.10.0 `bin` directory on the runner. Leave unset to resolve the pinned SwiftPM tools. |
| `DEVELOPER_ID_APPLICATION_IDENTITY` | Valid Developer ID Application identity name/fingerprint, once provisioned. |
| `NOTARYTOOL_PROFILE` | Existing native notarytool keychain profile name, once provisioned. |

The current official tool installation is `/Users/andrew/GIT/mac-tools/.build/sparkle-tools/bin`; a stable configured path avoids separate Keychain access prompts for freshly resolved copies. Certificate/private keys, Sparkle signing key, and Apple credentials stay on the runner.

Configure the runner user's native `gh auth login` session with read access to the private source repository and release-write access to `diamondplated/mac-tools-releases`. The workflow intentionally uses that native session for publication: the source repository's automatic workflow token cannot publish to a separate repository. Do not add private keys or Apple passwords to GitHub Secrets.

Dispatch **Release Mac Tools** with the next version and mode **signedlocal** for the current distribution. Version `1.1.0` is already published and must not be reused. The workflow defaults to **notarized**, which intentionally fails until Developer ID and the notary profile exist. The publish checkbox defaults off. All work uses `[self-hosted, macOS, ARM64, air]`; no hosted runner fallback exists.

## Version and prepare

Update `CFBundleShortVersionString` (for example `1.1.0`) and increment the integer `CFBundleVersion` in `MacTools/Info.plist`. The build number must exceed every published release. Commit the release source before publishing; publishing requires a clean working tree. `release.json` records the exact source commit. When downloads use a separate repository, its release tag belongs to that repository; no private source is copied there.

```sh
./scripts/release.sh --notarized --version 1.1.0 --preflight
./scripts/release.sh --notarized --version 1.1.0
```

Notarized mode checks the Developer ID identity, authenticated notary profile, and matching Sparkle key **before building or publishing**. DockPeek's release copy receives Developer ID signing without changing its usual local designated requirement. ScreenWren builds from a separate source copy with the release identity. Each tool is notarized, stapled, and assessed before being embedded. Then the manager and complete Sparkle framework are signed inside out, the manager is notarized and stapled, and the final archive is regenerated. `codesign`, `stapler`, Gatekeeper, archive extraction, and Sparkle signature checks must all pass.

This order keeps payload tickets in place before the enclosing app is sealed. Apple issues tickets for nested code, but ZIP files themselves cannot be stapled. See Apple's [custom notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) and Sparkle's [custom signing instructions](https://sparkle-project.org/documentation/sandboxing/#code-signing).

## Local signed distribution

A local release remains available when Apple notarization credentials are missing:

```sh
./scripts/release.sh --local --version 1.1.0 --preflight
./scripts/release.sh --local --version 1.1.0
```

Set `SCREENWREN_SIGNING_IDENTITY` to the persistent local certificate, or use the existing ignored `ScreenWren/.screenwren-signing-identity` file. Ad-hoc local releases are refused. Release notes explicitly say **“Locally signed; not notarized.”** The build still signs its update archive and appcast with the Sparkle key, but does not claim Gatekeeper acceptance. Other Macs may require manual approval. Local self-signed/ad-hoc development packages disable library validation so the bundled Sparkle framework can load; Developer ID distribution retains library validation.

Local and notarized outputs use different directories (`v1.1.0-local` and `v1.1.0-notarized`). Existing release output is never silently replaced: move it aside explicitly before rebuilding.

## Review and publish

Review the prepared app, release notes, signed `appcast.xml`, archive signature, SHA256 checksums, and notarization receipts when applicable. The appcast is served from:

`https://github.com/diamondplated/mac-tools-releases/releases/latest/download/appcast.xml`

`SUFeedURL` is set to that feed; `MacToolsReleasesURL` is `https://github.com/diamondplated/mac-tools-releases/releases`. `MACTOOLS_RELEASE_REPOSITORY` defaults to that feed's repository and, when supplied, must match it. Preflight rejects empty URLs, a private download repository, or inconsistent locations. `MACTOOLS_SOURCE_REPOSITORY` defaults to `diamondplated/mac-tools` and is used only for source provenance and older release checks. No app source or signing credentials are published to the download repository.

For 1.1.0, the archive URL is `https://github.com/diamondplated/mac-tools-releases/releases/download/v1.1.0/Mac-Tools-1.1.0.zip`. Each update uses its own immutable versioned URL. Both the archive signature and embedded feed signature are checked before publishing. Modifying the feed or release notes invalidates their signature; regenerate them with Sparkle's official tools. [Sparkle documents signed feeds and archive signatures here](https://sparkle-project.org/documentation/).

The script publishes only when explicitly passed `--publish` during a fresh release run:

```sh
./scripts/release.sh --local --version 1.1.0 --publish
```

Use `--notarized` instead once the Developer ID credentials are available. Once 1.1.0 is published, increment the version and build for the next release; do not overwrite its assets.

It refuses an existing version release and checks the build number against previous release metadata/appcasts (falling back to source tags for older releases). The script uploads the ZIP, appcast, signed release notes, archive signature, checksums, and source provenance into a draft release. It finds that draft in the authenticated release list, fetches its exact ID, and checks all six assets' names, upload states, sizes, and SHA256 digests before publishing that ID and marking it latest. Failed uploads leave an unpublished draft for inspection, so the live feed cannot point at a partially uploaded release. A failed preflight or verification publishes nothing. The workflow supports the same explicit choice and stores verified artifacts even without publishing.

To inspect a retained draft against the original verified local output, run `python3 scripts/verify-release-draft.py diamondplated/mac-tools-releases X.Y.Z dist/release/vX.Y.Z-local`. This is read-only and prints the validated release ID. Add `--publish` only when publication is authorized; it validates again before publishing by ID. Keep the original signed files and source provenance rather than rebuilding or overwriting assets.

After publishing, test a real older installed manager against the new feed: check for updates, confirm the offered version, install the update, relaunch, and verify the managed tool versions. Unit tests and packaging validation alone do not establish a successful end-to-end update on another Mac.

## Verified 1.1.0 release

On October 10, 2026, the [1.1.0 release](https://github.com/diamondplated/mac-tools-releases/releases/tag/v1.1.0) passed anonymous feed/archive download checks, byte comparisons with the local release, and official Sparkle signature verification. A modified feed failed signature verification.

On Andrew's Mac, a persistently signed fixture of the current updater stamped as version 1.0.0/build 1 received the public 1.1.0 offer, downloaded it, installed it, and relaunched through Sparkle. The installed version 1.1.0/build 2 matched the published app's complete bundle, including file modes and literal symlink targets. This exercises the update mechanism; the fixture is not the historical 1.0.0 app, which did not have an updater.

ScreenWren's included payload was then installed through Mac Tools. Both installed tools matched the release payloads and passed signature checks. Their complete settings snapshots were unchanged. Both login items were enabled and running from their expected `/Applications` bundles; the one-time next-login check remains armed. This evidence covers this Mac and does not establish notarization or a completed new-login test.
