#!/bin/sh
# Install the nightly Parquet compaction job (03:30 Pacific, launchd).
# ARCHIVE_DIR can override the default ~/.overflight/archive — point it at
# the spinning disk once that exists.
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.overflight"
ARCHIVE_DIR="${ARCHIVE_DIR:-$INSTALL_DIR/archive}"
LABEL="com.overflightkit.compact"

command -v duckdb >/dev/null || { echo "duckdb CLI not found (brew install duckdb)" >&2; exit 1; }
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/log" "$ARCHIVE_DIR"
cp scripts/compact.sh "$INSTALL_DIR/bin/compact.sh"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__ARCHIVE_DIR__|$ARCHIVE_DIR|g" \
	launchd/com.overflightkit.compact.plist.template > "$PLIST_DEST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"
echo "scheduled $LABEL daily 03:30 -> archive at $ARCHIVE_DIR"
