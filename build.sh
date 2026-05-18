#!/bin/bash
: "${ARM64_EXPECTED_HASH:=1feb14e8d9faab135cc3e4f13b76ef0cc6cdf1194ca457b3d9733d25a0b863d7}"
: "${AMD64_EXPECTED_HASH:=3d39a236267b17ea17e976015ca5f4a66a986a1324bab1d59529d36055b46afc}"
# Per-release pinned URL. Each Anthropic release lives at a unique path with
# a git-sha-suffixed filename. To bump: pull the matching values out of
# aaddrick/claude-desktop-debian -> scripts/setup/detect-host.sh at the
# desired release tag.
: "${CLAUDE_VERSION:=1.7196.1}"
: "${CLAUDE_RELEASE_SHA:=abcd6556f79f4cca317ff02bfe0bedbeeb6e56a9}"
: "${BUILT_IN_DOCKER:=0}"
#!/bin/bash
set -euo pipefail

# --- Architecture Detection ---
echo -e "\033[1;36m--- Architecture Detection ---\033[0m"
echo "⚙️ Detecting system architecture..."
HOST_ARCH=$(dpkg --print-architecture)
echo "Detected host architecture: $HOST_ARCH"
cat /etc/os-release && uname -m && dpkg --print-architecture

# Set variables based on detected architecture
if [ "$HOST_ARCH" = "amd64" ]; then
    CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/x64/${CLAUDE_VERSION}/Claude-${CLAUDE_RELEASE_SHA}.exe"
    ARCHITECTURE="amd64"
    CLAUDE_EXE_FILENAME="Claude-Setup-x64.exe"
    echo "Configured for amd64 build."
elif [ "$HOST_ARCH" = "arm64" ]; then
    CLAUDE_DOWNLOAD_URL="https://downloads.claude.ai/releases/win32/arm64/${CLAUDE_VERSION}/Claude-${CLAUDE_RELEASE_SHA}.exe"
    ARCHITECTURE="arm64"
    CLAUDE_EXE_FILENAME="Claude-Setup-arm64.exe"
    echo "Configured for arm64 build."
else
    echo "❌ Unsupported architecture: $HOST_ARCH. This script currently supports amd64 and arm64."
    exit 1
fi
echo "Target Architecture (detected): $ARCHITECTURE" # Renamed echo
echo -e "\033[1;36m--- End Architecture Detection ---\033[0m"


if [ ! -f "/etc/debian_version" ]; then
    echo "❌ This script requires a Debian-based Linux distribution"
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
   echo "❌ This script should not be run using sudo or as the root user."
   echo "   It will prompt for sudo password when needed for specific actions."
   echo "   Please run as a normal user."
   exit 1
fi

ORIGINAL_USER=$(whoami)
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)
if [ -z "$ORIGINAL_HOME" ]; then
    echo "❌ Could not determine home directory for user $ORIGINAL_USER."
    exit 1
fi
echo "Running as user: $ORIGINAL_USER (Home: $ORIGINAL_HOME)"

