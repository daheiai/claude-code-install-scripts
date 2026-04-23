#!/bin/sh

set -e

# Parse command line arguments
TARGET="$1"  # Optional target parameter

# Validate target if provided
if [ -n "$TARGET" ]; then
    case "$TARGET" in
        stable|latest) ;;
        *)
            if ! printf '%s\n' "$TARGET" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[^[:space:]]+)?$'; then
                echo "Usage: $0 [stable|latest|VERSION]" >&2
                exit 1
            fi
            ;;
    esac
fi

GCS_BUCKET="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"
DOWNLOAD_DIR="$HOME/.claude/downloads"
INSTALL_BASE="$HOME/.local/share/claude"
VERSIONS_DIR="$INSTALL_BASE/versions"
BIN_DIR="$HOME/.local/bin"
LINK_PATH="$BIN_DIR/claude"
CONFIG_PATH="$HOME/.claude.json"
STATE_DIR="$HOME/.local/state/claude/locks"
CACHE_DIR="$HOME/.cache/claude/staging"
DOWNLOADS_DIR="$HOME/.claude/downloads"
PATH_EXPORT='export PATH="$HOME/.local/bin:$PATH"'

# Check for required dependencies
DOWNLOADER=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
else
    echo "Either curl or wget is required but neither is installed" >&2
    exit 1
fi

# Check if jq is available (optional)
HAS_JQ=false
if command -v jq >/dev/null 2>&1; then
    HAS_JQ=true
fi

# Download function that works with both curl and wget
download_file() {
    url="$1"
    output="$2"
    
    if [ "$DOWNLOADER" = "curl" ]; then
        if [ -n "$output" ]; then
            curl -fL --progress-bar -o "$output" "$url"
        else
            curl -fsSL "$url"
        fi
    elif [ "$DOWNLOADER" = "wget" ]; then
        if [ -n "$output" ]; then
            wget -O "$output" "$url"
        else
            wget -q -O - "$url"
        fi
    else
        return 1
    fi
}

write_config() {
    config_path="$1"
    first_start_time="$2"
    tmp_config=$(mktemp)

    if command -v python3 >/dev/null 2>&1; then
        CONFIG_PATH="$config_path" FIRST_START_TIME="$first_start_time" python3 <<'PY' > "$tmp_config"
import json
import os
from pathlib import Path

config_path = Path(os.environ["CONFIG_PATH"])
first_start_time = os.environ["FIRST_START_TIME"]

data = {}
if config_path.exists():
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except Exception:
        data = {}

data["installMethod"] = "native"
data["autoUpdates"] = False
data["autoUpdatesProtectedForNative"] = True
data.setdefault("firstStartTime", first_start_time)

print(json.dumps(data, ensure_ascii=False, indent=2))
PY
    else
        cat > "$tmp_config" <<EOF
{
  "installMethod": "native",
  "autoUpdates": false,
  "autoUpdatesProtectedForNative": true,
  "firstStartTime": "$first_start_time"
}
EOF
    fi

    mv "$tmp_config" "$config_path"
}

ensure_path_in_file() {
    profile_path="$1"

    if [ ! -f "$profile_path" ]; then
        touch "$profile_path"
    fi

    if ! grep -Fqs "$PATH_EXPORT" "$profile_path"; then
        printf '\n%s\n' "$PATH_EXPORT" >> "$profile_path"
    fi
}

configure_shell_path() {
    updated_profiles=""

    if [ -n "$SHELL" ]; then
        case "$SHELL" in
            */zsh)
                ensure_path_in_file "$HOME/.zshrc"
                updated_profiles="$updated_profiles ~/.zshrc"
                ;;
            */bash)
                ensure_path_in_file "$HOME/.bashrc"
                updated_profiles="$updated_profiles ~/.bashrc"
                ;;
        esac
    fi

    if [ -z "$updated_profiles" ]; then
        ensure_path_in_file "$HOME/.profile"
        updated_profiles=" ~/.profile"
    fi

    printf '%s\n' "$updated_profiles" | awk '{$1=$1; print}'
}

