# Studio

The Studio makes a short marketing video from a conversation. You say what the video is for, hand over whatever you have (screenshots, a logo, recordings), and an AI model writes it as a [storyboard](storyboard.md). Tasjeel checks the storyboard, shows you its scenes, and renders the video in wide, square and tall. You change it by asking.

Open it with **File › New Video with AI…** (⇧⌘N) or the **Studio** button in the library.

## Make a video

1. **Add material.** Press **Add** under the chat, or drop files on the window: pictures (`.png`, `.jpg`, `.webp`, `.svg`) and videos (`.mp4`, `.mov`, `.m4v`). **A Recording from the Library** adds one of your Tasjeel recordings together with what is said in it, if it has a transcript, so the model can choose the part worth showing.
2. **Describe the video.** What it is for, who will watch it, how long, in which language. For example: *A 30-second launch video for our new export screen, for LinkedIn. Confident, not salesy.*
3. **Read the scenes** that appear on the right. Ask for changes in the chat: *shorter intro*, *make the second scene about pricing*, *in Arabic*.
4. Press **Create Video** to watch it. Pick **Wide**, **Square** or **Tall** first; **⋯ › Create Every Size** renders all of them and opens the folder.

After a change to the storyboard the video is marked out of date; **Update Video** renders it again. Every answer that changed the storyboard keeps its version, so **Go Back to This Version** under an earlier answer undoes what came after.

## What writes the storyboard

Chosen in **AI Settings**, the same setting the notes use:

| | Where it runs | Sees your pictures | What it needs |
| --- | --- | --- | --- |
| **Claude** | Anthropic's servers | Yes | Your own Anthropic API key |
| **Ollama** | Your Mac | No, file names and sizes only | The Ollama app and a downloaded model |

The model built into macOS is too small to write a whole video, so the Studio does not use it. "Automatic" uses Ollama and never the cloud.

**With Claude, this is sent to Anthropic on every message:** your chat, the storyboard, the list of materials (file names, sizes, lengths, and what is said in a library recording), and a small copy of each picture plus up to three frames of each video, at most twelve images in all. The files themselves, and the rendered video, stay on your Mac. Anthropic bills your key for each message.

The API key is kept in your Mac's Keychain and nowhere else.

## What the model is told to do, and not do

- Use only the files you added. A scene that would need a picture you did not give is written without it, and the reply says what would improve the video.
- Never invent a customer's words, a name or a figure. Quotes and numbers appear only when you supplied them.
- Keep to the storyboard format. Tasjeel checks every storyboard before using it. A faulty one is sent back to the model with the list of problems, twice at most; if it is still faulty, your video is left as it was and the chat shows what was wrong.

It can still write something you would not say. Read the scenes before you publish.

## Rendering

**Create Video** needs [Node.js](https://nodejs.org). The first time, Tasjeel asks before downloading [Remotion](https://www.remotion.dev), the tool that draws the video: about 1 GB, once, shared by all your Studio projects. Remotion is free for individuals and small companies; larger companies need a licence from Remotion.

## Where it is kept

```
~/Movies/Tasjeel Studio/
    Video/
        storyboard.json   the video; you can edit it by hand
        chat.json         the conversation and the list of materials
        materials/        copies of what you added
        video/            the Remotion project built from the storyboard
            out/          wide.mp4, square.mp4, tall.mp4
    .remotion-4.x/        the shared copy of Remotion (hidden)
```

`video` is the same kind of project **File › New Video from Storyboard File…** makes. To change how scenes look, not just what they say, choose **⋯ › Open in Remotion Studio**, or open that folder in an AI coding agent. If you move a project out of the Studio folder, its **Start** script installs Remotion inside it the next time it runs.

## Not yet

Voiceover, music and publishing are the next phases of the [plan](plans/marketing-video-studio.md). Today's videos are silent unless a recording's own sound is kept.
