#!/bin/sh
# Build the collector in release mode, install it under ~/.overflight, and
# load one LaunchAgent per site so each runs headless and restarts on
# failure/login.
#
#   scripts/install-agent.sh            # agents for every configured site
#   scripts/install-agent.sh toledo     # just that site
set -eu
cd "$(dirname "$0")/.."

INSTALL_DIR="$HOME/.overflight"

echo "Building OverflightCollector (release)..."
swift build -c release --product OverflightCollector
BIN_DIR="$(swift build -c release --product OverflightCollector --show-bin-path)"
mkdir -p "$INSTALL_DIR/bin" "$INSTALL_DIR/log" "$HOME/Library/LaunchAgents"

# Unload everything that might hold the old binary open, including the
# pre-multi-site unsuffixed label. Remember what was running so a
# single-site install restarts the rest afterwards.
RUNNING=""
launchctl bootout "gui/$(id -u)/com.overflightkit.collector" 2>/dev/null || true
for existing in "$HOME"/Library/LaunchAgents/com.overflightkit.collector.*.plist; do
	[ -e "$existing" ] || continue
	NAME="$(basename "$existing" .plist)"
	launchctl bootout "gui/$(id -u)/$NAME" 2>/dev/null || true
	RUNNING="$RUNNING ${NAME#com.overflightkit.collector.}"
done
rm -f "$HOME/Library/LaunchAgents/com.overflightkit.collector.plist"

# rm first: cp over a Mach-O that is currently exec'ing wedges the exec in
# an unkillable UE state. A fresh inode never collides with a running image.
rm -f "$INSTALL_DIR/bin/OverflightCollector"
cp "$BIN_DIR/OverflightCollector" "$INSTALL_DIR/bin/"

if [ $# -gt 0 ]; then
	SLUGS="$* $RUNNING"
else
	SLUGS="$("$INSTALL_DIR/bin/OverflightCollector" --list-sites | cut -f1)"
fi
SLUGS="$(printf '%s\n' $SLUGS | sort -u)"

# bootout is asynchronous: bootstrapping a label that is still tearing down
# fails with EIO, so wait for the old instance to vanish and retry.
bootstrap_agent() {
	LABEL="$1"
	PLIST="$2"
	i=0
	while launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; do
		i=$((i + 1))
		[ $i -ge 10 ] && break
		sleep 1
	done
	i=0
	while ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; do
		i=$((i + 1))
		if [ $i -ge 5 ]; then
			echo "failed to bootstrap $LABEL" >&2
			return 1
		fi
		sleep 1
	done
}

for SLUG in $SLUGS; do
	LABEL="com.overflightkit.collector.$SLUG"
	PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
	sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__SLUG__|$SLUG|g" \
		launchd/com.overflightkit.collector.plist.template > "$PLIST_DEST"
	bootstrap_agent "$LABEL" "$PLIST_DEST"
	echo "started $LABEL -> log/$SLUG.log"
done

# Wide-area sweep rides the same binary with its own agent, when configured.
SWEEP="$("$INSTALL_DIR/bin/OverflightCollector" --sweep-check)"
if [ -n "$SWEEP" ]; then
	LABEL="com.overflightkit.sweep.$SWEEP"
	PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
	launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
	sed -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" -e "s|__SLUG__|$SWEEP|g" \
		launchd/com.overflightkit.sweep.plist.template > "$PLIST_DEST"
	bootstrap_agent "$LABEL" "$PLIST_DEST"
	echo "started $LABEL -> log/$SWEEP.log"
fi

echo ""
echo "Useful commands:"
echo "  tail -f $INSTALL_DIR/log/<slug>.log"
echo "  $INSTALL_DIR/bin/OverflightCollector --report --site <slug>"
echo "  scripts/uninstall-agent.sh [slug]"
