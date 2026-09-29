#!/usr/bin/env bash
# Shared settings for the build, sign and notarize scripts. Sourced, not executed.
#
# Override any value for your machine in scripts/config.local.sh (git-ignored), or with an environment variable.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-Voxa}"
SCHEME="${SCHEME:-Voxa}"
PROJECT="${PROJECT:-$ROOT/Voxa.xcodeproj}"
BUNDLE_ID="${BUNDLE_ID:-com.rohitsainier.voxa}"

# Apple Developer team that owns the Developer ID certificate. This is the team in your certificate's name,
# e.g. "Developer ID Application: Your Name (TEAMID)".
TEAM_ID="${TEAM_ID:-79Q9WFF2X8}"

BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DERIVED_DATA="${DERIVED_DATA:-$BUILD_DIR/DerivedData}"

# Signing identity for release builds. Empty means "look for a Developer ID Application identity in the keychain".
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

# Keychain profile created with `xcrun notarytool store-credentials` (used by notarize.sh).
NOTARY_PROFILE="${NOTARY_PROFILE:-voxa-notary}"

if [[ -f "$ROOT/scripts/config.local.sh" ]]; then
    # shellcheck source=/dev/null
    source "$ROOT/scripts/config.local.sh"
fi

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"; }

# Prints the first "Developer ID Application" identity in the keychain, or nothing.
find_developer_id() {
    security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1
}
