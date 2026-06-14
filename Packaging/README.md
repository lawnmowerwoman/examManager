# Packaging Layout

This folder holds the staging structure for packaging and notarization.

## Intent

The package payload should stay small and predictable:

1. the signed daemon binary
2. the SwiftPM resource bundle used by the daemon
3. the LaunchDaemon plist
4. optional support files that are intentionally shipped outside the binary
5. a `preinstall` script that unloads the previous LaunchDaemon before upgrade
6. a `postinstall` script that bootstraps the LaunchDaemon after installation

The deny page and illustration are bundled into the SwiftPM resource bundle and
therefore travel with the signed daemon build. They do not need to exist as
separate source files in the final payload.

## Folder Layout

```text
Packaging/
├── root/
│   ├── Library/
│   │   └── LaunchDaemons/
│   └── usr/
│       └── local/
│           └── bin/
│               ├── exam-manager-daemon
│               └── ExamManager_ExamManagerCore.bundle
├── pkg-scripts/
│   ├── preinstall
│   └── postinstall
└── scripts/
    └── stage-payload.sh
```

## Notes

1. `ConfigProfiles/de.twocent.exam.mobileconfig` is intentionally kept outside
   the payload root because it is typically uploaded to Jamf Pro, not installed
   locally by the pkg.
2. The runtime allowlist files and `/var/db/notaryExam.plist` remain runtime
   files and are not treated as immutable packaged assets.
3. Signed package filenames include the current build label to reduce update
   collisions during repeated test deployments.
