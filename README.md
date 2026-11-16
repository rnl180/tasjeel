# Tasjeel

A screen recorder and video editor for the Mac that keeps everything on your machine. Record a meeting or a walkthrough with your screen, voice, the computer's sound and your webcam, then trim it, frame it and export an MP4. No account, no upload, no subscription.

*Tasjeel* (تسجيل) is Arabic for "recording".

![The editor: preview, zoom controls and timeline](docs/editor.png)

![The library and recorder settings](docs/library.png)

<sub>Screenshots show generated sample footage.</sub>

## What it does

**Record**

- An entire display or a single window, at the display's full Retina resolution, 30 or 60 fps
- Encoded to a fixed picture quality rather than a fixed data rate, so text is sharp on the very first frame after the screen changes, and a still screen costs almost no disk space
- Your microphone and the computer's sound (the other side of a call) on **separate audio tracks**
- Your webcam, saved as its own file so you can move, resize or hide yourself afterwards
- Pause and resume; the paused stretch never reaches the file
- Start and stop from any app with **⌥⇧R**, from the menu bar, or from the floating control pill
- The floating controls and camera bubble are left out of display recordings
- Written to disk in fragments every few seconds, so a crash costs seconds, not the meeting

**Edit**

- Split, delete and trim on a timeline; every cut can be restored, and undo goes back 200 steps
- *Studio* look: wallpaper, padding, rounded corners and a drop shadow, or keep it *Plain*
- Canvas shapes for any destination: source, 16:9, 4:3, 1:1, 9:16
- Camera overlay as a circle, square or wide tile in any corner, mirrored or not
- **Auto zoom**: mouse clicks are logged while recording, and one button turns them into smooth zooms that pan from click to click. Add, move, resize and aim zooms by hand too
- Separate volume for your voice and the computer's sound
- Import any existing video file and edit it the same way

**Transcribe** (macOS 26 or later)

- One button turns the talking into a transcript, using the speech models built into macOS. The audio never leaves your Mac
- Lines are marked **You** or **Others**, because your microphone and the computer's sound were recorded separately
- Search the transcript and click any line to jump to that moment
- Show the transcript as captions on the video, in the preview and in the export
- Save it as a text file or as `.srt` subtitles; both follow your cuts
- Over 50 languages, Arabic among them. macOS downloads a language's model the first time you use it

**Export**

- MP4 in H.264 or HEVC, at the recording's own resolution by default (up to 4K) or scaled down to 1440p, 1080p or 720p, at 30 or 60 fps
- What you see in the preview is exactly what is exported: both go through the same renderer, and the preview is drawn at the exact pixel size it is shown at
- Colours come out as they were on screen

## Requirements

- macOS 15 (Sequoia) or later; transcripts need macOS 26. Built and tested on Apple silicon with macOS 26
- Xcode 26 or later to build

## Install

```bash
git clone https://github.com/rnl180/tasjeel.git
cd tasjeel
scripts/build-app.sh --install
```

That builds `dist/Tasjeel.app` and copies it to `/Applications`. Leave out `--install` to only build.

The script signs the app with your Apple Development certificate if you have one, which lets macOS remember the app's permissions across rebuilds. Without one the app is ad-hoc signed and still works; macOS just asks for permissions again after each rebuild.

## First run

macOS asks for three permissions, each the first time it is needed:

| Permission | Why | Where |
| --- | --- | --- |
| Screen & System Audio Recording | Capturing the screen and the computer's sound | System Settings › Privacy & Security. macOS asks you to reopen the app afterwards |
| Microphone | Your voice | Prompt on first recording |
| Camera | Your webcam, only if you pick one | Prompt on first recording |

## Using it

1. Choose **Entire display** or **One window**, and which camera, microphone and computer sound to include.
2. Press **Start Recording** (or ⌥⇧R). After a 3 second countdown the window gets out of the way and a small control pill appears.
3. Press **Stop** (or ⌥⇧R again). The recording opens in the editor.
4. Cut what you do not need, pick a look, and press **Export**.

### Editor shortcuts

