# Toolchain for JuniorPrompter builds and tests.
#
# Xcode's licence is un-accepted after an Xcode update, so /usr/bin/git,
# /usr/bin/swift and xcrun all fail, and the Command Line Tools toolchain
# cannot compile SwiftUI macros. Point everything at Xcode's own toolchain
# until `sudo xcodebuild -license accept` is run.
#
# Source this file: `source env.sh`, then use $SWIFT, $GIT and $XCTEST.
XCODE_DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
export SDKROOT="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
# xctest and the built test bundle need the platform's XCTest framework on the load path.
export DYLD_FRAMEWORK_PATH="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
export DYLD_LIBRARY_PATH="$XCODE_DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"
SWIFT="$XCODE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
GIT="$XCODE_DEVELOPER_DIR/usr/bin/git"
XCTEST="$XCODE_DEVELOPER_DIR/usr/bin/xctest"
# Never build inside this folder: Documents is file-provider managed, so .build
# picks up com.apple.macl/com.apple.provenance extended attributes and CodeSign
# then rejects the test bundle with "resource fork, Finder information, or
# similar detritus not allowed".
JUNIORPROMPTER_TEST_SCRATCH="${JUNIORPROMPTER_TEST_SCRATCH:-/private/tmp/JuniorPrompter-test-cache}"

# A stable local identity keeps the Camera and Microphone grants across rebuilds; ad hoc ("-")
# ties them to one build's cdhash, so every new build silently loses them (black camera, silent mic).
SIGN_ID="-"
if /usr/bin/security find-identity -v -p codesigning 2>/dev/null | grep -q '"ReadAlong Dev"'; then SIGN_ID="ReadAlong Dev"; fi
export SIGN_ID
