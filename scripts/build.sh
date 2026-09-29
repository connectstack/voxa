#!/usr/bin/env bash
# Builds Voxa.app with Xcode.
#
#   scripts/build.sh                    Debug build, ad-hoc signed (fast; macOS re-asks for permissions after each rebuild)
#   scripts/build.sh --sign-dev         Debug build signed with your Developer ID, so permission grants (microphone,
#                                       Accessibility, ...) survive rebuilds
#   scripts/build.sh --release          Release build signed with Developer ID + hardened runtime (for notarization)
#   scripts/build.sh --run              Launch the app after building (add to any of the above)
#   scripts/build.sh --regenerate       Regenerate Voxa.xcodeproj from project.yml first (needs XcodeGen)
#
# The app is written to build/DerivedData/Build/Products/<Configuration>/Voxa.app.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"

CONFIGURATION="Debug"
RUN=0
REGENERATE=0
SIGN_DEV=0

for arg in "$@"; do
    case "$arg" in
        --release)    CONFIGURATION="Release" ;;
        --sign-dev)   SIGN_DEV=1 ;;
        --run)        RUN=1 ;;
        --regenerate) REGENERATE=1 ;;
        -h|--help)    sed -n '2,13p' "$0"; exit 0 ;;
        *)            die "unknown option: $arg (see --help)" ;;
    esac
done

require xcodebuild "Install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"

if [[ $REGENERATE -eq 1 || ! -d "$PROJECT" ]]; then
    require xcodegen "Install with: brew install xcodegen"
    log "Generating Xcode project from project.yml"
    (cd "$ROOT" && xcodegen generate --quiet)
fi

SIGN_ARGS=()
if [[ "$CONFIGURATION" == "Release" || $SIGN_DEV -eq 1 ]]; then
    IDENTITY="${SIGN_IDENTITY:-$(find_developer_id)}"
    [[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' identity found. Set SIGN_IDENTITY in scripts/config.local.sh."
    log "Signing with: $IDENTITY"
    SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_ID"
        ENABLE_HARDENED_RUNTIME=YES
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
fi

log "Building $APP_NAME ($CONFIGURATION)"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} \
    build | { command -v xcbeautify >/dev/null 2>&1 && xcbeautify || grep -E "error:|warning:|BUILD|Signing Identity" ; }

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
[[ -d "$APP" ]] || die "build finished but $APP is missing"
log "Built $APP"

if [[ $RUN -eq 1 ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.3
    log "Launching"
    open -n "$APP"
fi
