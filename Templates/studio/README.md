# __TITLE__

This folder is a [Remotion](https://www.remotion.dev) project that Tasjeel built from a storyboard: a list of scenes, each with its words, pictures and length. It renders the same video in up to three sizes: wide (16:9), square and tall (9:16).

## Start

1. Install [Node.js](https://nodejs.org) if you do not have it.
2. Double-click **Start.command**. The first time it installs Remotion and Remotion's AI skills (a few minutes), then opens Remotion Studio in your browser. Pick **Wide**, **Square** or **Tall** on the left to see each size.

To get the finished files, double-click **Render.command**. It writes one video per size into `out/`.

## Change the video

- **Words, pictures, order, timing, colours:** change your storyboard file and build it again from Tasjeel into this same folder. Only `src/storyboard.json` and `public/media` are replaced; changes made to the code here are kept.
- **How a scene looks or moves:** each kind of scene is one file in `src/scenes/`. Open this folder in Claude Code (or another AI coding agent) and describe what you want, for example "make the hook text type itself out" or "give the numbers scene a darker card behind each figure". `AGENTS.md` tells the agent how the project works.

## What is in here

| Path | What it is |
| --- | --- |
| `src/storyboard.json` | The storyboard, checked and completed by Tasjeel |
| `public/media/` | Your pictures and clips, copied in; clips are trimmed to the part each scene uses |
| `src/Video.tsx` | Plays the scenes one after another |
| `src/scenes/` | Hook, Screen, Feature, Quote, Numbers, CallToAction |
| `src/lib/` | Helpers for sizing and motion |

## Licence

Remotion is free for individuals and small teams. Larger companies need a paid licence: see [remotion.dev/license](https://www.remotion.dev/license).
