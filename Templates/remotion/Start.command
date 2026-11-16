#!/bin/bash
# Double-click to open this video in Remotion Studio.
# The first run installs Remotion and its AI skills into this folder.
cd "$(dirname "$0")" || exit 1

stop() {
    echo
    echo "$1"
    read -r -p "Press Return to close this window."
    exit 1
}

command -v npm >/dev/null 2>&1 || stop "Node.js is needed to run Remotion. Install it from https://nodejs.org, then double-click Start again."

if [ ! -d node_modules ]; then
    echo "Installing Remotion (first time only, a few minutes)…"
    npm install --no-audit --no-fund || stop "The install did not finish. Check your internet connection and double-click Start again."
fi

if [ ! -d .agents/skills ] && [ ! -d .claude/skills ]; then
    echo "Adding Remotion's skills for AI coding agents…"
    npx remotion skills add </dev/null || echo "The skills could not be added. Run 'npm run skills' later; everything else works without them."
fi

echo "Opening Remotion Studio in your browser. Close this window to stop it."
npm run dev
