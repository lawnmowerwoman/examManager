# ----------------------------
# Project
# ----------------------------
APP_NAME        := exam-manager-daemon
PKG_ID          := de.twocent.exam.daemon
VERSION         ?= 2.0
-include .version/version.mk

INSTALL_DIR     := /usr/local/bin

# ----------------------------
# Signing identities
# ----------------------------
DEV_ID_APP      ?= Developer ID Application: Stefanie Ramroth (KP5T66DWT2)
DEV_ID_INSTALL  ?= Developer ID Installer: Stefanie Ramroth (KP5T66DWT2)
TEAM_ID         ?= KP5T66DWT2
NOTARY_PROFILE  ?= notary-profile

# ----------------------------
# Paths
# ----------------------------
BUILD_DIR       := .build
OUT_DIR         := dist
PAYLOAD_ROOT    := Packaging/root
PKG_SCRIPTS_DIR := Packaging/pkg-scripts
VERSION_DIR     := .version
VERSION_SWIFT   := Sources/ExamManagerCore/Version.generated.swift
BUILD_LABEL     = $(shell test -f "$(VERSION_DIR)/build_label" && tr -d '[:space:]' < "$(VERSION_DIR)/build_label")
RELEASE_DIR     := $(BUILD_DIR)/arm64-apple-macosx/release
RELEASE_BIN     := $(RELEASE_DIR)/$(APP_NAME)
RELEASE_BUNDLE  := $(RELEASE_DIR)/ExamManager_ExamManagerCore.bundle
PAYLOAD_BIN     := $(PAYLOAD_ROOT)$(INSTALL_DIR)/$(APP_NAME)
PAYLOAD_BUNDLE  := $(PAYLOAD_ROOT)$(INSTALL_DIR)/ExamManager_ExamManagerCore.bundle
PKG_BASENAME    = $(APP_NAME)-$(VERSION)$(if $(BUILD_LABEL),-$(BUILD_LABEL),)
PKG_UNSIGNED    = $(OUT_DIR)/$(PKG_BASENAME)-unsigned.pkg
PKG_SIGNED      = $(OUT_DIR)/$(PKG_BASENAME).pkg
NOTARY_LOG      := $(OUT_DIR)/notary-log.json

.PHONY: all clean gen-version build prepare-root check-signing check-notary sign-payload sign-bin pkg pkg-sign pkg-verify notarize staple release release-notarized help

all: release

help:
	@echo "Targets:"
	@echo "  make gen-version      - bump build number and regenerate Version.generated.swift"
	@echo "  make build            - SwiftPM release build"
	@echo "  make prepare-root     - stage payload root including resource bundle"
	@echo "  make sign-payload     - codesign the staged daemon binary"
	@echo "  make sign-bin         - alias for sign-payload"
	@echo "  make pkg              - build unsigned installer package"
	@echo "  make pkg-sign         - sign installer package"
	@echo "  make pkg-verify       - verify signed package"
	@echo "  make notarize         - notarize signed package"
	@echo "  make staple           - staple notarization ticket"
	@echo "  make release          - build -> sign -> pkg -> pkg-sign -> verify"
	@echo "  make release-notarized - release -> notarize -> staple"

clean:
	rm -rf $(OUT_DIR)
	rm -rf $(BUILD_DIR)

gen-version:
	@mkdir -p "$(VERSION_DIR)"
	@chmod +x ./Tools/gen_version.sh
	@./Tools/gen_version.sh "$(VERSION_DIR)" "$(VERSION_SWIFT)"

build: gen-version
	swift build -c release

prepare-root: build
	rm -rf "$(PAYLOAD_ROOT)"
	mkdir -p "$(OUT_DIR)"
	./Packaging/scripts/stage-payload.sh release

check-signing:
ifeq ($(strip $(DEV_ID_APP)),)
	$(error DEV_ID_APP is not set. Example: DEV_ID_APP='Developer ID Application: ... (TEAMID)')
endif

check-notary:
ifeq ($(strip $(NOTARY_PROFILE)),)
	$(error NOTARY_PROFILE is not set. Example: NOTARY_PROFILE='notary-profile')
endif

sign-payload: prepare-root check-signing
	codesign --force --options runtime --timestamp \
	  --identifier "$(PKG_ID)" \
	  --sign "$(DEV_ID_APP)" \
	  "$(PAYLOAD_BIN)"
	codesign --verify --strict --verbose=2 "$(PAYLOAD_BIN)"

sign-bin: sign-payload

pkg: sign-payload
	mkdir -p "$(OUT_DIR)"
	pkgbuild \
	  --root "$(PAYLOAD_ROOT)" \
	  --scripts "$(PKG_SCRIPTS_DIR)" \
	  --identifier "$(PKG_ID)" \
	  --version "$(VERSION)" \
	  --install-location "/" \
	  "$(PKG_UNSIGNED)"

pkg-sign: pkg
ifeq ($(strip $(DEV_ID_INSTALL)),)
	$(error DEV_ID_INSTALL is not set. Example: DEV_ID_INSTALL='Developer ID Installer: ... (TEAMID)')
endif
	productsign --sign "$(DEV_ID_INSTALL)" "$(PKG_UNSIGNED)" "$(PKG_SIGNED)"
	rm -f "$(PKG_UNSIGNED)"

pkg-verify:
	@echo "=== pkgutil --check-signature ==="
	pkgutil --check-signature "$(PKG_SIGNED)" || true
	@echo ""
	@echo "=== spctl --assess ==="
	spctl --assess --type install --verbose "$(PKG_SIGNED)" || true

notarize: pkg-sign check-notary
	xcrun notarytool submit "$(PKG_SIGNED)" \
	  --keychain-profile "$(NOTARY_PROFILE)" \
	  --wait \
	  --output-format json > "$(NOTARY_LOG)"
	@echo "Notarization log written to $(NOTARY_LOG)"

staple: notarize
	xcrun stapler staple "$(PKG_SIGNED)"
	xcrun stapler validate "$(PKG_SIGNED)"

release: pkg-sign pkg-verify
	@echo "Built: $(PKG_SIGNED)"

release-notarized: release notarize staple
	@echo "Built and notarized: $(PKG_SIGNED)"
