# Studio

The Studio makes a short marketing video from a conversation. You say what the video is for, hand over whatever you have (screenshots, a logo, recordings), and an AI model writes it as a [storyboard](storyboard.md). Tasjeel checks the storyboard, shows you its scenes, and renders the video in wide, square and tall. You change it by asking.

Open it with **File › New Video with AI…** (⇧⌘N) or the **Studio** button in the library.

## Projects and their memory

Videos are kept in **projects**: one for each product, app or business you make videos about. A project has two things every one of its videos shares:

- **Its memory**: what the project is, who it is for, how it talks, what it does, which facts and customer quotes are true, its links, logo and colours, and, for an app, where it runs and how to get around it. Press **Project Memory** to read or change it. You fill it in once; after that no video starts by explaining the product again.
- **Its files**: the logo, screenshots and recordings you add are kept with the project, not with one video.

**Start from the website.** At the top of the Project Memory sheet, type the project's web address and press **Fill from Website**. Tasjeel reads that page and up to three it links to (what it does, what it costs, who is behind it), and the AI model drafts whatever is still empty: the name, what it is, who it is for, how it talks, what it does, and figures and customer quotes that appear on the pages. The site's theme colour becomes the accent colour and its home-screen icon is added to the project as the logo. What you already wrote is never replaced, and nothing is saved until you press **Save**, so read the draft first: it is the site's wording, and the "true facts" are the site's own claims.

This needs Claude or Ollama, like the chat. With Claude, the words of those pages are sent to Anthropic. Sites that draw their text only inside the browser give Tasjeel nothing to read, and it says so. Only `https` sites are read.

The memory also grows by itself. When you tell the chat something that will still be true for the next video ("our customers are clinic owners", "never say AI"), the model asks Tasjeel to remember it. The chat shows exactly what was added, and you can delete any of it under **Project Memory › Learned along the way**. What you say in a chat wins over the memory where they differ.

Switch projects and videos with the two menus at the top left. **New Project…** starts one; its folder takes the project's name once you give it one.

### PROJECT.md: the brief for AI agents

Every project folder has a `PROJECT.md`, rewritten whenever the memory or the files change. It holds the memory in plain Markdown, a list of the project's files and videos, and the commands an AI agent can run to work on the project. **Project Memory › Copy Brief for an AI Agent** puts it on the clipboard to paste into Claude, ChatGPT or any other assistant; an agent that works in a terminal (Claude Code, Codex, Cursor) can be pointed at the file itself.

The brief leaves your home folder's name out of its paths, since it is made to be handed on. Read it before you send it somewhere: it contains whatever you wrote in the memory.

### Screenshots of an app

For an app project, the screens of the app are the material. Two ways to get them in:

- **You:** under the chat, **Add › A Screenshot of a Window** lists the windows open on your Mac. Pick one and its picture goes into the project at full resolution, without the window's shadow or the pointer. A phone app is the simulator's window; a web app is your browser's.
- **An AI agent:** the commands in `PROJECT.md` let an agent list the open windows and take the same screenshot itself, give it a name, and add what it learns to the memory:

```bash
Tasjeel --project "~/Movies/Tasjeel Studio/Orbit" --windows
Tasjeel --project "~/Movies/Tasjeel Studio/Orbit" --screenshot "Simulator" --name "booking-screen"
Tasjeel --project "~/Movies/Tasjeel Studio/Orbit" --remember "Booking takes three taps"
Tasjeel --studio "~/Movies/Tasjeel Studio/Orbit/videos/Launch" --say "A 20-second video of the booking flow" --render wide
```

(`Tasjeel` here is `/Applications/Tasjeel.app/Contents/MacOS/Tasjeel`; the brief writes it out in full.)

Tasjeel takes the picture but does not click or type. Getting the app to the right screen is up to you or to the agent's own tools (a browser tool for a web app, a simulator tool for a phone app). Screenshots need Screen Recording permission: for Tasjeel when you use the menu, and for the terminal app when an agent runs the command.

## Make a video

1. **Add material.** Press **Add** under the chat, or drop files on the window: pictures (`.png`, `.jpg`, `.webp`, `.svg`) and videos (`.mp4`, `.mov`, `.m4v`). **A Recording from the Library** adds one of your Tasjeel recordings together with what is said in it, if it has a transcript, so the model can choose the part worth showing. **A Screenshot of a Window** takes a picture of an app that is open. Everything you add belongs to the project and is there for its next video too.
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

**With Claude, this is sent to Anthropic on every message:** your chat, the storyboard, the project's memory, the list of materials (file names, sizes, lengths, and what is said in a library recording), and a small copy of each picture plus up to three frames of each video, at most twelve images in all. The files themselves, and the rendered video, stay on your Mac. Anthropic bills your key for each message.

The API key is kept in your Mac's Keychain and nowhere else.

## What the model is told to do, and not do

- Use only the files you added. A scene that would need a picture you did not give is written without it, and the reply says what would improve the video.
- Never invent a customer's words, a name or a figure. Quotes and numbers appear only when you supplied them, in the chat or under **True facts** in the project's memory.
- Remember only what is lasting. A request about one video ("shorter intro") is not saved.
- Keep to the storyboard format. Tasjeel checks every storyboard before using it. A faulty one is sent back to the model with the list of problems, twice at most; if it is still faulty, your video is left as it was and the chat shows what was wrong.

It can still write something you would not say. Read the scenes before you publish.

## Rendering

**Create Video** needs [Node.js](https://nodejs.org). The first time, Tasjeel asks before downloading [Remotion](https://www.remotion.dev), the tool that draws the video: about 1 GB, once, shared by all your Studio projects. Remotion is free for individuals and small companies; larger companies need a licence from Remotion.

## Where it is kept

```
~/Movies/Tasjeel Studio/
    Orbit/                    a project
        PROJECT.md            the brief for AI agents, rewritten by Tasjeel
        project.json          the memory, as Tasjeel keeps it
        assets/               logo, screenshots, recordings: shared by its videos
        assets.json           what each of those files is
        videos/
            Launch/
                storyboard.json   the video; you can edit it by hand
                chat.json         the conversation
                video/            the Remotion project built from the storyboard
                    out/          wide.mp4, square.mp4, tall.mp4
    .remotion-4.x/            the shared copy of Remotion (hidden)
```

A storyboard names files from the project's folder, such as `assets/logo.svg`. `video` is the same kind of project **File › New Video from Storyboard File…** makes. To change how scenes look, not just what they say, choose **⋯ › Open in Remotion Studio**, or open that folder in an AI coding agent. If you move a project out of the Studio folder, its **Start** script installs Remotion inside it the next time it runs.

Videos made with the first version of the Studio, which had no projects, each become a project of their own the next time the Studio opens.

## Not yet

- Voiceover, music and publishing: the next phases of the [plan](plans/marketing-video-studio.md). Today's videos are silent unless a recording's own sound is kept.
- Reading a site that needs a browser to show its words, or one behind a sign-in.
- Fonts and writing samples in the memory.
- Moving around an app by itself. Tasjeel photographs the window it is shown; it does not click through your app.
