import AppKit
import SwiftUI
import TasjeelCore

/// What Tasjeel remembers about a project, to read and correct, and the
/// brief made from it for AI agents.
struct ProjectMemoryView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject private var app = AppState.shared
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ProjectMemory(name: "")
    @State private var features = ""
    @State private var facts = ""
    @State private var links = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project memory").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Written once, used by every video in this project, and saved as PROJECT.md: a brief you can give to any AI agent. Leave blank what you do not know; the chat adds what it learns.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    basics
                    if draft.kind == .app { appSection }
                    wording
                    brand
                    if !draft.learned.isEmpty { learned }
                }
                .padding(20)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy Brief for an AI Agent") {
                    commit()
                    model.copyBrief()
                    copied = true
                }
                .buttonStyle(QuietButtonStyle())
                .help("Copies PROJECT.md: paste it into Claude, ChatGPT or any AI agent so it knows the project")
                Button("Show PROJECT.md") {
                    commit()
                    model.revealBrief()
                }
                .buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    commit()
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 600, height: 680)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear {
            draft = model.memory
            features = draft.features.joined(separator: "\n")
            facts = draft.facts.joined(separator: "\n")
            links = draft.links.joined(separator: "\n")
        }
    }

    private func lines(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func commit() {
        draft.features = lines(features)
        draft.facts = lines(facts)
        draft.links = lines(links)
        model.save(draft)
    }

    // MARK: - Sections

    private var basics: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("The project")
            field("Name") { input("Orbit", text: $draft.name) }
            field("Kind") {
                Segmented(options: [(value: ProjectMemory.Kind.app, label: "An app"), (value: ProjectMemory.Kind.other, label: "Something else")],
                          selection: $draft.kind)
                    .frame(width: 250)
            }
            field("What it is", hint: "One or two sentences, as you would say it to a stranger.") {
                area("A video editor for the Mac that keeps everything on your machine.", text: $draft.summary, height: 52)
            }
            field("Who it is for") { area("People who make tutorials and record meetings.", text: $draft.audience, height: 38) }
        }
    }

    private var appSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("The app")
            field("Runs on") {
                HStack(spacing: 6) {
                    ForEach(ProjectMemory.platforms, id: \.self) { platform in
                        let on = draft.app.platforms.contains(platform)
                        Button(platform) {
                            if on { draft.app.platforms.removeAll { $0 == platform } } else { draft.app.platforms.append(platform) }
                        }
                        .buttonStyle(QuietButtonStyle(selected: on))
                    }
                }
            }
            field("Its window", hint: "The app's name as it appears on this Mac, used to take screenshots. For a phone app, the simulator; for a web app, your browser.") {
                HStack(spacing: 6) {
                    input("Simulator", text: $draft.app.window)
                    Menu("Open Windows") {
                        if app.windows.isEmpty { Text(app.hasScreenAccess ? "No app windows are open" : "Screen recording is not allowed yet") }
                        ForEach(Array(Set(app.windows.map(\.appName))).sorted(), id: \.self) { name in
                            Button(name) { draft.app.window = name }
                        }
                    }
                    .fixedSize()
                }
            }
            field("Address") { input("https://app.example.com", text: $draft.app.address) }
            field("Getting around", hint: "How to reach the screens worth showing. An AI agent follows this to take screenshots.") {
                area("Sign in with the demo account. The export screen is under File › Export.", text: $draft.app.guide, height: 52)
            }
        }
    }

    private var wording: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("What to say")
            field("What it does", hint: "One feature on each line.") { area("Exports in 4K\nCaptions in 50 languages", text: $features, height: 70) }
            field("True facts", hint: "Figures and customers' own words, one on each line. Only these may appear as numbers or quotes in a video.") {
                area("12,000 teams use it\n“It saved us a day a week.” Sara K., Head of Support", text: $facts, height: 60)
            }
            field("How it talks") { area("Plain and confident. No hype, no exclamation marks.", text: $draft.voice, height: 38) }
            field("Links", hint: "One on each line.") { area("example.com", text: $links, height: 38) }
            field("Notes", hint: "Anything else worth knowing.") { area("", text: $draft.notes, height: 52) }
        }
    }

    private var brand: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Brand")
            field("Logo", hint: pictures.isEmpty ? "Add a logo to the project's materials first, then choose it here." : nil) {
                Picker("Logo", selection: $draft.logo) {
                    Text("None").tag("")
                    ForEach(pictures) { Text($0.name).tag($0.file) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(pictures.isEmpty)
            }
            field("Colours", hint: "Written like #8F7CFF. Leave empty for the dark default.") {
                HStack(spacing: 10) {
                    color("Accent", text: $draft.accent)
                    color("Background", text: $draft.background)
                    color("Text", text: $draft.text)
                }
            }
        }
    }

    private var learned: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Learned along the way")
            ForEach(draft.learned) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text(item.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .reading(item.text)
                    Text(item.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11)).foregroundStyle(Theme.faint)
                    IconButton(symbol: "xmark", help: "Forget this", size: 20) {
                        draft.learned.removeAll { $0.id == item.id }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .cardSurface(radius: 8)
            }
        }
    }

    private var pictures: [StudioMaterial] { model.materials.filter { $0.kind == .picture } }

    // MARK: - Pieces

    private func field(_ label: String, hint: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.subtext)
                .frame(width: 104, alignment: .trailing)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                content()
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func input(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func area(_ placeholder: String, text: Binding<String>, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .allowsHitTesting(false)
            }
            TextEditor(text: text)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
        }
        .frame(height: height)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func color(_ label: String, text: Binding<String>) -> some View {
        let value = text.wrappedValue.trimmingCharacters(in: .whitespaces)
        let valid = value.hasPrefix("#") && value.count == 7 && value.dropFirst().allSatisfy(\.isHexDigit)
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(valid ? Color(hexString: value) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.strokeStrong))
                .frame(width: 18, height: 18)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .frame(width: 84)
        }
        .padding(.horizontal, 7)
        .frame(height: 28)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(!value.isEmpty && !valid ? Theme.warn : Theme.stroke))
        .help(label)
    }
}
