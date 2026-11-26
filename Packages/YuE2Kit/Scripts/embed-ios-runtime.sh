#!/bin/sh
set -eu

[ "${PLATFORM_NAME:-}" = iphoneos ] || exit 0
source="${SRCROOT:?}/Packages/YuE2Kit/.build/apple-mobile/YuE2Audio.framework"
destination="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}/YuE2Audio.framework"

# Replace only this build product so removing the optional local runtime also
# removes it from incremental app builds.
if [ -d "$destination" ]; then
    rm -rf -- "$destination"
fi
[ -f "$source/YuE2Audio" ] || exit 0

ditto "$source" "$destination"
if [ "${CODE_SIGNING_ALLOWED:-NO}" = YES ]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:?Missing framework signing identity}" "$destination"
fi
