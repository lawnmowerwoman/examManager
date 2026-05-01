# ExamManager

Swift-based exam-mode enforcement for macOS school environments.

`exam-manager-daemon` runs as a signed root `LaunchDaemon`, reacts to managed
configuration-profile changes, applies system proxy restrictions within seconds,
and can report exam-mode status directly back to Jamf Pro.

## Highlights

1. built-in Swift proxy as the default backend
2. optional `tinyproxy` compatibility mode for gradual migration
3. Jamf Extension Attribute updates without `recon`
4. emergency exit via `/var/db/notaryExam.plist`
5. packaging, signing, and notarization support via `Makefile`
6. release history in [CHANGELOG.md](CHANGELOG.md)

## Overview

`exam-manager-daemon` runs permanently as a root `LaunchDaemon` and watches the
managed preference key `ExamModeEnabled` in the domain `de.twocent.exam`.

Exam mode is no longer driven by a Jamf policy parameter. Instead, Jamf or
another MDM system deploys or removes a configuration profile, and the daemon
reacts automatically.

Profile changes remain event-driven through Darwin notifications. The emergency
exit is handled separately through the persisted state plist at
`/var/db/notaryExam.plist`.

```text
MDM / Jamf
    │
    │  deploy / remove config profile
    ▼
macOS managed preferences
    │
    │  Darwin notification
    ▼
exam-manager-daemon
    │
    ├─ ConfigProfileReader     -> reads ExamModeEnabled
    ├─ ExamProxyManager        -> runs the built-in Swift proxy by default
    ├─ TinyproxyManager        -> optional compatibility backend
    ├─ NetworkProxyManager     -> applies system-wide proxy settings
    ├─ NotaryStateStore        -> persists runtime state in /var/db/notaryExam.plist
    ├─ EmergencyExitObserver   -> watches for `exit = true`
    └─ JamfHelper              -> updates the Jamf EA directly via API
```

## Runtime Model

The daemon now prefers the built-in Swift proxy and supports these backend choices:

1. `internal`
   the built-in Swift proxy listens on `127.0.0.1:8888` and is the default
   backend for new builds.
2. `tinyproxy`
   `tinyproxy` is present under `/Library/Management/bin/tinyproxy`, launches
   successfully, and can still be selected explicitly as a compatibility mode.
3. `proxyless`
   exam mode stays active without a running proxy process. The daemon enforces
   a restrictive bypass-only mode by pointing system proxies to
   `127.0.0.1:80` and `127.0.0.1:443`.

At runtime the persisted `proxyMode` can still become `fallback` when the
selected backend could not be started. In that case the daemon still enforces a
   restrictive exam mode by pointing system proxies to `127.0.0.1:80` and
   `127.0.0.1:443`, while allowing only bypass domains to remain reachable.

The current mode is persisted in `/var/db/notaryExam.plist` as `proxyMode`.

## Project Structure

```text
ExamManager/
├── Package.swift
├── Sources/
│   ├── ExamManagerCore/
│   │   ├── ConfigProfileReader.swift
│   │   ├── ProfileChangeObserver.swift
│   │   ├── EmergencyExitObserver.swift
│   │   ├── ExamModeController.swift
│   │   ├── ExamProxyConfiguration.swift
│   │   ├── ExamProxyRequest.swift
│   │   ├── ExamProxyRequestParser.swift
│   │   ├── ExamProxyAllowlist.swift
│   │   ├── ExamProxyConnectionHandler.swift
│   │   ├── ExamProxyServer.swift
│   │   ├── ExamProxyManager.swift
│   │   ├── TinyproxyManager.swift
│   │   ├── NetworkProxyManager.swift
│   │   ├── JamfHelper.swift
│   │   ├── NotaryStateStore.swift
│   │   ├── NotaryExamState.swift
│   │   ├── SecurePlistStore.swift
│   │   ├── ExamManagerPaths.swift
│   │   ├── ConsoleLogger.swift
│   │   └── PlistStoreLogger.swift
│   └── ExamManagerDaemon/
│       └── main.swift
├── LaunchDaemons/
│   └── de.twocent.exam.daemon.plist
└── ConfigProfiles/
    ├── de.twocent.exam.mobileconfig
    └── de.twocent.exam.example.mobileconfig
    └── de.twocent.exam.schema.json
```

