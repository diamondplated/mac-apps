# Releasing Mac Tools

Mac Tools bundles DockPeek, ScreenWren, and Sparkle 2.10.0. Source may remain private, but the update download repository must be public. Ordinary `./build-app.sh` produces a universal local package; `./scripts/release.sh` prepares an isolated, verified distribution in `dist/release/`. Neither command installs apps. All CI runs on Andrew's `air` self-hosted Mac.

## Native keychain setup

Prepare these credentials once on the release runner, outside GitHub:

1. Install a valid **Developer ID Application** certificate and its private key in the runner user's login keychain. An Apple Development or self-signed certificate cannot substitute for Developer ID notarization. Set `DEVELOPER_ID_APPLICATION_IDENTITY` to that identity's name or fingerprint.
2. Run `xcrun notarytool store-credentials mac-tools-notary` interactively and provide the Apple credentials there. Set `NOTARYTOOL_PROFILE=mac-tools-notary`. Passwords and private keys remain in the native keychain.
3. Use the official [Sparkle 2.10.0 distribution](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0). Set `SPARKLE_TOOLS_DIR` to its `bin` directory; resolved SwiftPM artifact `bin` directories are also detected automatically. Run `"$SPARKLE_TOOLS_DIR/generate_keys" --account mac-tools` once, then put only its public key into `SUPublicEDKey` in `MacTools/Info.plist`. Preserve the existing key on subsequent releases. Do not export or commit the private key.
4. Permit the official Sparkle signing tools to read that key when Keychain Access asks. Unattended runs need an unlocked, accessible login keychain. Never work around this by copying private keys into GitHub Secrets.

The initial machine inspection found no valid Developer ID Application identity. Notarized release preflight fails until a certificate/private key and working notary profile are provisioned. A successful local package does not establish notarization.

For workflow dispatch, repository **variables** may contain the nonsecret identity/profile/path names: `DEVELOPER_ID_APPLICATION_IDENTITY`, `NOTARYTOOL_PROFILE`, `SPARKLE_TOOLS_DIR`, and optionally `LOCAL_SIGNING_IDENTITY`, and `MACTOOLS_RELEASE_REPOSITORY`. The actual credentials stay on the self-hosted runner. Configure the runner user’s native `gh auth login` session with access to the chosen download repository; the source repository’s automatic workflow token cannot publish to another repository. The workflow defaults to notarized mode and does not publish unless its publish checkbox is selected.

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

`https://github.com/<owner>/<public-download-repository>/releases/latest/download/appcast.xml`

Set `SUFeedURL` and `MacToolsReleasesURL` in the manager plist to the chosen public repository. `MACTOOLS_RELEASE_REPOSITORY` defaults to that feed's repository and, when supplied, must match it. Preflight rejects empty URLs, a private download repository, or inconsistent locations. `MACTOOLS_SOURCE_REPOSITORY` defaults to `diamondplated/mac-tools` and is used only for source provenance and older release checks. The publishing destination remains unconfigured until a public host is selected.

Its update archive points to the immutable versioned release URL. Both the archive signature and embedded feed signature are checked before publishing. Modifying the feed or release notes invalidates their signature; regenerate them with Sparkle's official tools. [Sparkle documents signed feeds and archive signatures here](https://sparkle-project.org/documentation/).

The script publishes only when explicitly passed `--publish` during a fresh release run:

```sh
./scripts/release.sh --notarized --version 1.1.0 --publish
```

It refuses an existing version tag/release and checks the build number against previous release metadata/appcasts (falling back to source tags for older releases). The final `gh release create` publishes the ZIP, appcast, signed release notes, archive signature, checksums, and source provenance together, after all checks. A failed preflight or verification publishes nothing. The workflow supports the same explicit choice and stores verified artifacts even without publishing.

After publishing, test a real older installed manager against the new feed: check for updates, confirm the offered version, install the update, relaunch, and verify the managed tool versions. Unit tests and packaging validation alone do not establish a successful end-to-end update on another Mac.
