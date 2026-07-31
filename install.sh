#!/bin/bash
# install.sh — put the four commands on PATH and seed $SYNCHEALTH_HOME.
#
# Nothing here needs root and nothing is started automatically: the watcher and
# the server are opt-in, because each has a prerequisite you should decide about
# (a watch directory, a token and a tunnel). See README.md.
set -euo pipefail
umask 077
cd "$(dirname "$0")"

BIN="${BIN:-$HOME/.local/bin}"
HOME_DIR="${SYNCHEALTH_HOME:-$HOME/.synchealth}"

install -d -m 755 "$BIN"
install -d -m 700 "$HOME_DIR"
install -m 755 bin/synchealth-import bin/synchealth-watch bin/synchealth-server bin/health "$BIN/"
echo "installed 4 commands -> $BIN"

# Context is curated and source-linked where a broad range applies. Seed only:
# an existing copy carries your personal goals and is left alone.
if [ -f "$HOME_DIR/health-targets.json" ]; then
  echo "kept existing $HOME_DIR/health-targets.json (your goals)"
else
  cp health-targets.json "$HOME_DIR/"
  chmod 600 "$HOME_DIR/health-targets.json"
  echo "seeded $HOME_DIR/health-targets.json"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo; echo "note: $BIN is not on PATH — add it to your shell profile" ;;
esac

cat <<EOF

next:
  1. create ~/.synchealth/server.json with a random token (see README.md)
  2. start synchealth-server, then expose only its /health path through HTTPS
  3. build ios/FreeReps.xcodeproj for your iPhone and run Full Sync once
  4. health                    # read the locally stored history

optional recovery:
  launchd/com.synchealth.watch.plist imports a manual Health export when you
  need to repair or independently compare the history.
EOF