# Check for NVM and source it if found to ensure npm/npx are available later
if [ -d "$ORIGINAL_HOME/.nvm" ]; then
    echo "Found NVM installation for user $ORIGINAL_USER, attempting to activate..."
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # Source NVM script to set up NVM environment variables temporarily
        # shellcheck disable=SC1091
        \. "$NVM_DIR/nvm.sh" # This loads nvm
        # Initialize and find the path to the currently active or default Node version's bin directory
        NODE_BIN_PATH=""
        NODE_BIN_PATH=$(nvm which current | xargs dirname 2>/dev/null || find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

        if [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ]; then
            echo "Adding NVM Node bin path to PATH: $NODE_BIN_PATH"
            export PATH="$NODE_BIN_PATH:$PATH"
        else
            echo "Warning: Could not determine NVM Node bin path. npm/npx might not be found."
        fi
    else
        echo "Warning: nvm.sh script not found or not sourceable."
    fi
fi # End of if [ -d "$ORIGINAL_HOME/.nvm" ] check


echo "System Information:"
echo "Distribution: $(grep "PRETTY_NAME" /etc/os-release | cut -d'"' -f2)"
echo "Debian version: $(cat /etc/debian_version)"
echo "Target Architecture: $ARCHITECTURE" 
PACKAGE_NAME="claude-desktop"
MAINTAINER="Claude Desktop Linux Maintainers"
DESCRIPTION="Claude Desktop for Linux"
PROJECT_ROOT="$(pwd)" WORK_DIR="$PROJECT_ROOT/build" APP_STAGING_DIR="$WORK_DIR/electron-app" VERSION="" 
echo -e "\033[1;36m--- Argument Parsing ---\033[0m"
BUILD_FORMAT="deb"    CLEANUP_ACTION="yes"  TEST_FLAGS_MODE=false
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -b|--build)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        BUILD_FORMAT="$2"
        shift 2 ;; # Shift past flag and value
        -c|--clean)
        if [[ -z "$2" || "$2" == -* ]]; then              echo "❌ Error: Argument for $1 is missing" >&2; exit 1
        fi
        CLEANUP_ACTION="$2"
        shift 2 ;; # Shift past flag and value
        --test-flags)
        TEST_FLAGS_MODE=true
        shift # past argument
        ;;
        -h|--help)
        echo "Usage: $0 [--build deb] [--clean yes|no] [--test-flags]"
        echo "  --build: Specify the build format (deb only). Default: deb"
        echo "  --clean: Specify whether to clean intermediate build files (yes or no). Default: yes"
        echo "  --test-flags: Parse flags, print results, and exit without building."
        exit 0
        ;;
        *)            echo "❌ Unknown option: $1" >&2
        echo "Use -h or --help for usage information." >&2
        exit 1
        ;;
    esac
done

# Validate arguments
BUILD_FORMAT=$(echo "$BUILD_FORMAT" | tr '[:upper:]' '[:lower:]') CLEANUP_ACTION=$(echo "$CLEANUP_ACTION" | tr '[:upper:]' '[:lower:]')
if [[ "$BUILD_FORMAT" != "deb" ]]; then
    echo "❌ Invalid build format specified: '$BUILD_FORMAT'. Must be 'deb'." >&2
    exit 1
fi
if [[ "$CLEANUP_ACTION" != "yes" && "$CLEANUP_ACTION" != "no" ]]; then
    echo "❌ Invalid cleanup option specified: '$CLEANUP_ACTION'. Must be 'yes' or 'no'." >&2
    exit 1
fi

echo "Selected build format: $BUILD_FORMAT"
echo "Cleanup intermediate files: $CLEANUP_ACTION"

PERFORM_CLEANUP=false
if [ "$CLEANUP_ACTION" = "yes" ]; then
    PERFORM_CLEANUP=true
fi
echo -e "\033[1;36m--- End Argument Parsing ---\033[0m"

# Exit early if --test-flags mode is enabled
if [ "$TEST_FLAGS_MODE" = true ]; then
    echo "--- Test Flags Mode Enabled ---"
    # Target Architecture is implicitly detected now
    echo "Build Format: $BUILD_FORMAT"
    echo "Clean Action: $CLEANUP_ACTION"
    echo "Exiting without build."
    exit 0
fi


check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "❌ $1 not found"
        return 1
    else
        echo "✓ $1 found"
        return 0
    fi
}

echo "Checking dependencies..."
DEPS_TO_INSTALL=""
COMMON_DEPS="curl file p7zip wget wrestool icotool convert npx"
DEB_DEPS="dpkg-deb"
ALL_DEPS_TO_CHECK="$COMMON_DEPS"
if [ "$BUILD_FORMAT" = "deb" ]; then
    ALL_DEPS_TO_CHECK="$ALL_DEPS_TO_CHECK $DEB_DEPS"
fi

for cmd in $ALL_DEPS_TO_CHECK; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "p7zip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-full" ;;
            "curl") DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
            "file") DEPS_TO_INSTALL="$DEPS_TO_INSTALL file" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL imagemagick" ;;
            "npx") DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
            "dpkg-deb") DEPS_TO_INSTALL="$DEPS_TO_INSTALL dpkg-dev" ;;
        esac
    fi
done

