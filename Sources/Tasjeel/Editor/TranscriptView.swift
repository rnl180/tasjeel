import AppKit
import SwiftUI
import TasjeelCore
import UniformTypeIdentifiers

/// The Transcript tab: create a transcript, read and search it, jump around
/// the video by clicking lines, and export it.
struct TranscriptTab: View {
    @ObservedObject var model: EditorModel
    @AppStorage("transcriptLanguage") private var language = ""
    @State private var search = ""

    var body: some View {
        if !Transcriber.isSupported {
            notice(symbol: "text.bubble", title: "Transcripts need macOS 26",
                   detail: "Tasjeel uses the speech models built into macOS 26 and later, so the audio never has to leave your Mac.")
        } else if let job = model.transcription {
            working(job)
        } else if let transcript = model.transcript {
            TranscriptContent(model: model, transcript: transcript, search: $search)
        } else if !model.hasMic, !model.hasSystemAudio {
            notice(symbol: "speaker.slash", title: "No sound to transcribe",
                   detail: "Turn on Microphone or Computer sound before recording.")
        } else {
            setup
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "text.bubble").font(.system(size: 24)).foregroundStyle(Theme.accent)
            Text("Turn the talking into text").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text("Read, search and jump through the recording by what was said, add captions to the video, and save the text. It runs on this Mac; nothing is uploaded.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Spoken language")
                Picker("Spoken language", selection: $language) {
                    if model.languages.isEmpty { Text("Loading…").tag(language) }
                    ForEach(model.languages) { option in
                        Text(option.installed ? option.name : "\(option.name) (downloads first)").tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                model.createTranscript(language: language)
            } label: {
                Label("Create transcript", systemImage: "waveform.badge.magnifyingglass").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(language.isEmpty || model.languages.isEmpty)

            if let selected = model.languages.first(where: { $0.id == language }), !selected.installed {
                Text("macOS downloads the speech model for \(selected.name) the first time. After that it works offline.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.hasMic, model.hasSystemAudio {
                Text("Your microphone and the computer's sound are transcribed separately, so lines are marked You or Others.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.transcriptError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
        .task {
            await model.loadLanguages()
            if !model.languages.contains(where: { $0.id == language }) {
                language = Transcriber.suggestedLanguage(from: model.languages) ?? ""
            }
        }
    }

    private func working(_ job: EditorModel.TranscriptionJob) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Creating transcript").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            ProgressView(value: job.progress)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
            Text(job.status)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            Button("Cancel") { model.cancelTranscription() }.buttonStyle(QuietButtonStyle())
        }
        .padding(.top, 4)
    }

    private func notice(symbol: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.faint)
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.subtext)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }
}

private struct TranscriptContent: View {
    @ObservedObject var model: EditorModel
    let transcript: Transcript
    @Binding var search: String

    private var rightToLeft: Bool {
        Locale.Language(identifier: transcript.language).characterDirection == .rightToLeft
    }

    private var lines: [TranscriptSegment] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return transcript.segments }
        return transcript.segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Show captions on the video", isOn: model.binding(\.captions, key: "captions"))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
                .font(.system(size: 13))
                .disabled(transcript.segments.isEmpty)

            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faint)
                    TextField("Search the transcript", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))

                Menu {
                    Button("Copy All Text") { copy() }
                    Button("Save as Text…") { save(.text) }
                    Button("Save Subtitles (.srt)…") { save(.srt) }
                    Divider()
                    Button("Create Again…") { model.discardTranscript() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Copy, save or recreate the transcript")
                .accessibilityLabel("Transcript actions")
            }

            if transcript.segments.isEmpty {
                Text("No speech was found in this recording. If people did talk, try Create Again with a different language.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        TranscriptRow(line: line, active: model.activeLineID == line.id, cut: model.isCut(line),
                                      showSpeaker: transcript.hasSpeakers, rightToLeft: rightToLeft) {
                            model.seek(toSource: line.start + 0.02)
                        }
                    }
                }
                if lines.isEmpty {
                    Text("Nothing matches “\(search)”.").font(.system(size: 12.5)).foregroundStyle(Theme.subtext)
                }
            }
        }
    }

    private var summary: String {
        let name = Locale.current.localizedString(forIdentifier: transcript.language) ?? transcript.language
        let count = search.trimmingCharacters(in: .whitespaces).isEmpty ? transcript.segments.count : lines.count
        return "\(count) line\(count == 1 ? "" : "s") · \(name) · click a line to jump there"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TranscriptFormat.text(model.editedLines, speakers: transcript.hasSpeakers), forType: .string)
    }

    private enum Kind { case text, srt }

    /// Both files describe the edited video: cut parts are left out and the
    /// times match what Export produces.
    private func save(_ kind: Kind) {
        let panel = NSSavePanel()
        let base = model.recording.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        switch kind {
        case .text:
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = base + ".txt"
        case .srt:
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
            panel.nameFieldStringValue = base + ".srt"
        }
        let lines = model.editedLines
        let speakers = transcript.hasSpeakers
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let content = kind == .text ? TranscriptFormat.text(lines, speakers: speakers) : TranscriptFormat.srt(lines)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                model.transcriptError = "The file could not be saved: \(error.localizedDescription)"
            }
        }
    }
}

private struct TranscriptRow: View {
    let line: TranscriptSegment
    let active: Bool
    let cut: Bool
    let showSpeaker: Bool
    let rightToLeft: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.clock(line.start))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(active ? Theme.accent : Theme.faint)
                    .frame(width: 36, alignment: .leading)
                VStack(alignment: rightToLeft ? .trailing : .leading, spacing: 2) {
                    if showSpeaker, let name = TranscriptFormat.speakerName(line.speaker) {
                        Text(name)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(line.speaker == .mic ? Theme.accent : Theme.good)
                    }
                    Text(line.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .strikethrough(cut, color: Theme.subtext)
                        .multilineTextAlignment(rightToLeft ? .trailing : .leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(active ? Theme.accent.opacity(0.16) : (hovering ? Theme.card : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(cut ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(cut ? "This part has been cut from the video" : "Jump to \(Format.clock(line.start))")
    }
}