# Simple JSON parser for extracting checksum when jq is not available
get_checksum_from_manifest() {
    json="$1"
    platform="$2"
    
    # Normalize JSON to single line and extract checksum
    json=$(echo "$json" | tr -d '\n\r\t' | sed 's/ \+/ /g')
    
    echo "$json" | sed -n "s/.*\"$platform\"[^}]*\"checksum\"[[:space:]]*:[[:space:]]*\"\\([a-f0-9][a-f0-9]*\\)\".*/\\1/p" | head -n 1
}

# Detect platform
case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux) os="linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "Windows is not supported by this script. See https://code.claude.com/docs for installation options." >&2; exit 1 ;;
    *) echo "Unsupported operating system: $(uname -s). See https://code.claude.com/docs for supported platforms." >&2; exit 1 ;;
esac

case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# Detect Rosetta 2 on macOS: if the shell is running as x64 under Rosetta on an ARM Mac,
# download the native arm64 binary instead of the x64 one
if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        arch="arm64"
    fi
fi

# Check for musl on Linux and adjust platform accordingly
if [ "$os" = "linux" ]; then
    if [ -f /lib/libc.musl-x86_64.so.1 ] || [ -f /lib/libc.musl-aarch64.so.1 ] || ldd /bin/ls 2>&1 | grep -q musl; then
        platform="linux-${arch}-musl"
    else
        platform="linux-${arch}"
    fi
else
    platform="${os}-${arch}"
fi
mkdir -p "$DOWNLOAD_DIR"

# Always download latest version (which has the most up-to-date installer)
version=$(download_file "$GCS_BUCKET/latest")

# Download manifest and extract checksum
manifest_json=$(download_file "$GCS_BUCKET/$version/manifest.json")

# Use jq if available, otherwise fall back to pure bash parsing
if [ "$HAS_JQ" = true ]; then
    checksum=$(echo "$manifest_json" | jq -r ".platforms[\"$platform\"].checksum // empty")
else
    checksum=$(get_checksum_from_manifest "$manifest_json" "$platform")
fi

# Validate checksum format (SHA256 = 64 hex characters)
if [ -z "$checksum" ] || ! printf '%s\n' "$checksum" | grep -Eq '^[a-f0-9]{64}$'; then
    echo "Platform $platform not found in manifest" >&2
    exit 1
fi

# Download and verify
binary_path="$DOWNLOAD_DIR/claude-$version-$platform"
echo "Claude Code version: $version"
echo "Platform: $platform"
echo "Download source: $GCS_BUCKET/$version/$platform/claude"
echo "Downloading Claude Code binary..."
if ! download_file "$GCS_BUCKET/$version/$platform/claude" "$binary_path"; then
    echo "Download failed" >&2
    rm -f "$binary_path"
    exit 1
fi

# Pick the right checksum tool
if [ "$os" = "darwin" ]; then
    actual=$(shasum -a 256 "$binary_path" | cut -d' ' -f1)
else
    actual=$(sha256sum "$binary_path" | cut -d' ' -f1)
fi

if [ "$actual" != "$checksum" ]; then
    echo "Checksum verification failed" >&2
    rm -f "$binary_path"
    exit 1
fi

chmod +x "$binary_path"

# Install directly without invoking the bundled installer.
echo "Setting up Claude Code..."
mkdir -p "$VERSIONS_DIR" "$BIN_DIR" "$STATE_DIR" "$CACHE_DIR" "$DOWNLOADS_DIR" "$HOME/.claude/backups"

final_path="$VERSIONS_DIR/$version"
rm -f "$final_path"
mv "$binary_path" "$final_path"
chmod +x "$final_path"
ln -sfn "$final_path" "$LINK_PATH"

first_start_time="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
if [ -f "$CONFIG_PATH" ]; then
    cp "$CONFIG_PATH" "$HOME/.claude/backups/.claude.json.backup.$(date +%s)" 2>/dev/null || true
fi
write_config "$CONFIG_PATH" "$first_start_time"
updated_profiles="$(configure_shell_path)"

echo ""
echo "Claude Code successfully installed!"
echo ""
echo "Version: $version"
echo "Location: $LINK_PATH"
echo ""
echo "PATH updated in: $updated_profiles"
echo "Run this in your current terminal to use claude right now:"
echo "$PATH_EXPORT"

echo ""
echo "✅ Installation complete!"
echo ""
