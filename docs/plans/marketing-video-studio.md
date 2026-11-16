# Plan: Marketing Video Studio

Status: phases 1 and 2, project memory and voiceover are built (see [Storyboards](../storyboard.md) and [Studio](../studio.md)). Phases 3 to 5 are proposals. Written 16 November 2026.

## What this is

A second way to make a video in Tasjeel. Today you record something and edit it. With the Studio you **describe** a video in a chat, hand over whatever material you have (recordings, screenshots, a logo, a script, a product page), and Tasjeel produces a finished marketing video: scenes, voiceover, music, captions, and versions sized for each social network. You then refine it by talking to it ("shorter intro", "make the second scene about pricing") and publish it.

It is built on three things Tasjeel already has: the Remotion export (videos made from code, which an AI can write), the AI engine layer (Claude with your own key), and the Keychain storage for keys.

## What the user does

1. Opens **Studio** and starts a project.
2. Drops in material and types what the video is for: "A 30-second launch video for our new export screen, for LinkedIn and Instagram. Confident, not salesy."
3. Reads the **storyboard** Tasjeel proposes: a list of scenes, each with what is shown, what is said, and how long it lasts. Edits it in the chat or directly.
4. Presses **Create**. Tasjeel generates the voiceover, builds the video and plays it.
5. Asks for changes in the chat until it is right.
6. Presses **Render**, then optionally **Schedule posts**.

## How it works

| Step | What happens | Runs where |
| --- | --- | --- |
| Brief | Claude reads the chat and a description of each uploaded file, and asks at most a few questions if something essential is missing | Claude API |
| Storyboard | Claude returns the video as structured data: scenes, on-screen text, narration, timing, which material each scene uses | Claude API |
| Voiceover | Each scene's narration becomes speech, with timings so captions follow the words | ElevenLabs (optional), or the Mac's built-in voices for free |
| Music and sound | A music bed and a few sound effects, generated or chosen from a folder the user provides | ElevenLabs (optional) or local files |
| Build | The storyboard is written into a Remotion project made of ready-made scene templates. No code is generated for an ordinary video | On the Mac |
| Refine | A chat request changes the storyboard, and only the affected scenes are rebuilt. Requests the templates cannot express are handed to an AI coding agent that edits the Remotion code | Claude API, on the Mac |
| Render | Remotion renders each size (16:9, 1:1, 9:16) | On the Mac |
| Publish | The rendered files and a caption per network are scheduled through the user's Postiz account | Postiz (optional) |

The storyboard is the centre of the design. It is a plain file in the project folder, so it can be read, edited by hand, versioned, and rebuilt without calling any service again.

## Scene templates

The first version ships a small set, each a Remotion component driven by the storyboard:

- **Hook**: one large line of text over a colour or a clip.
- **Screen clip**: a piece of a Tasjeel recording with its zooms, framed like the editor's Studio look.
- **Feature**: a screenshot or clip beside a headline and two or three points.
- **Quote**: a customer quote with a name.
- **Numbers**: one to three statistics that count up.
- **Call to action**: logo, a line of text and a link.

A **brand kit** (logo, two colours, a font, a tone-of-voice note) is set once and applied to every scene.

## Connections and keys

A **Connections** page in settings, one row per service, each with a field for the key, a test button and a link to where the key is created.

| Service | Used for | Needed? |
| --- | --- | --- |
| Anthropic (Claude) | Brief, storyboard, refinement, post captions | Yes |
| ElevenLabs | Voiceover, music, sound effects | No. Without it: the Mac's voices, and music from your own files |
| Postiz | Scheduling the finished video to social networks | No. Without it: export the files and post them yourself |
| An image or video generation service | Filling a scene that has no material | No. Left for a later phase |

Rules that apply to every key, the same as for the Claude key today:

- Stored only in the macOS Keychain. Never in the repository, a project file, a log or an export.
- Sent only to the service it belongs to.
- Each service is off until its key is added, and every screen says plainly what leaves the Mac when it is on.
- Before anything that costs money or publishes, Tasjeel shows what it is about to do (how many characters of speech, which accounts, what time) and waits for a yes.

Checked against the services' documentation on the day this was written:

