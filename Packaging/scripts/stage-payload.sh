#!/bin/zsh --no-rcs
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PAYLOAD_ROOT="${ROOT_DIR}/Packaging/root"
BUILD_CONFIG="${1:-release}"
BUILD_BIN="${ROOT_DIR}/.build/arm64-apple-macosx/${BUILD_CONFIG}/exam-manager-daemon"
BUILD_BUNDLE="${ROOT_DIR}/.build/arm64-apple-macosx/${BUILD_CONFIG}/ExamManager_ExamManagerCore.bundle"
TARGET_BIN="${PAYLOAD_ROOT}/usr/local/bin/exam-manager-daemon"
TARGET_BUNDLE="${PAYLOAD_ROOT}/usr/local/bin/ExamManager_ExamManagerCore.bundle"
TARGET_PLIST="${PAYLOAD_ROOT}/Library/LaunchDaemons/de.twocent.exam.daemon.plist"
SOURCE_PLIST="${ROOT_DIR}/LaunchDaemons/de.twocent.exam.daemon.plist"

echo "Staging payload into ${PAYLOAD_ROOT}"

mkdir -p "$(dirname "${TARGET_BIN}")"
mkdir -p "$(dirname "${TARGET_PLIST}")"

if [[ ! -f "${BUILD_BIN}" ]]; then
  echo "Missing build artifact: ${BUILD_BIN}" >&2
  echo "Run: swift build -c ${BUILD_CONFIG}" >&2
  exit 2
fi

if [[ ! -d "${BUILD_BUNDLE}" ]]; then
  echo "Missing resource bundle: ${BUILD_BUNDLE}" >&2
  echo "Run: swift build -c ${BUILD_CONFIG}" >&2
  exit 3
fi

cp "${BUILD_BIN}" "${TARGET_BIN}"
chmod 755 "${TARGET_BIN}"

rm -rf "${TARGET_BUNDLE}"
cp -R "${BUILD_BUNDLE}" "${TARGET_BUNDLE}"

cp "${SOURCE_PLIST}" "${TARGET_PLIST}"
chmod 644 "${TARGET_PLIST}"

echo "Payload staged:"
echo "  Binary: ${TARGET_BIN}"
echo "  Resources: ${TARGET_BUNDLE}"
echo "  LaunchDaemon: ${TARGET_PLIST}"
echo "  Postinstall: ${ROOT_DIR}/Packaging/pkg-scripts/postinstall"
echo
echo "External deployment artifacts kept outside payload root:"
echo "  Config profile: ${ROOT_DIR}/ConfigProfiles/de.twocent.exam.mobileconfig"
echo "  Runtime allowlist files: /Library/Management/whitelist + /Library/Management/lib/tinyproxy/whitelist"
echo "  Runtime state: /var/db/notaryExam.plist"
