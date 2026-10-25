# Security Policy

This policy covers Mac Tools and the apps it installs: DockPeek, ScreenWren,
ScrollSplit, and LinkRoutes. ScreenWren's
[security policy](ScreenWren/SECURITY.md) adds its capture-specific boundaries.

## Report a vulnerability

Use the **Report a vulnerability** form on the
[public Mac Tools downloads repository](https://github.com/diamondplated/mac-tools-releases/security/advisories/new)
(GitHub private vulnerability reporting). The source repository is private, so
reporters cannot reach its security page. Do not open a public issue for an
unpatched security problem.

If private vulnerability reporting is unavailable, contact the maintainer through
a private channel listed on the repository owner's GitHub profile. Include the
affected app, version and build, macOS version and architecture, reproduction
steps using nonsensitive sample content, and the security boundary you expected.

Do not send passwords, signing certificates, Apple credentials, private keys, or
unredacted personal captures.

## Supported versions

Security fixes are made against the latest source and the latest published Mac
Tools release. Installed tools are updated through the manager after it updates.

## Relevant boundaries

Reports are especially useful when they concern update feed or archive signature
verification, installation that replaces or downgrades another app, settings
bridges accepting writes they should reject, LinkRoutes opening a link in an
unexpected app, input-monitoring or accessibility access used beyond its stated
purpose, or any path by which untrusted input can execute code.