## Built-in Proxy

The built-in Swift proxy is now the default backend for the development branch.

Current beta scope:

1. local listener on `127.0.0.1:8888`
2. host-based allowlist enforcement
3. denied HTTP requests return the bundled block page
4. allowed `CONNECT host:443` requests are tunneled
5. allowed plain HTTP requests are forwarded upstream
6. both upstream paths now use raw POSIX TCP sockets instead of `NWConnection`
   to avoid self-recursion into the system proxy path

Compatibility mode:

1. `tinyproxy` remains available through the managed preference
   `ExamProxyBackend = tinyproxy`
2. `ExamProxyBackend = proxyless` enables a bypass-only emergency operating
   mode without a local proxy process
3. if `ExamProxyBackend` is absent, the daemon uses the built-in proxy

See:

1. [docs/mini-proxy-plan.md](docs/mini-proxy-plan.md)
2. `ExamProxyConfiguration`
3. `ExamProxyRequestParser`
4. `ExamProxyAllowlist`
5. `ExamProxyConnectionHandler`
6. `ExamProxyServer`
7. `ExamProxyManager`

## Bundled Web Assets

The deny page and its illustration are now versioned project assets and are
processed as part of the SwiftPM build.

Bundled resources:

1. `Sources/ExamManagerCore/Resources/default.html`
2. `Sources/ExamManagerCore/Resources/websperre.svg`

At runtime these assets are still copied into:

1. `/Library/Management/lib/tinyproxy/default.html`
2. `/Library/Management/lib/tinyproxy/websperre.svg`

This keeps the legacy `tinyproxy` path working and also preserves the current
absolute image reference inside the deny page while the built-in proxy is still
in beta.

In addition, the SwiftPM resource bundle itself is shipped with the daemon so
the signed package always contains the canonical source assets used at build
time.

For the built-in proxy specifically, the deny page no longer depends on an
external HTML file. The HTTP `403` response is generated directly in memory and
embeds the bundled `websperre.svg` markup inline. The copied `default.html`
remains necessary only for the optional `tinyproxy` compatibility backend.

### HTTPS Block Behavior

For denied `https://` destinations, browsers typically show their own generic
connection error instead of the local ExamManager block page.

This is expected with the current design:

1. ExamManager denies the `CONNECT` request before any TLS session is
   established.
2. Without TLS interception, the proxy cannot inject an HTML error page into
   an HTTPS response stream.
3. A rendered HTTPS block page would require a man-in-the-middle proxy with a
   trusted intermediate certificate on the managed Macs.

ExamManager intentionally does **not** do this today because it would:

1. increase operational complexity significantly
2. introduce compatibility risks with many sites and apps
3. change the security model of the exam proxy substantially

Practical consequence:

1. denied HTTP pages can show the branded local block page
2. denied HTTPS pages will usually show a browser-native connection error

The same transition applies to the allowlist location:

1. current tinyproxy-based path:
   `/Library/Management/lib/tinyproxy/whitelist`
2. built-in proxy runtime path:
   `/Library/Management/whitelist`

The daemon now accepts additional custom allowlist entries from both:

1. the managed profile key `ExamProxyWhitelist`
2. the existing runtime allowlist files

Those custom entries are merged with the built-in Jamf and Apple defaults and
then materialized into the backend-specific runtime file for the selected
backend.

Simple IPv4 wildcard patterns are also supported for local infrastructure
testing, for example `192.168.0.*` or `192.168.0.x`.

## Package Staging

A packaging scaffold is available under:

1. [Packaging/README.md](Packaging/README.md)
2. [Packaging/scripts/stage-payload.sh](Packaging/scripts/stage-payload.sh)

