import AppKit
import SwiftUI
import TasjeelCore
import UniformTypeIdentifiers

/// The Notes tab: an AI model reads the transcript and writes a title, a
/// summary, key points, decisions, action items and chapters.
struct NotesTab: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var ai = AIConfig.shared
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let job = model.notesJob {
                working(job)
            } else if let notes = model.notes {
                NotesContent(model: model, notes: notes, openSettings: { showingSettings = true })
            } else if let transcript = model.transcript {
                setup(transcript)
            } else {
                needsTranscript
            }
        }
        .padding(.top, 4)
        .task { await ai.refresh() }
        .sheet(isPresented: $showingSettings) { AISettingsView(ai: ai) }
    }

    private var needsTranscript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 22)).foregroundStyle(Theme.faint)
            Text("Notes start from the transcript").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Create a transcript first. Then an AI model can turn it into a summary, action items and chapters.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Go to Transcript") { model.tab = .transcript }.buttonStyle(QuietButtonStyle())
        }
    }

    private func setup(_ transcript: Transcript) -> some View {
        let choice = ai.choice(for: transcript.language)
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Theme.accent)
            Text("Summary, action items and chapters").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("An AI model reads the transcript and writes what the recording was about, what was decided, who does what next, and chapters you can click on the timeline.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            EngineSummary(choice: choice, checked: ai.checked)

            Button {
                if let engine = try? ai.model(for: transcript.language) { model.createNotes(with: engine) }
            } label: {
                Label("Create notes", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!choice.isUsable || transcript.segments.isEmpty)

            Button("AI settings…") { showingSettings = true }.buttonStyle(QuietButtonStyle())

            if transcript.segments.isEmpty {
                Text("The transcript is empty, so there is nothing to write notes from.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.notesError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func working(_ job: EditorModel.NotesJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Writing notes").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text(job.status)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
            Text("With \(job.engine)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { model.cancelNotes() }.buttonStyle(QuietButtonStyle())
        }
    }
}

extension AIChoice {
    var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

/// One card saying which model will write the notes and where the text goes.
private struct EngineSummary: View {
    let choice: AIChoice
    let checked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.subtext)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: 9)
    }

    private var symbol: String {
        switch choice {
        case .apple, .ollama: return "lock.laptopcomputer"
        case .claude: return "cloud"
        case .unavailable: return checked ? "exclamationmark.circle" : "hourglass"
        }
    }

    private var tint: Color {
        switch choice {
        case .apple, .ollama: return Theme.good
        case .claude: return Theme.accent
        case .unavailable: return checked ? Theme.warn : Theme.faint
        }
    }

    private var title: String {
        switch choice {
        case .apple: return "Apple Intelligence"
        case .ollama(let model): return model
        case .claude: return "Claude Opus 5.5"
        case .unavailable: return checked ? "No AI model ready" : "Looking for AI models…"
        }
    }

    private var detail: String {
        switch choice {
        case .apple, .ollama: return "Runs on this Mac. Nothing is sent anywhere."
        case .claude: return "The transcript text is sent to Anthropic with your API key. Audio and video stay on your Mac."
        case .unavailable(let reason): return checked ? reason : "One moment."
        }
    }
}

// MARK: - The notes

private struct NotesContent: View {
    @ObservedObject var model: EditorModel
    let notes: MeetingNotes
    let openSettings: () -> Void

    private var rightToLeft: Bool {
        Locale.Language(identifier: notes.language).characterDirection == .rightToLeft
    }

