#!/bin/bash
# install.sh — put the four commands on PATH and seed $SYNCHEALTH_HOME.
#
# Nothing here needs root and nothing is started automatically: the watcher and
# the server are opt-in, because each has a prerequisite you should decide about
# (a watch directory, a token and a tunnel). See README.md.
set -euo pipefail
cd "$(dirname "$0")"

BIN="${BIN:-$HOME/.local/bin}"
HOME_DIR="${SYNCHEALTH_HOME:-$HOME/.synchealth}"

mkdir -p "$BIN" "$HOME_DIR"
install -m 755 bin/synchealth-import bin/synchealth-watch bin/synchealth-server bin/health "$BIN/"
echo "installed 4 commands -> $BIN"

# Targets are curated (a citation per entry), so the checkout is the source of
# truth. Seed only: an existing copy carries your edited goals and is left alone.
if [ -f "$HOME_DIR/health-targets.json" ]; then
  echo "kept existing $HOME_DIR/health-targets.json (your goals)"
else
  cp health-targets.json "$HOME_DIR/"
  echo "seeded $HOME_DIR/health-targets.json"
fi

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo; echo "note: $BIN is not on PATH — add it to your shell profile" ;;
esac

cat <<EOF

next:
  1. iPhone: Health app -> profile -> Export All Health Data
  2. save export.zip to ~/Downloads (or iCloud Drive/HealthExports)
  3. synchealth-watch          # unzip, import, archive
  4. health                    # read it

optional, for automatic daily data:
  launchd/  holds plist templates for the 15-minute watcher and the push server
EOF
