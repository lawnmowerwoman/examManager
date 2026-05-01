# Config Profiles

This folder contains the configuration-profile material for `exam-manager-daemon`.

## Files

1. [de.twocent.exam.mobileconfig](de.twocent.exam.mobileconfig)
   Project-oriented example profile with all currently supported managed keys.
2. [de.twocent.exam.example.mobileconfig](de.twocent.exam.example.mobileconfig)
   Open-source example profile with safe placeholders for external deployments.
3. [de.twocent.exam.schema.json](de.twocent.exam.schema.json)
   JSON schema for the managed preference keys consumed by the daemon.
4. [de.twocent.exam.managed-login-items.mobileconfig](de.twocent.exam.managed-login-items.mobileconfig)
   Example profile for Managed Login Items approval on macOS.
5. [de.twocent.exam.notifications.mobileconfig](de.twocent.exam.notifications.mobileconfig)
   Example profile for app notification settings on macOS.

## Supported Keys

1. `ExamModeEnabled`
   Boolean flag that enables or disables exam mode.
2. `ExamProxyBackend`
   Optional backend override: `internal`, `tinyproxy`, or `proxyless`.
3. `ExamProxyWhitelist`
   Optional array of additional host patterns delivered through the profile.
4. `ExamVerboseLogging`
   Optional debug flag for chatty proxy/runtime logging.
5. `ExamStatusEAName`
   Optional Jamf extension attribute name. Default: `Exam Mode`.
6. `JamfAPIClientID`
   Optional OAuth client ID for direct Jamf Pro API updates.
7. `JamfAPIClientSecret`
   Optional OAuth client secret for direct Jamf Pro API updates.

## Notes

1. Replace all placeholder UUIDs before using a profile in production.
2. Replace Jamf placeholder credentials only if direct EA updates should be enabled.
3. Removing the profile from scope disables exam mode because the managed key disappears.
4. The schema describes the payload values read by the daemon, not the full Apple configuration-profile envelope.
5. Jamf Pro may ignore advanced JSON Schema conditionals such as `if` / `then`; the included schema intentionally stays conservative for compatibility.
6. Direct Jamf EA updates require an API client with these privileges:
   `Update Computer Extension Attributes`, `Update Computers`, `Read Computers`, `Read Computer Extension Attributes`.
7. The managed settings profiles use the macOS Managed Preferences payload type `com.apple.ManagedClient.preferences`, because the daemon reads from the managed preference layer via `CFPreferences`.
8. `proxyless` is intended as an operational fallback. It keeps exam mode
   active without a local proxy process and only allows bypass-listed
   destinations to remain reachable.