- ElevenLabs authenticates with an `xi-api-key` header, and its speech endpoint takes `text`, `model_id`, `voice_settings` and `language_code`.
- Postiz is open source and can be self-hosted. Its public API is at `https://api.postiz.com/public/v1` with endpoints for listing connected channels, uploading media and creating posts, an `Authorization` header, and a limit on how many posts can be created per hour.

Both will be checked again when the work starts, since the details change.

## Phases

Each phase ends with something usable.

**1. Storyboard to video. Done.** The storyboard format, the six scene templates, the brand kit, and a builder that turns a hand-written storyboard into a Remotion project. No AI and no keys. The example in `Examples/studio` renders in all three sizes, and an Arabic storyboard renders right to left.

**2. Chat to storyboard. Done.** The Studio window: material in, chat on one side, scenes and the rendered video on the other. Claude (which sees the pictures) or a local model in Ollama writes and revises the storyboard; each one is checked and a faulty one goes back to the model with its problems. The video renders inside the app. Differences from the proposal: the model answers in words plus a whole storyboard rather than through a fixed form, a change re-renders the whole video rather than only the scenes it touched, and Remotion is downloaded once and shared between projects (decision 1 below: Node.js is still the user's to install).

**2b. Project memory. Done.** Not in the first plan; added on request. Videos belong to projects. A project keeps a memory (what it is, audience, voice, features, true facts, brand, and for an app where it runs) that every video starts from and that the chat adds to, shared assets, and a `PROJECT.md` brief for AI agents with commands to take screenshots of the running app, add to the memory and make videos. A new project's memory can be drafted from its website. See [Studio](../studio.md).

**3a. Voiceover. Done.** ElevenLabs with the user's own key: a voice chosen per project, narration written by the model, each line spoken with word timings and shown as captions that follow the voice, a question before anything is charged, and every line kept so it is never paid for twice. Checked in English and Arabic with a stand-in for ElevenLabs; not yet run against the real service. Keys are entered in AI Settings rather than on a separate Connections page.

**3b. Music and a free voice. Not built.** What is left of the proposal below.

**3. Voice and sound (as first proposed).** The Connections page, ElevenLabs voiceover with word-timed captions, the free built-in voice fallback, music from a folder or generated. Done when a video has narration in sync with its captions in English and Arabic.

**4. Publish.** Postiz: pick channels, write a caption per network, schedule, see what was scheduled. Done when a rendered video is scheduled to a real account from inside Tasjeel.

**5. Open-ended edits.** Hand unusual requests to an AI coding agent working in the Remotion project, with a check that the project still type-checks and renders before the result is shown.

## Decisions needed before starting

1. **Where rendering runs.** Remotion needs Node.js. Either Tasjeel asks the user to install it (as the Remotion export does now), or Tasjeel carries its own copy, which makes the app much larger but removes a setup step.
2. **Remotion's licence.** Free for individuals and small teams, paid for larger companies. If Tasjeel is meant for companies, this needs to be stated up front or the renderer replaced.
3. **How much the first version tries to do.** Phases 1 and 2 alone give a silent video with on-screen text. Is that worth releasing, or should it wait for phase 3?
4. **Voices.** Stock voices only, or also cloning the user's own voice. Cloning needs clear consent and is easy to misuse, so the proposal is stock voices first.
5. **Publishing.** Postiz's hosted service, a self-hosted Postiz, or both.

## Risks

- **Quality.** A video made from templates can look like one. The brand kit and good defaults matter more than the number of templates.
- **Cost surprises.** Speech and generation are billed per use by the services. The confirmation step and a running estimate are part of the design, not an extra.
- **Other people's material.** Uploaded logos, footage and quotes may not be the user's to publish. Tasjeel cannot check; the publish step should say so.
- **Arabic.** Right-to-left text and Arabic voices have to be tested in every template from phase 1, not added afterwards.
- **Services change.** Each connection is a small, separately tested piece of code, so one service changing its API does not break the rest.

## What it deliberately leaves out

- Generating footage of people or events that did not happen.
- Posting without the user seeing and approving the exact post first.
- Storing keys or user material anywhere but the user's Mac.