if [ -n "$DEPS_TO_INSTALL" ]; then
    echo "System dependencies needed: $DEPS_TO_INSTALL"
    echo "Attempting to install using sudo..."
        if ! sudo -v; then
        echo "❌ Failed to validate sudo credentials. Please ensure you can run sudo."
        exit 1
    fi
        if ! sudo apt update; then
        echo "❌ Failed to run 'sudo apt update'."
        exit 1
    fi
    # Here on purpose no "" to expand the 'list', thus
    # shellcheck disable=SC2086
    if ! sudo apt install -y $DEPS_TO_INSTALL; then
         echo "❌ Failed to install dependencies using 'sudo apt install'."
         exit 1
    fi
    echo "✓ System dependencies installed successfully via sudo."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$APP_STAGING_DIR" 
echo -e "\033[1;36m--- Electron & Asar Handling ---\033[0m"
CHOSEN_ELECTRON_MODULE_PATH="" ASAR_EXEC=""

echo "Ensuring local Electron and Asar installation in $WORK_DIR..."
cd "$WORK_DIR"
if [ ! -f "package.json" ]; then
    echo "Creating temporary package.json in $WORK_DIR for local install..."
    echo '{"name":"claude-desktop-build","version":"0.0.1","private":true}' > package.json
fi

ELECTRON_DIST_PATH="$WORK_DIR/node_modules/electron/dist"
ASAR_BIN_PATH="$WORK_DIR/node_modules/.bin/asar"

INSTALL_NEEDED=false
if [ ! -d "$ELECTRON_DIST_PATH" ]; then
    echo "Electron distribution not found."
    INSTALL_NEEDED=true
fi
if [ ! -f "$ASAR_BIN_PATH" ]; then
    echo "Asar binary not found."
    INSTALL_NEEDED=true
fi

if [ "$INSTALL_NEEDED" = true ]; then
    echo "Installing Electron and Asar locally into $WORK_DIR..."
        if ! npm install --no-save electron @electron/asar; then
        echo "❌ Failed to install Electron and/or Asar locally."
        cd "$PROJECT_ROOT"
        exit 1
    fi
    echo "✓ Electron and Asar installation command finished."
    # Some npm versions skip Electron's postinstall (which fetches the prebuilt
    # binaries into node_modules/electron/dist). Run it explicitly as a fallback.
    if [ ! -d "$ELECTRON_DIST_PATH" ] && [ -f "node_modules/electron/install.js" ]; then
        echo "Electron dist/ missing after npm install; running install.js manually..."
        if ! node node_modules/electron/install.js; then
            echo "❌ Electron install.js failed to download prebuilt binaries."
            cd "$PROJECT_ROOT"
            exit 1
        fi
    fi
else
    echo "✓ Local Electron distribution and Asar binary already present."
fi

if [ -d "$ELECTRON_DIST_PATH" ]; then
    echo "✓ Found Electron distribution directory at $ELECTRON_DIST_PATH."
    CHOSEN_ELECTRON_MODULE_PATH="$(realpath "$WORK_DIR/node_modules/electron")"
    echo "✓ Setting Electron module path for copying to $CHOSEN_ELECTRON_MODULE_PATH."
else
    echo "❌ Failed to find Electron distribution directory at '$ELECTRON_DIST_PATH' after installation attempt."
    echo "   Cannot proceed without the Electron distribution files."
    cd "$PROJECT_ROOT"
    exit 1
fi

if [ -f "$ASAR_BIN_PATH" ]; then
    ASAR_EXEC="$(realpath "$ASAR_BIN_PATH")"
    echo "✓ Found local Asar binary at $ASAR_EXEC."
else
    echo "❌ Failed to find Asar binary at '$ASAR_BIN_PATH' after installation attempt."
    cd "$PROJECT_ROOT"
    exit 1
fi

cd "$PROJECT_ROOT" 
if [ -z "$CHOSEN_ELECTRON_MODULE_PATH" ] || [ ! -d "$CHOSEN_ELECTRON_MODULE_PATH" ]; then
     echo "❌ Critical error: Could not resolve a valid Electron module path to copy."
     exit 1
fi
echo "Using Electron module path: $CHOSEN_ELECTRON_MODULE_PATH"
echo "Using asar executable: $ASAR_EXEC"


