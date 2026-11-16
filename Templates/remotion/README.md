# __TITLE__

This folder is a [Remotion](https://www.remotion.dev) project made by Tasjeel from one of your recordings. Remotion builds videos out of code, which means an AI coding agent can restyle this one for you: animated captions, title cards, chapter cards, an outro, anything you can describe.

## Start

1. Install [Node.js](https://nodejs.org) if you do not have it.
2. Double-click **Start.command**. The first time it installs Remotion and Remotion's AI skills (a few minutes), then opens Remotion Studio in your browser with the video ready to play.

To get the finished file, double-click **Render.command**. It writes `out/video.mp4`.

## Change it with AI

Open this folder in Claude Code (or Codex, Cursor and others) and say what you want:

- "Make the captions bigger and yellow, two words at a time."
- "Add a five-second outro listing the action items."
- "Make a 9:16 version for phones, with the captions in the middle."
- "Replace the title card with the title typed out letter by letter."

`AGENTS.md` tells the agent how this project is laid out, and Remotion's own skills (in `.agents/skills`) teach it Remotion's rules.

## Change it by hand

`src/settings.ts` has the switches: turn the title card, captions, chapter cards and progress bar on or off, and change the accent colour and font.

## What is in here

| Path | What it is |
| --- | --- |
| `public/recording.mp4` | Your recording as exported by Tasjeel: cuts, zooms, wallpaper and camera already applied |
| `src/recording.json` | Title, captions, chapters and notes, timed to that video |
| `src/settings.ts` | The quick switches |
| `src/Video.tsx` | The video: the recording with the graphics layered on top |
| `src/components/` | Captions, chapter card, title card, progress bar |

Exporting the same recording to this folder again from Tasjeel replaces only `public/recording.mp4` and `src/recording.json`. Your changes to the code are kept.

## Licence

Remotion is free for individuals and small teams. Larger companies need a paid licence: see [remotion.dev/license](https://www.remotion.dev/license).
