# Mac Apps development

- Preserve Andrew's selected model and reasoning effort; keep work bounded and
  reuse successful verification unless subsequent changes justify repeating it.
- This repository owns Mac Tools, DockPeek, ScreenWren, ScrollSplit, LinkRoutes,
  Latent, and Sift. Do not make new development changes in the previous standalone
  ScreenWren, Latent, or Sift repositories; they are archived.
- Latent and Sift are standalone apps that Mac Tools also embeds and installs.
  Follow `Latent/CLAUDE.md` and `Sift/AGENTS.md` inside those folders. Their tests
  run in their own workflows (`latent.yml`, `sift.yml`); `verify.sh` builds and
  checks their `--mac-tools-payload` bundles (universal, hardened runtime,
  persistent identity, no Latent model weights). They have no settings bridge, so
  `ManagedApp.supportsSettingsBridge` is false and Mac Tools never runs
  `--mac-tools-settings` against them. Sift's version lives in `Sift/VERSION`
  and `Sift/BUILD`, Latent's in its Info.plist; bump them when the app changes,
  and BUILD only goes up.
- This repository is public and its CI runs on Andrew's laptop. Every workflow
  job that runs on `pull_request` must skip fork PRs
  (`github.event.pull_request.head.repo.full_name == github.repository`).
  Never put machine paths, hostnames, or account details in committed files.
- Follow `ScreenWren/AGENTS.md` for its persistent signing and interactive
  installation workflow. Never commit local signing configuration or credentials.
- Use `./verify.sh` for full suite verification. For focused changes, run the
  affected package's tests, build updated tool payloads, and use
  `./build-app.sh --reuse-payloads` before checking the assembled bundle.
- Packaging must preserve the embedded apps' signatures; do not sign the manager
  with `codesign --deep`.
- Settings changes must use each tool's settings bridge, validate the entire
  patch before writing, retain existing preference domains, and apply to running
  apps without losing captures or window state.
- GitHub Actions must use only Andrew's self-hosted macOS runners. No hosted
  runners or fallback. Repair or report unavailable local runners.
- Recurring infrastructure belongs on the target system's native scheduler.
  Do not create Codex automations.