echo -e "\033[1;36m--- Download the latest Claude executable ---\033[0m"
echo "📥 Downloading Claude Desktop installer for $ARCHITECTURE..."
CLAUDE_EXE_PATH="$WORK_DIR/$CLAUDE_EXE_FILENAME"
if ! curl -fSL --retry 3 "$CLAUDE_DOWNLOAD_URL" -o "$CLAUDE_EXE_PATH"; then
    echo "❌ Failed to download Claude Desktop installer from $CLAUDE_DOWNLOAD_URL"
    exit 1
fi
echo "✓ Download complete: $CLAUDE_EXE_FILENAME"

echo "🔐 Verifying SHA256 checksum..."
if [ "$ARCHITECTURE" = "amd64" ]; then
    EXPECTED_HASH=${AMD64_EXPECTED_HASH}
elif [ "$ARCHITECTURE" = "arm64" ]; then
    EXPECTED_HASH=${ARM64_EXPECTED_HASH}
else
    echo "Unknown architecture: $ARCHITECTURE"
    exit 1
fi

ACTUAL_HASH=$(sha256sum "$CLAUDE_EXE_PATH" | awk '{print $1}')
if [[ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]]; then
    echo "❌ SHA256 checksum mismatch!"
    echo "Expected: $EXPECTED_HASH"
    echo "Actual:   $ACTUAL_HASH"
    exit 1
fi
echo "✅ File integrity verified."

echo "📦 Extracting resources from $CLAUDE_EXE_FILENAME into separate directory..."
CLAUDE_EXTRACT_DIR="$WORK_DIR/claude-extract"
mkdir -p "$CLAUDE_EXTRACT_DIR"
if ! 7z x -y "$CLAUDE_EXE_PATH" -o"$CLAUDE_EXTRACT_DIR"; then     echo "❌ Failed to extract installer"
    cd "$PROJECT_ROOT" && exit 1
fi

cd "$CLAUDE_EXTRACT_DIR" # Change into the extract dir to find files
NUPKG_PATH_RELATIVE=$(find . -maxdepth 1 -name "AnthropicClaude-*.nupkg" | head -1)
if [ -z "$NUPKG_PATH_RELATIVE" ]; then
    echo "❌ Could not find AnthropicClaude nupkg file in $CLAUDE_EXTRACT_DIR"
    cd "$PROJECT_ROOT" && exit 1
fi
NUPKG_PATH="$CLAUDE_EXTRACT_DIR/$NUPKG_PATH_RELATIVE" echo "Found nupkg: $NUPKG_PATH_RELATIVE (in $CLAUDE_EXTRACT_DIR)"

VERSION=$(echo "$NUPKG_PATH_RELATIVE" | LC_ALL=C grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full|-arm64-full)')
if [ -z "$VERSION" ]; then
    echo "❌ Could not extract version from nupkg filename: $NUPKG_PATH_RELATIVE"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Detected Claude version: $VERSION"

if ! 7z x -y "$NUPKG_PATH_RELATIVE"; then     echo "❌ Failed to extract nupkg"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "✓ Resources extracted from nupkg"

EXE_RELATIVE_PATH="lib/net45/claude.exe" # Check if this path is correct for arm64 too
if [ ! -f "$EXE_RELATIVE_PATH" ]; then
    echo "❌ Cannot find claude.exe at expected path within extraction dir: $CLAUDE_EXTRACT_DIR/$EXE_RELATIVE_PATH"
    cd "$PROJECT_ROOT" && exit 1
fi
echo "🎨 Processing icons from $EXE_RELATIVE_PATH..."
if ! wrestool -x -t 14 "$EXE_RELATIVE_PATH" -o claude.ico; then     echo "❌ Failed to extract icons from exe"
    cd "$PROJECT_ROOT" && exit 1
fi

if ! icotool -x claude.ico; then     echo "❌ Failed to convert icons"
    cd "$PROJECT_ROOT" && exit 1
fi
cp claude_*.png "$WORK_DIR/"
echo "✓ Icons processed and copied to $WORK_DIR"

echo "⚙️ Processing app.asar..."
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar" "$APP_STAGING_DIR/"
cp -a "$CLAUDE_EXTRACT_DIR/lib/net45/resources/app.asar.unpacked" "$APP_STAGING_DIR/" 
cd "$APP_STAGING_DIR" 
"$ASAR_EXEC" extract app.asar app.asar.contents