The staging script prepares the current payload root with:

1. `/usr/local/bin/exam-manager-daemon`
2. `/usr/local/bin/ExamManager_ExamManagerCore.bundle`
3. `/Library/LaunchDaemons/de.twocent.exam.daemon.plist`

The following remain intentionally outside the payload root:

1. `ConfigProfiles/de.twocent.exam.mobileconfig`
2. `ConfigProfiles/de.twocent.exam.example.mobileconfig`
3. the runtime allowlist files
4. the runtime state plist

## Build

Recommended versioned build:

```bash
make build
```

This regenerates [Version.generated.swift](Sources/ExamManagerCore/Version.generated.swift)
and then builds the release binary.

Current start version:

1. marketing version `2.0`
2. build label `1A1n`

Direct SwiftPM build remains available:

```bash
swift build -c release
```

The resulting release artifacts are:

```text
.build/arm64-apple-macosx/release/exam-manager-daemon
.build/arm64-apple-macosx/release/ExamManager_ExamManagerCore.bundle
```

## Code Signing

The release workflow is now captured in the `Makefile`.

Useful targets:

1. `make sign-payload`
   signs the staged daemon binary and the SwiftPM resource bundle
2. `make release`
   builds a signed installer package and verifies its signature
3. `make release-notarized`
   builds, signs, notarizes, and staples the final installer package

The daemon binary is signed with bundle identifier `de.twocent.exam` so
CFPreferences resolves the managed preference domain correctly.

The notarization step expects an Apple notarytool keychain profile such as:

```bash
xcrun notarytool store-credentials "notary-profile" \
  --apple-id "name@example.com" \
  --team-id "TEAMID12345" \
  --password "app-specific-password"
```

Manual `codesign` remains possible if needed:

```bash
codesign \
  --sign "Developer ID Application: Stefanie Ramroth (TEAMID)" \
  --identifier "de.twocent.exam" \
  --options runtime \
  --timestamp \
  .build/release/exam-manager-daemon
```

## Deployment via Jamf

### 1. Install the Binary

Package the binary as a pkg and install it to:

```text
/usr/local/bin/exam-manager-daemon
```

### 2. Install the LaunchDaemon

Deploy:

```text
LaunchDaemons/de.twocent.exam.daemon.plist
```

to:

```text
/Library/LaunchDaemons/de.twocent.exam.daemon.plist
```

Then bootstrap it once:

```bash
launchctl bootstrap system /Library/LaunchDaemons/de.twocent.exam.daemon.plist
```

### 3. Enable Exam Mode

Upload `de.twocent.exam.mobileconfig` to Jamf Pro and scope it to the desired
device group. The daemon reacts within seconds to the managed-preferences
notification.

For open-source or third-party deployments, the repository also includes:

1. [de.twocent.exam.example.mobileconfig](ConfigProfiles/de.twocent.exam.example.mobileconfig)
2. [de.twocent.exam.schema.json](ConfigProfiles/de.twocent.exam.schema.json)

This example profile uses the built-in proxy backend and contains no real Jamf
API credentials. The schema describes the managed keys expected inside the
payload and is useful for documentation, review, and generated config tooling.

### 4. Disable Exam Mode

Remove the configuration profile from scope or delete it. Once macOS removes
the managed key, the daemon disables the active exam-mode proxy configuration.

## Direct Jamf EA Update

The daemon no longer writes a separate EA marker file and no longer depends on
`jamf recon` after each state transition.

Instead, it can update the exam-status extension attribute directly through the
Jamf Pro API. The implementation is intentionally lightweight and mirrors the
core approach used in `Notary`:

1. obtain an OAuth bearer token with client credentials
2. resolve the local Jamf Computer ID from the serial number
3. resolve the EA definition by name
4. PATCH the value directly onto the computer inventory record

### Supported Configuration Inputs

The direct EA update is enabled when these values are present:

1. `JamfAPIClientID`
2. `JamfAPIClientSecret`

Optional:

