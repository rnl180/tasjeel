import AppKit
import AVKit
import SwiftUI
import TasjeelCore
import UniformTypeIdentifiers

/// The Studio: describe a video in the chat on the left, watch it take shape
/// on the right.
struct StudioView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var ai = AIConfig.shared
    @State private var showingAISettings = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 0) {
                StudioChatPane(model: model, showAISettings: { showingAISettings = true })
                    .frame(width: 400)
                    .background(Theme.panel)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                StudioPreviewPane(model: model)
            }
        }
        .background(Theme.window)
        .ignoresSafeArea()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(Text("Drop pictures and videos to add them").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                model.addMaterials(urls)
            }
            return true
        }
        .sheet(isPresented: $showingAISettings) { AISettingsView(ai: ai) }
        .alert("Download Remotion?", isPresented: $model.askDownload) {
            Button("Download and Create Video") { model.startRender() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tasjeel makes the video with Remotion, a free video tool, and needs to download it once: about 1 GB, into your Tasjeel Studio folder. Remotion is free for individuals and small companies; larger companies need a licence from remotion.dev.")
        }
        .task { await ai.refresh() }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(model.projects) { project in
                    Button {
                        model.open(project.workspace)
                    } label: {
                        if project.workspace == model.workspace { Label(project.title, systemImage: "checkmark") } else { Text(project.title) }
                    }
                }
                Divider()
                Button("New Video") { model.newProject() }
                Button("Show Project in Finder") { model.revealProject() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles.rectangle.stack").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
                    Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()

            Spacer()

            Button { showingAISettings = true } label: {
                Label("AI Settings", systemImage: "gearshape")
            }
            .buttonStyle(QuietButtonStyle())
        }
        .padding(.leading, 84)
        .padding(.trailing, 14)
        .frame(height: 48)
        .background(Theme.panel)
    }
}

// MARK: - Chat