    private var alignment: HorizontalAlignment { rightToLeft ? .trailing : .leading }
    private var textAlignment: TextAlignment { rightToLeft ? .trailing : .leading }
    private var frameAlignment: Alignment { rightToLeft ? .trailing : .leading }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                Text(notes.title.isEmpty ? model.recording.title : notes.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: frameAlignment)
                menu
            }
            if !notes.title.isEmpty, notes.title != model.recording.title {
                Button("Use as the recording's title") { model.useNotesTitle() }.buttonStyle(QuietButtonStyle())
            }

            if !notes.summary.isEmpty { paragraph(notes.summary) }
            list("Key points", notes.keyPoints, symbol: "circle.fill", symbolSize: 4.5)
            list("Decisions", notes.decisions, symbol: "checkmark.seal", symbolSize: 11)

            if !notes.actionItems.isEmpty {
                section("Action items") {
                    ForEach(notes.actionItems) { item in
                        row(symbol: "square", symbolSize: 11) {
                            VStack(alignment: alignment, spacing: 3) {
                                Text(item.text)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Theme.text)
                                    .multilineTextAlignment(textAlignment)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let owner = item.owner, !owner.isEmpty {
                                    Text(owner)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(owner == "You" ? Theme.accent : Theme.good)
                                }
                            }
                        }
                    }
                }
            }

            if !model.chapters.isEmpty {
                section("Chapters") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.chapters) { chapter in
                            ChapterRow(chapter: chapter, active: model.activeChapterID == chapter.id, rightToLeft: rightToLeft) {
                                model.seek(toSource: chapter.start + 0.02)
                            }
                        }
                    }
                }
            }

            if let error = model.notesError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Written by \(notes.engine). AI notes can be wrong: check anything that matters against the transcript.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var menu: some View {
        Menu {
            Button("Copy Notes") { copy(NotesFormat.markdown(notes, chapters: model.editedChapters)) }
            Button("Copy Chapters") { copy(NotesFormat.chapterList(model.editedChapters)) }
                .disabled(model.editedChapters.isEmpty)
            Button("Save as Markdown…") { save() }
            Divider()
            Button("Create Again…") { model.discardNotes() }
            Button("AI Settings…", action: openSettings)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.text)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Copy, save or recreate the notes")
        .accessibilityLabel("Notes actions")
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.text.opacity(0.9))
            .multilineTextAlignment(textAlignment)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: frameAlignment)
            .textSelection(.enabled)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title)
            content()
        }
    }

    @ViewBuilder
    private func list(_ title: String, _ lines: [String], symbol: String, symbolSize: CGFloat) -> some View {
        if !lines.isEmpty {
            section(title) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(symbol: symbol, symbolSize: symbolSize) {
                        Text(line)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                            .multilineTextAlignment(textAlignment)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// A bullet and its text; the bullet moves to the right for Arabic.
    private func row(symbol: String, symbolSize: CGFloat, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if rightToLeft {
                content().frame(maxWidth: .infinity, alignment: .trailing)
                bullet(symbol, size: symbolSize)
            } else {
                bullet(symbol, size: symbolSize)
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func bullet(_ symbol: String, size: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(Theme.subtext)
            .frame(width: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = model.recording.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".") + ".md"
        let content = NotesFormat.markdown(notes, chapters: model.editedChapters)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.notesError = "The file could not be saved: \(error.localizedDescription)"
            }
        }
    }
}

private struct ChapterRow: View {
    let chapter: NoteChapter
    let active: Bool
    let rightToLeft: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NotesFormat.stamp(chapter.start))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(active ? Theme.accent : Theme.faint)
                    .frame(width: 40, alignment: .leading)
                Text(chapter.title)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.card : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Jump to \(NotesFormat.stamp(chapter.start))")
    }
}

// MARK: - AI settings