1. `ExamStatusEAName`
   Default: `Exam Mode`

These values can come from either:

1. environment variables
   `JAMF_CLIENT_ID`, `JAMF_CLIENT_SECRET`, `JAMF_EXAM_STATUS_EA_NAME`
2. managed preferences in the same domain `de.twocent.exam`

If the credentials are missing, the daemon simply skips the direct EA update
and continues normal exam-mode operation.

### Required Jamf API Privileges

The Jamf Pro API client used for direct EA updates must be allowed to:

1. `Update Computer Extension Attributes`
2. `Update Computers`
3. `Read Computers`
4. `Read Computer Extension Attributes`

### EA Values

The daemon currently writes these status strings:

1. `active`
2. `active:fallback`
3. `inactive`
4. `activating`
5. `deactivating`
6. `error`

### Jamf Smart Group Recommendation

If you want a Smart Group that represents devices currently in exam mode, use
two criteria with `OR`:

1. `Exam Mode` `is` `active`
2. `Exam Mode` `is` `active:fallback`

This is preferred over broad text matching. Do not use a loose operator such
as `like` or `contains` unless you explicitly want to match future status
variants as well.

## tinyproxy Fallback

If the selected backend is unavailable, the daemon still enters a restrictive
fallback mode instead of failing open.

In fallback mode it applies:

```text
HTTP  -> 127.0.0.1:80
HTTPS -> 127.0.0.1:443
```

No custom error page is shown in fallback mode, but the proxy bypass list still
limits which destinations remain reachable.

## Emergency Exit

The legacy `/Library/Management/2472` marker is no longer used.

Emergency exit is now triggered through the persisted state plist:

```bash
sudo defaults write /var/db/notaryExam exit -bool true
```

When the daemon sees `exit = true`, it:

1. disables the currently active proxy configuration
2. records `emergency-exit` as the last command
3. keeps the exit flag latched
4. suppresses profile-driven reactivation until the profile state changes

The flag is reset automatically whenever `ExamModeEnabled` changes its value:

1. `true -> false` clears `exit`
2. `false -> true` clears `exit`
3. after the reset, the daemon applies the new desired profile state

This keeps the state machine deterministic:

1. exam mode enabled, proxy active
2. emergency exit, proxy inactive
3. exam mode disabled, proxy remains inactive and `exit` is cleared
4. exam mode enabled again, proxy activates normally

You can still clear the flag manually if needed:

```bash
sudo defaults write /var/db/notaryExam exit -bool false
```

## Logging and Diagnostics

```bash
# live daemon log
tail -f /var/log/exam-manager-daemon.log

# persisted runtime state
sudo plutil -p /var/db/notaryExam.plist

# daemon status
launchctl list de.twocent.exam.daemon
launchctl list de.twocent.exam.tinyproxy
```

## Managed Preference Key

| Key | Domain | Type | Meaning |
|---|---|---|---|
| `ExamModeEnabled` | `de.twocent.exam` | `Bool` | `true` enables exam mode |
| `ExamProxyBackend` | `de.twocent.exam` | `String` | optional backend override: `internal` or `tinyproxy` |
| `ExamProxyWhitelist` | `de.twocent.exam` | `[String]` | optional additional allowlist patterns delivered through the profile |
| `JamfAPIClientID` | `de.twocent.exam` | `String` | optional Jamf API client ID |
| `JamfAPIClientSecret` | `de.twocent.exam` | `String` | optional Jamf API client secret |
| `ExamStatusEAName` | `de.twocent.exam` | `String` | optional EA display name, default `Exam Mode` |

The daemon reads this key through `CFPreferencesCopyValue` from the managed
layer using `kCFPreferencesAnyUser` and `kCFPreferencesCurrentHost`.

## Open Source

This repository is intended for publication as open source under the Apache 2.0
license.

Included files:

1. [LICENSE](LICENSE)
2. [NOTICE](NOTICE)

If you publish forks or derived packages, keep the Apache 2.0 license text and
the relevant attribution notices intact.