echo "Creating stub native module..."
# Locate the claude-native module. In 0.x it was at node_modules/claude-native;
# in 1.x (post-Apr 2026) it moved to node_modules/@ant/claude-native.
CLAUDE_NATIVE_DIR=""
for candidate in \
    "app.asar.contents/node_modules/@ant/claude-native" \
    "app.asar.contents/node_modules/claude-native"; do
    if [ -d "$candidate" ]; then
        CLAUDE_NATIVE_DIR="$candidate"
        break
    fi
done
if [ -z "$CLAUDE_NATIVE_DIR" ]; then
    echo "❌ Could not locate claude-native module in extracted app.asar."
    exit 1
fi
echo "Stubbing native module at $CLAUDE_NATIVE_DIR"
cat > "$CLAUDE_NATIVE_DIR/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

mkdir -p app.asar.contents/resources
mkdir -p app.asar.contents/resources/i18n
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/Tray"* app.asar.contents/resources/
cp "$CLAUDE_EXTRACT_DIR/lib/net45/resources/"*-*.json app.asar.contents/resources/i18n/

echo "##############################################################"
echo "Removing "'!'" from 'if ("'!'"isWindows && isMainWindow) return null;'"
echo "detection flag to to enable title bar"

echo "Current working directory: '$PWD'"

SEARCH_BASE="app.asar.contents/.vite/renderer/main_window/assets"
TARGET_PATTERN="MainWindowPage-*.js"

echo "Searching for '$TARGET_PATTERN' within '$SEARCH_BASE'..."
# Find the target file recursively (ensure only one matches)
TARGET_FILES=$(find "$SEARCH_BASE" -type f -name "$TARGET_PATTERN")
# Count non-empty lines to get the number of files found
NUM_FILES=$(echo "$TARGET_FILES" | grep -c .)

if [ "$NUM_FILES" -eq 0 ]; then
  echo "Error: No file matching '$TARGET_PATTERN' found within '$SEARCH_BASE'." >&2
  exit 1
elif [ "$NUM_FILES" -gt 1 ]; then
  echo "Error: Expected exactly one file matching '$TARGET_PATTERN' within '$SEARCH_BASE', but found $NUM_FILES." >&2
  echo "Found files:" >&2
  echo "$TARGET_FILES" >&2
  exit 1
else
  # Exactly one file found
  TARGET_FILE="$TARGET_FILES" # Assign the found file path
  echo "Found target file: $TARGET_FILE"
  echo "Attempting to replace patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE..."
  # Use character classes [a-zA-Z]+ to match minified variable names
  # Capture group 1: first variable name
  # Capture group 2: second variable name
  sed -i -E 's/if\(!([a-zA-Z]+)[[:space:]]*&&[[:space:]]*([a-zA-Z]+)\)/if(\1 \&\& \2)/g' "$TARGET_FILE"

  # Verification: Check if the original pattern structure still exists
  if ! grep -q -E 'if\(![a-zA-Z]+[[:space:]]*&&[[:space:]]*[a-zA-Z]+\)' "$TARGET_FILE"; then
    echo "Successfully replaced patterns like 'if(!VAR1 && VAR2)' with 'if(VAR1 && VAR2)' in $TARGET_FILE"
  else
    echo "Error: Failed to replace patterns like 'if(!VAR1 && VAR2)' in $TARGET_FILE. Check file contents." >&2
    exit 1
  fi
fi
echo "##############################################################"

"$ASAR_EXEC" pack app.asar.contents app.asar

# Mirror the stub at the same relative path used inside the app.asar (see above).
# In 1.x this is @ant/claude-native; in 0.x it was claude-native.
UNPACKED_NATIVE_REL="${CLAUDE_NATIVE_DIR#app.asar.contents/}"
UNPACKED_NATIVE_DIR="$APP_STAGING_DIR/app.asar.unpacked/$UNPACKED_NATIVE_REL"
mkdir -p "$UNPACKED_NATIVE_DIR"
cat > "$UNPACKED_NATIVE_DIR/index.js" << EOF
// Stub implementation of claude-native using KeyboardKey enum values
const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);
module.exports = { getWindowsVersion: () => "10.0.0", setWindowEffect: () => {}, removeWindowEffect: () => {}, getIsMaximized: () => false, flashFrame: () => {}, clearFlashFrame: () => {}, showNotification: () => {}, setProgressBar: () => {}, clearProgressBar: () => {}, setOverlayIcon: () => {}, clearOverlayIcon: () => {}, KeyboardKey };
EOF