| Key | Action |
| --- | --- |
| Space | Play / pause |
| S | Split at the playhead |
| Delete | Remove the selected part or zoom |
| [ and ] | Trim everything before / after the playhead |
| Z | Add a zoom at the playhead |
| ← → | Step one frame |
| ⌘Z, ⇧⌘Z | Undo, redo |

## Where your recordings live

Everything is in `~/Movies/Tasjeel`, one folder per recording:

```
~/Movies/Tasjeel/2026-11-16 09.30.12/
    project.json   title, cuts, look, zooms, click log
    screen.mov     screen (HEVC) + computer sound + microphone
    camera.mov     webcam (when one was recorded)
    thumb.jpg
    transcript.json   the transcript, once you create one
```

The `.mov` files are ordinary QuickTime movies you can open in any player. Editing never changes them; the edit is only a description in `project.json`. Deleting a recording in the app moves its folder to the Trash.

## How it is built

A Swift package with two targets and no third-party dependencies:

- **TasjeelCore**: the engine. ScreenCaptureKit for screen, system audio and microphone; AVFoundation for the camera, writing and export; Core Image on Metal for compositing.
- **Tasjeel**: the SwiftUI app.

| File | Role |
| --- | --- |
| `ScreenRecorder.swift` | Configures the ScreenCaptureKit stream and passes samples on |
| `CaptureWriter.swift` | Turns samples into a movie file: timestamps, pausing, one audio track per source |
| `CameraController.swift` | Runs the webcam for the live bubble and its own movie file |
| `RecordingClock.swift` | One clock for both files, so pauses and camera sync line up |
| `RecordingSession.swift` | One recording from start to finish, including the click log |
| `FrameRenderer.swift` | Draws a finished frame: wallpaper, zoomed screen, camera overlay. Resizes with a Lanczos filter so text stays crisp |
| `StudioCompositor.swift` | Plugs the renderer into AVFoundation for playback and export, in the colour space the recording uses |
| `CompositionBuilder.swift` | Turns the cut list into a playable composition |
| `Timing.swift` | Maps between recording time and edited time; zoom easing; auto zoom |
| `Transcriber.swift` | Runs each audio track through macOS's on-device speech models |
| `Transcript.swift` | Transcript lines: splitting into readable lines, echo removal, text and SRT export |
| `CaptionRenderer.swift` | Draws a caption line, including right-to-left text |

### Development

```bash
swift build          # debug build
swift test           # engine tests
```

The tests generate their own footage and run the real pipeline: they write movies through `CaptureWriter` (including a pause), render frames and read pixels back, and export an edited video and inspect the result.

A few aids for working on the app, none of which are needed for normal use:

- `TASJEEL_LIBRARY=/some/folder` makes the app use that folder instead of `~/Movies/Tasjeel`.
- `Tasjeel --selftest-record 3` records the main display for three seconds with no UI and prints what was written.
- `Tasjeel --transcribe <recording folder> --language en-US` transcribes a recording and prints the lines.
- `Tasjeel --render <recording folder> --out out.mp4` exports a recording with its saved edit. Add `--frame 6` and a `.png` name to write one finished frame instead, which is the quickest way to check sharpness and colour.
- `TASJEEL_SNAPSHOT=/some/folder` makes the app save pictures of its own windows there and quit (see `DebugSnapshot.swift`).

### About transcripts

- Two speech engines ship with macOS 26. Tasjeel uses the newer long-form one where it knows the language (30 locales: English, Spanish, French, German, Italian, Portuguese, Japanese, Korean, Chinese) and the dictation engine for the rest (Arabic, Turkish, Hindi, Russian and others). The dictation engine does not add punctuation in every language.
- Without headphones, your microphone also hears the call coming out of the speakers. Tasjeel drops microphone lines that repeat what the other side said at the same moment, but headphones give the cleanest You / Others split.
- Accuracy depends on Apple's models and on the audio. The transcript is not editable yet.

## Not there yet

- Editing the transcript, and cutting the video by deleting text
- Recording a connected iPhone or iPad
- GIF export
- Cursor smoothing and click highlights
- Recording only a selected region of the screen

## License

MIT. See [LICENSE](LICENSE).