struct StudioChatPane: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var ai = AIConfig.shared
    @ObservedObject private var app = AppState.shared
    let showAISettings: () -> Void
    @FocusState private var composing: Bool

    private static let starters = [
        "A 30-second launch video for our new feature, for LinkedIn. Confident, not salesy.",
        "A short product tour from the recording I added, with a clear call to action.",
        "فيديو تعريفي قصير بالعربية عن المنتج، مدته ٢٠ ثانية.",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if model.messages.isEmpty, model.writing == nil { welcome }
                        ForEach(model.messages) { message in
                            StudioMessageRow(message: message, canRestore: model.canRestore(message)) { model.restore(message) }
                        }
                        if let writing = model.writing { writingRow(writing) }
                        if let error = model.chatError { errorRow(error) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.count) { _, _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: model.writing) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
            Rectangle().fill(Theme.stroke).frame(height: 1)
            materialsStrip
            composer
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What video do you want to make?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Add screenshots, your logo or a recording below, then say what the video is for and who will watch it. You get a first version to react to, and you change it by asking.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.starters, id: \.self) { starter in
                    Button {
                        model.draft = starter
                        composing = true
                    } label: {
                        Text(starter)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .reading(starter)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .cardSurface(radius: 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
        .padding(.top, 6)
    }

    private func writingRow(_ writing: StudioModel.Writing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !writing.text.isEmpty {
                Text(StudioMessageRow.styled(writing.text))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .reading(writing.text)
            }
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(writing.text.isEmpty ? "\(writing.engine) is thinking…" : "Writing the storyboard…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                Spacer()
                Button("Stop") { model.stopWriting() }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if model.messages.last?.role == .user, model.writing == nil {
                    Button("Try Again") { model.retry() }.buttonStyle(QuietButtonStyle())
                }
                Button("AI Settings…", action: showAISettings).buttonStyle(QuietButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Materials

    private var materialsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Menu {
                        Button("Pictures and Videos…") { model.chooseMaterials() }
                        if !app.items.isEmpty {
                            Menu("A Recording from the Library") {
                                ForEach(app.items.prefix(20)) { entry in
                                    Button(entry.recording.title) { model.addRecording(entry) }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if model.addingMaterials {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                            }
                            Text(model.materials.isEmpty ? "Add material" : "Add").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Add screenshots, a logo or recordings for the video to use. You can also drop files on the window.")

                    ForEach(model.materials) { material in
                        MaterialChip(material: material, url: model.workspace.directory.appendingPathComponent(material.file)) {
                            model.remove(material)
                        }
                    }
                    if model.materials.isEmpty {
                        Text("Screenshots, a logo, recordings")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            if let error = model.materialError {
                Text(error)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.top, 10)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(model.outline == nil ? "Describe the video…" : "Ask for a change…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1 ... 6)
                    .focused($composing)
                    .onSubmit { model.send() }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(composing ? Theme.accent.opacity(0.6) : Theme.stroke))
                Button { model.send() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                .opacity(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy ? 0.4 : 1)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
            engineLine
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var engineLine: some View {
        switch model.engine {
        case .claude:
            privacy("Claude Opus 5.5", "Your messages, the storyboard and small copies of the pictures you add (with a few frames of each video) are sent to Anthropic.", cloud: true)
        case .ollama(let name):
            privacy(name, "Runs on this Mac. Nothing is sent anywhere. It reads file names, not pictures.", cloud: false)
        case .apple:
            EmptyView()
        case .unavailable(let reason):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Theme.warn)
                Text(ai.checked ? reason : "Checking which AI models are set up…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Set Up…", action: showAISettings)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func privacy(_ name: String, _ detail: String, cloud: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: cloud ? "cloud" : "desktopcomputer").font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            (Text(name).fontWeight(.semibold) + Text(". \(detail)"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct StudioMessageRow: View {
    let message: StudioMessage
    let canRestore: Bool
    let restore: () -> Void

    /// Models write a little Markdown (**bold**); show it as such.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .reading(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if !message.text.isEmpty {
                    Text(Self.styled(message.text))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .reading(message.text)
                }
                if let problems = message.problems, !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The new storyboard had problems, so the video was left as it was. Ask again, or say what to change:")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.warn)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(problems.prefix(5), id: \.self) { problem in
                            Text("• \(problem)").font(.system(size: 11.5)).foregroundStyle(Theme.subtext).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                if message.storyboard != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "film.stack").font(.system(size: 10.5))
                        Text("Storyboard updated").font(.system(size: 11.5, weight: .medium))
                        if canRestore {
                            Button("Go Back to This Version", action: restore)
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.leading, 4)
                        }
                    }
                    .foregroundStyle(Theme.good)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MaterialChip: View {
    let material: StudioMaterial
    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            StudioThumbnail(url: url, time: material.kind == .video ? (material.seconds ?? 0) * 0.15 : nil)
                .frame(width: 44, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(material.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: 130, alignment: .leading)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Theme.subtext)
                    .frame(width: 16, height: 16)
                    .background(Theme.raised, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove \(material.name) from this video")
            .accessibilityLabel("Remove \(material.name)")
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .frame(height: 44)
        .cardSurface(radius: 8)
        .onHover { hovering = $0 }
    }

    private var detail: String {
        switch material.kind {
        case .picture: return "Picture"
        case .video: return "Video · \(Format.clock(material.seconds ?? 0))"
        }
    }
}

/// A small picture of a material: the picture itself, or a frame of a video.
struct StudioThumbnail: View {
    let url: URL?
    var time: Double?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")@\(time ?? -1)") {
            guard let url else {
                image = nil
                return
            }
            if let time {
                image = await StudioWorkspace.frame(of: url, at: time, longSide: 480)
            } else {
                image = StudioWorkspace.picture(url, longSide: 480)
            }
        }
    }
}

// MARK: - Storyboard and video

struct StudioPreviewPane: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        if let outline = model.outline {
            VStack(spacing: 0) {
                header(outline)
                stage(outline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                Rectangle().fill(Theme.stroke).frame(height: 1)
                scenes(outline)
            }
        } else if !model.storyboardProblems.isEmpty {
            brokenStoryboard
        } else {
            emptyState
        }
    }

    private func header(_ outline: Storyboard.Outline) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(outline.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("\(outline.scenes.count) scene\(outline.scenes.count == 1 ? "" : "s") · \(Format.clock(outline.seconds.rounded()))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
            }
            Spacer(minLength: 8)
            if outline.formats.count > 1 {
                Segmented(options: outline.formats.map { (value: $0, label: $0.capitalized) }, selection: $model.format)
                    .frame(width: CGFloat(outline.formats.count) * 68)
                    .disabled(model.render != nil)
            }
            if model.render != nil {
                Button("Cancel") { model.cancelRender() }.buttonStyle(QuietButtonStyle())
            } else {
                Button(model.videoURL == nil ? "Create Video" : "Update Video") { model.createVideo() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.videoURL != nil && !model.videoIsStale)
                    .help(model.videoURL != nil && !model.videoIsStale ? "The video is up to date" : "Make the \(model.format) video from the storyboard")
            }
            Menu {
                Button("Create Every Size") { model.createVideo(allSizes: true) }.disabled(model.render != nil)
                Divider()
                if model.videoURL != nil { Button("Show Video in Finder") { model.revealVideo() } }
                Button("Show Project in Finder") { model.revealProject() }
                Button("Open the Storyboard File") { model.openStoryboardFile() }
                if let starter = model.remotionStarter {
                    Button("Open in Remotion Studio") { NSWorkspace.shared.open(starter) }
                }
                Divider()
                Button("Clear the Chat") { model.clearChat() }.disabled(model.messages.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 30, height: 30)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: Stage

    private static let aspects: [String: CGFloat] = ["wide": 16.0 / 9.0, "square": 1, "tall": 9.0 / 16.0]

    @ViewBuilder private func stage(_ outline: Storyboard.Outline) -> some View {
        VStack(spacing: 10) {
            ZStack {
                if model.videoURL != nil {
                    StudioPlayer(player: model.player)
                } else {
                    poster(outline)
                }
                if let job = model.render { renderOverlay(job) }
            }
            .aspectRatio(Self.aspects[model.format] ?? 16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error = model.renderError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if error.contains("nodejs.org") {
                        Button("Get Node.js") { NSWorkspace.shared.open(URL(string: "https://nodejs.org")!) }.buttonStyle(QuietButtonStyle())
                    }
                    IconButton(symbol: "xmark", help: "Dismiss", size: 22) { model.renderError = nil }
                }
                .padding(10)
                .background(Theme.warn.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if model.videoIsStale, model.render == nil {
                Label("The storyboard changed after this video was made. Press Update Video to see the changes.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)
            }
        }
    }

    /// Shown before the first render: the opening scene's words in the
    /// brand's colours, as a taste of the video.
    private func poster(_ outline: Storyboard.Outline) -> some View {
        ZStack {
            Color(hexString: outline.background)
            VStack(spacing: 14) {
                Text(outline.scenes.first?.text ?? outline.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color(hexString: outline.text))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .minimumScaleFactor(0.5)
                Capsule().fill(Color(hexString: outline.accent)).frame(width: 46, height: 4)
                Text("Press Create Video to watch it")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hexString: outline.text).opacity(0.55))
            }
            .padding(28)
        }
    }

    private func renderOverlay(_ job: StudioModel.RenderJob) -> some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                if let fraction = job.fraction {
                    ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent).frame(width: 240)
                } else {
                    ProgressView().controlSize(.regular)
                }
                Text(job.label).font(.system(size: 12.5)).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            }
            .padding(20)
        }
    }

    // MARK: Scenes

    private func scenes(_ outline: Storyboard.Outline) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(outline.scenes) { scene in
                    SceneCard(scene: scene, outline: outline)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(height: 176)
        .background(Theme.panel)
    }

    // MARK: Other states

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card).frame(width: 88, height: 88)
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.faint)
            }
            Text("Your video appears here").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Describe it in the chat. You will see its scenes, then the video itself, in wide, square and tall.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var brokenStoryboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("The storyboard file needs fixing", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.warn)
            ForEach(model.storyboardProblems.prefix(8), id: \.self) { problem in
                Text("• \(problem)").font(.system(size: 12.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            }
            Text("Ask in the chat for a new storyboard, or fix the file yourself.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
            Button("Open the Storyboard File") { model.openStoryboardFile() }.buttonStyle(QuietButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The rendered video with the system's playback controls. AppKit's player
/// view is used directly; SwiftUI's own wrapper of it crashes in an app
/// built as a Swift package.
struct StudioPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct SceneCard: View {
    let scene: Storyboard.Outline.Scene
    let outline: Storyboard.Outline

    private static let symbols = ["hook": "text.quote", "screen": "macwindow", "feature": "checklist",
                                  "quote": "quote.bubble", "numbers": "number", "cta": "hand.tap"]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color(hexString: outline.background)
                if scene.media != nil {
                    StudioThumbnail(url: scene.media, time: scene.start.map { $0 + 0.5 } ?? (scene.type == "screen" ? 0.5 : nil))
                        .padding(scene.type == "screen" ? 7 : 0)
                } else {
                    Image(systemName: Self.symbols[scene.type] ?? "rectangle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Color(hexString: outline.accent))
                }
            }
            .frame(width: 168, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Text(seconds)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(5)
            }

            Text("\(scene.id + 1) · \(scene.label)".uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.faint)
            Text(scene.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: 168, alignment: .leading)
                .environment(\.layoutDirection, outline.rightToLeft ? .rightToLeft : .leftToRight)
        }
        .help(scene.detail.map { "\(scene.text)\n\($0)" } ?? scene.text)
    }

    private var seconds: String {
        scene.seconds == scene.seconds.rounded() ? "\(Int(scene.seconds))s" : String(format: "%.1fs", scene.seconds)
    }
}
