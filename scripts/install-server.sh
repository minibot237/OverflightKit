#!/bin/sh
# Build the query API server in release mode, install it under ~/.overflight,
# copy the web UI, and (re)load its LaunchAgent.
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.overflight"
LABEL="com.overflightkit.server"

echo "Building OverflightServer (release)..."
swift build -c release --product OverflightServer
BIN_DIR="$(swift build -c release --product OverflightServer --show-bin-path)"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/log" "$INSTALL_DIR/web" "$HOME/Library/LaunchAgents"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# rm first: cp over an exec'ing Mach-O wedges the exec (see install-agent.sh).
rm -f "$INSTALL_DIR/bin/OverflightServer"
cp "$BIN_DIR/OverflightServer" "$INSTALL_DIR/bin/"
[ -f web/index.html ] && cp web/index.html "$INSTALL_DIR/web/"

PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
	launchd/com.overflightkit.server.plist.template > "$PLIST_DEST"

i=0
while ! launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null; do
	i=$((i + 1))
	if [ $i -ge 5 ]; then
		echo "failed to bootstrap $LABEL" >&2
		exit 1
	fi
	sleep 1
done
echo "started $LABEL -> log/server.log"
