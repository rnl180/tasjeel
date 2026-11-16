# Storyboards

A storyboard is a marketing video written down as a list of scenes. Tasjeel turns it into a video project that renders in three sizes: wide (16:9), square and tall (9:16). You write the words and name the pictures; Tasjeel does the layout and the motion.

A complete example is in [`Examples/studio`](../Examples/studio).

You do not have to write one by hand: in the [Studio](studio.md) an AI model writes and revises the storyboard from a chat. This page is the format it writes, for when you want to read or edit the file yourself.

## Make a video

1. Write a storyboard file (below) and put the pictures and clips it mentions in the same folder.
2. In Tasjeel choose **File › New Video from Storyboard File…**, pick the file, and choose where the project should go.
3. In the project folder, double-click **Start** to preview and **Render** to make the videos. This part needs [Node.js](https://nodejs.org).

To change the video, edit the storyboard and build it into the same folder again.

If something in the storyboard is wrong, Tasjeel lists every problem at once, for example `Scene 2 (screen): the file "demo.mp4" was not found.`

## The file

```json
{
  "title": "Launch video",
  "brand": { "logo": "logo.svg", "accent": "#8F7CFF" },
  "scenes": [
    { "type": "hook", "text": "Export in 4K. In one click." },
    { "type": "screen", "video": "demo.mp4", "caption": "Pick a size, press Export." },
    { "type": "cta", "text": "Try it today", "link": "example.com" }
  ]
}
```

Only `scenes` is required. File names are relative to the storyboard's folder.

| Field | What it is | If left out |
| --- | --- | --- |
| `title` | The video's name | "Untitled video" |
| `language` | Language of the words, such as `"en"` or `"ar"`. Arabic and Hebrew are laid out right to left | `"en"` |
| `formats` | Which sizes to render: any of `"wide"`, `"square"`, `"tall"` | All three |
| `fps` | Frames per second: 24, 25, 30, 50 or 60 | 30 |
| `brand` | Colours, logo and font used in every scene | Dark background, white text, purple accent |
| `scenes` | The scenes, in order. Up to 40 | Required |

### Brand

| Field | What it is |
| --- | --- |
| `name` | Shown on the last scene when there is no logo |
| `logo` | A picture (`.svg`, `.png`, `.jpg`, `.webp`). Sits in the corner of every scene and large on the last one |
| `background`, `text`, `accent` | Colours, written like `#0C0D11` |
| `font` | A font installed on your Mac, by name. Left out, the system font is used |

## Scenes

Every scene has a `type` and may have `seconds` (1 to 30). Text that is too long to fit on screen is reported.

Every scene may also have `say`: what a narrator reads aloud during it (up to 400 characters). It is spoken only when the video is made in the [Studio](studio.md) with a voice chosen; the scene is then lengthened to fit, and the words are shown as captions unless the storyboard has `"captions": false` at the top. Built any other way, `say` is ignored and the video is silent.

### `hook`: the opening line

One big sentence whose words rise in one by one. 3 seconds unless you say otherwise.

| Field | |
| --- | --- |
| `text` | Required. The line |
| `kicker` | A short line above it, such as "NEW" |

### `screen`: a piece of a recording

A clip shown as a floating window. Any `.mp4`, `.mov` or `.m4v` works, including Tasjeel's own recordings and exports; Tasjeel cuts out the part the scene uses. 6 seconds.

| Field | |
| --- | --- |
| `video` | Required. The clip |
| `start` | Where in the clip to begin, in seconds. 0 if left out |
| `caption` | A line under the window |
| `sound` | `true` to keep the clip's sound. Silent if left out |

The clip must be at least `start` + `seconds` long.

### `feature`: one thing the product does

A headline and up to four points, with an optional picture. 5 seconds.

| Field | |
| --- | --- |
| `headline` | Required |
| `points` | Up to four short lines |
| `image` | A picture, usually a screenshot |

### `quote`: something a customer said

4.5 seconds.

| Field | |
| --- | --- |
| `quote` | Required. Use words a real customer said |
| `name`, `role` | Who said it |

### `numbers`: figures that count up

One to three figures. 4.5 seconds.

| Field | |
| --- | --- |
| `items` | Required. Each has a `value` (a number) and may have `prefix` (`"$"`), `suffix` (`"K"`, `" fps"`, `"%"`) and `label` |
| `headline` | A line above the figures |

### `cta`: what to do next

The last scene: your logo, a line and a link. 3.5 seconds.

| Field | |
| --- | --- |
| `text` | Required |
| `link` | A web address, shown in a button |

## Changing how scenes look

The project is ordinary [Remotion](https://www.remotion.dev) code, one file per kind of scene. Open the project folder in Claude Code or another AI coding agent and describe what you want; the project includes a guide for agents and installs Remotion's own agent skills. Changes to the code are kept when you build from the storyboard again.