/// Choose which model writes the notes, download a local one, or add a key
/// for Claude.
struct AISettingsView: View {
    @ObservedObject var ai: AIConfig
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""
    @State private var keyProblem: String?
    @State private var voiceKeyDraft = ""
    @State private var voiceKeyProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI settings").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Choose what writes your notes and, in the Studio, your storyboards. Of these, only Claude sends anything off this Mac. The voiceover at the bottom is a separate service.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                option(.automatic, title: "Automatic", badge: "On this Mac",
                       detail: "Uses Apple Intelligence when it knows the language, otherwise a model in Ollama. Never uses the cloud. The Studio needs Ollama or Claude.") { EmptyView() }

                option(.apple, title: "Apple Intelligence", badge: "On this Mac",
                       detail: ai.found.appleProblem ?? "Ready. Built into macOS, best for short recordings.",
                       warning: ai.checked && ai.found.appleProblem != nil) { EmptyView() }

                option(.ollama, title: "Ollama", badge: "On this Mac", detail: ollamaDetail,
                       warning: ai.checked && (!ai.found.ollamaRunning || ai.found.ollamaModels.isEmpty)) { ollamaControls }

                option(.claude, title: "Claude", badge: "Cloud, your API key",
                       detail: "The best results, in any language. For notes it sends the transcript text to Anthropic. In the Studio it sends your chat, the storyboard and small copies of the pictures you add, with a few frames of each video. Recordings themselves stay on your Mac. Anthropic bills your key for each use.") { claudeControls }
            }

            voiceCard

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .task { await ai.refresh() }
    }

    private var ollamaDetail: String {
        if !ai.checked { return "Checking…" }
        if !ai.found.ollamaRunning { return "Not running. Open the Ollama app, or get it free from ollama.com, then come back here." }
        if ai.found.ollamaModels.isEmpty { return "Running, with no models yet. Download one below; it works offline afterwards." }
        return "Runs a downloaded model on this Mac. Handles Arabic and long meetings."
    }

    @ViewBuilder private var ollamaControls: some View {
        if let download = ai.download {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: download.progress).progressViewStyle(.linear).tint(Theme.accent)
                HStack {
                    Text("\(download.model): \(download.status) \(Int(download.progress * 100))%")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.subtext)
                    Spacer()
                    Button("Stop") { ai.cancelDownload() }.buttonStyle(QuietButtonStyle())
                }
            }
        } else if ai.found.ollamaRunning {
            HStack(spacing: 8) {
                if !ai.found.ollamaModels.isEmpty {
                    Picker("Model", selection: $ai.ollamaModel) {
                        if !ai.found.ollamaModels.contains(ai.ollamaModel) { Text("Choose automatically").tag(ai.ollamaModel) }
                        ForEach(ai.found.ollamaModels, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                if !ai.found.ollamaModels.contains(AIEngines.suggestedOllamaModel) {
                    Button("Download \(AIEngines.suggestedOllamaModel) (\(AIEngines.suggestedOllamaSize))") {
                        ai.downloadModel(AIEngines.suggestedOllamaModel)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                Spacer(minLength: 0)
            }
        }
        if let error = ai.downloadError {
            Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var claudeControls: some View {
        if ai.found.hasClaudeKey {
            HStack(spacing: 8) {
                Label("Key saved in your Mac's Keychain", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.good)
                Spacer(minLength: 0)
                Button("Remove key") { ai.removeKey() }.buttonStyle(QuietButtonStyle())
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField("Paste your Anthropic API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
                        .onSubmit(saveKey)
                    Button("Save key", action: saveKey)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("The key is stored only in your Mac's Keychain. Create one at platform.claude.com.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let keyProblem {
                    Text(keyProblem).font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    /// ElevenLabs is not one of the writers above: it reads a Studio video's
    /// narration aloud, whichever of them wrote it.
    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Voiceover: ElevenLabs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Cloud, your API key")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.14), in: Capsule())
            }
            Text("Reads a Studio video's narration aloud. Only the words to be spoken are sent to ElevenLabs, which bills your key by the character. Tasjeel asks before each new voiceover and never pays twice for the same line.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
            if ai.hasVoiceKey {
                HStack(spacing: 8) {
                    Label("Key saved in your Mac's Keychain", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.good)
                    Spacer(minLength: 0)
                    Button("Remove key") { ai.removeVoiceKey() }.buttonStyle(QuietButtonStyle())
                }
                if let problem = ai.voicesError {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 8) {
                    SecureField("Paste your ElevenLabs API key", text: $voiceKeyDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Theme.window, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
                        .onSubmit(saveVoiceKey)
                    Button("Save key", action: saveVoiceKey)
                        .buttonStyle(QuietButtonStyle())
                        .disabled(voiceKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("The key is stored only in your Mac's Keychain. Create one at elevenlabs.io, under Developers › API Keys.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if let voiceKeyProblem {
                    Text(voiceKeyProblem).font(.system(size: 11.5)).foregroundStyle(Theme.warn)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func saveVoiceKey() {
        if ai.saveVoiceKey(voiceKeyDraft) {
            voiceKeyDraft = ""
            voiceKeyProblem = nil
        } else {
            voiceKeyProblem = "The key could not be saved to the Keychain."
        }
    }

    private func saveKey() {
        if ai.saveKey(keyDraft) {
            keyDraft = ""
            keyProblem = nil
            ai.engine = .claude
        } else {
            keyProblem = "The key could not be saved to the Keychain."
        }
    }

    /// One selectable engine: a radio mark, what it is, and its controls.
    private func option(_ kind: AIEngineKind, title: String, badge: String, detail: String, warning: Bool = false,
                        @ViewBuilder controls: () -> some View) -> some View {
        let selected = ai.engine == kind
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                ai.engine = kind
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(selected ? Theme.accent : Theme.faint)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(kind == .claude ? Theme.accent : Theme.good)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((kind == .claude ? Theme.accent : Theme.good).opacity(0.14), in: Capsule())
                        }
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(warning ? Theme.warn : Theme.subtext)
                            .lineSpacing(1.5)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(badge)")
            .accessibilityAddTraits(selected ? .isSelected : [])

            controls().padding(.leading, 24)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.stroke))
    }
}
