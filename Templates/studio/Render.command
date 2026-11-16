#!/bin/bash
# Double-click to render the finished videos into the out folder,
# one for each size listed in the storyboard.
cd "$(dirname "$0")" || exit 1

if [ ! -d node_modules ]; then
    echo "Run Start first: it installs Remotion."
    read -r -p "Press Return to close this window."
    exit 1
fi

npm run render && open out
read -r -p "Press Return to close this window."
