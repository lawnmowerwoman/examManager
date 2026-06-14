# Changelog

All notable changes to this project will be documented in this file.

The format is inspired by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
with release identifiers aligned to the project's marketing version and build
label.

## [Unreleased]

### Added

1. managed profile support for `ExamProxyWhitelist`, making profile-delivered
   allowlist entries the primary configuration path
2. example mobile configuration profiles for Managed Login Items and
   Notifications
3. explicit `proxyless` backend mode for a bypass-only exam-mode fallback
4. simple IPv4 wildcard support in the allowlist for local infrastructure

### Changed

1. JSON schema for managed settings now avoids Jamf-incompatible conditional
   validation blocks
2. documentation now lists the required Jamf API client privileges for direct
   EA updates
3. external deployment no longer requires a separately managed allowlist file
4. documentation now explains why denied HTTPS requests show a browser-native
   connection error instead of the local block page
5. built-in proxy upstream traffic now uses raw POSIX TCP sockets for both
   `CONNECT` tunnels and plain HTTP forwarding
6. Jamf managed settings for the EA updater are now read from the same robust
   managed-preferences fallback chain as the main profile reader

## [2.0 (1A6d)] - 2026-04-27

Public test release.

### Added

1. randomized delay of 0 to 10 seconds before direct Jamf Extension
   Attribute updates to smooth concurrent database access on Jamf Pro
   instances with low connection limits
2. daemon signal handling for graceful `SIGTERM` shutdown and `SIGHUP`
   whitelist reloads
3. launchd cleanup timeout so the daemon can process `SIGTERM` before
   macOS falls back to `SIGKILL`

### Changed

1. release channel moved from `n` to `d` to mark the public test state

### Release

1. Git tag: `v2.0-1A6d`
2. Installer package: `exam-manager-daemon-2.0.pkg`
3. Package SHA-256:
   `765e8ae673495da438171f55cd440ded53db804fcf9045241caeb310d98f18df`
4. Apple notarization status: `Accepted`

## [2.0 (1A4n)] - 2026-04-25

First public Swift-based beta release.

### Added

1. permanent root `LaunchDaemon` architecture for exam-mode enforcement
2. built-in Swift proxy with allowlist enforcement, HTTP forwarding, and `CONNECT` tunneling
3. direct Jamf Extension Attribute updates via API
4. emergency exit handling via `/var/db/notaryExam.plist`
5. versioned packaging and notarization workflow through `Makefile`
6. example configuration profiles and JSON schema for managed settings
7. Apache 2.0 license, `NOTICE`, and public repository documentation

### Changed

1. built-in Swift proxy is now the default backend for the Swift branch
2. `tinyproxy` remains available as an optional compatibility backend
3. allowlist migration path is documented from `/Library/Management/lib/tinyproxy/whitelist` to `/Library/Management/whitelist`
4. deny page for the built-in proxy is generated directly in memory with inline SVG artwork

### Fixed

1. release workflow now stages and signs the correct payload root
2. release workflow no longer tries to separately sign the SwiftPM resource bundle

### Release

1. Git tag: `v2.0-1A4n`
2. Installer package: `exam-manager-daemon-2.0.pkg`
3. Package SHA-256:
   `fb74661ea39114a2041e8d710cf7449f5785954c24e44efc5681d85aaca7395c`
4. Apple notarization status: `Accepted`