echo "Copying chosen electron installation to staging area..."
mkdir -p "$APP_STAGING_DIR/node_modules/"
ELECTRON_DIR_NAME=$(basename "$CHOSEN_ELECTRON_MODULE_PATH")
echo "Copying from $CHOSEN_ELECTRON_MODULE_PATH to $APP_STAGING_DIR/node_modules/"
cp -a "$CHOSEN_ELECTRON_MODULE_PATH" "$APP_STAGING_DIR/node_modules/" 
STAGED_ELECTRON_BIN="$APP_STAGING_DIR/node_modules/$ELECTRON_DIR_NAME/dist/electron"
if [ -f "$STAGED_ELECTRON_BIN" ]; then
    echo "Setting executable permission on staged Electron binary: $STAGED_ELECTRON_BIN"
    chmod +x "$STAGED_ELECTRON_BIN"
else
    echo "Warning: Staged Electron binary not found at expected path: $STAGED_ELECTRON_BIN"
fi

echo "✓ app.asar processed and staged in $APP_STAGING_DIR"

cd "$PROJECT_ROOT"

echo -e "\033[1;36m--- Call Packaging Script ---\033[0m"
FINAL_OUTPUT_PATH="" 
if [ "$BUILD_FORMAT" = "deb" ]; then
    echo "📦 Calling Debian packaging script for $ARCHITECTURE..."
    chmod +x scripts/build-deb-package.sh
    if ! scripts/build-deb-package.sh \
        "$VERSION" "$ARCHITECTURE" "$WORK_DIR" "$APP_STAGING_DIR" \
        "$PACKAGE_NAME" "$MAINTAINER" "$DESCRIPTION"; then
        echo "❌ Debian packaging script failed."
        exit 1
    fi
    DEB_FILE=$(find "$WORK_DIR" -maxdepth 1 -name "${PACKAGE_NAME}_${VERSION}_${ARCHITECTURE}.deb" | head -n 1)
    echo "✓ Debian Build complete!"
    if [ -n "$DEB_FILE" ] && [ -f "$DEB_FILE" ]; then
        FINAL_OUTPUT_PATH="./$(basename "$DEB_FILE")" # Set final path using basename directly
        mv "$DEB_FILE" "$FINAL_OUTPUT_PATH"
        echo "Package created at: $FINAL_OUTPUT_PATH"
    else
        echo "Warning: Could not determine final .deb file path from $WORK_DIR for ${ARCHITECTURE}."
        FINAL_OUTPUT_PATH="Not Found"
    fi

fi


echo -e "\033[1;36m--- Cleanup ---\033[0m"
if [ "$PERFORM_CLEANUP" = true ]; then     echo "🧹 Cleaning up intermediate build files in $WORK_DIR..."
        if rm -rf "$WORK_DIR"; then
        echo "✓ Cleanup complete ($WORK_DIR removed)."
    else
        echo "⚠️ Cleanup command (rm -rf $WORK_DIR) failed."
    fi
else
    echo "Skipping cleanup of intermediate build files in $WORK_DIR."
fi


echo "✅ Build process finished."

echo -e "\n\033[1;34m====== Next Steps ======\033[0m"
if [ "$BUILD_FORMAT" = "deb" ]; then
    if [ "$FINAL_OUTPUT_PATH" != "Not Found" ] && [ -e "$FINAL_OUTPUT_PATH" ]; then
        echo -e "📦 To install the Debian package, run:"
        echo -e "   \033[1;32msudo apt install $FINAL_OUTPUT_PATH\033[0m"
        echo -e "   (or \`sudo dpkg -i $FINAL_OUTPUT_PATH\`)"
    else
        echo -e "⚠️ Debian package file not found. Cannot provide installation instructions."
    fi
fi
echo -e "\033[1;34m======================\033[0m"

if [ "$BUILT_IN_DOCKER" = 1 ]; then
  mv -v "$FINAL_OUTPUT_PATH" ./output/
fi
exit 0
