import SwiftUI
import SoftwareFactoryKit

/// Talking to the factory. A microphone in the corner of the window: hold it, say what
/// you want, and what it understood comes back as a row you can correct.
///
/// It proposes and it never files. What was heard lands in a field with the project
/// beside it, and nothing happens until Add. A misheard project name that quietly filed
/// work on the wrong backlog would be worse than typing it, because you would not find
/// out for a week. (T340, and design/dictation.md.)
struct DictateButton: View {
    @Environment(AppModel.self) private var model
    /// The project whose page is open, which is the project when the words name none.
    var lookingAt: String?

    @State private var showing = false
    @State private var heard: Spoken.Heard?
    @State private var title = ""
    @State private var projectID: String?
    /// Everything said, kept for the task's note.
    @State private var said = ""
    /// When the words last changed, so a pause can be told from a thought. (T351.)
    @State private var lastWords = Date()
    @State private var watching: Task<Void, Never>?

    /// How long a silence has to be before it is the end of what you were saying. Short
    /// enough not to sit there afterwards, long enough to think mid-sentence.
    private static let pause: TimeInterval = 2.5

    private var dictation: Dictation { model.dictation }

    var body: some View {
        Button {
            showing = true
            start()
        } label: {
            Image(systemName: dictation.isListening ? "waveform" : "mic.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .symbolEffect(.variableColor, isActive: dictation.isListening)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Say what to add, and which project it is for")
        .accessibilityLabel("Dictate a task")
        .popover(isPresented: $showing, arrowEdge: .top) { sheet }
        .onChange(of: showing) { if !showing { finish() } }
    }

    @ViewBuilder
    private var sheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch dictation.standing {
            case .allowed:
                if dictation.isListening { listening } else { proposal }
            case .notAsked:
                primer
            case .denied:
                denied
            case .unavailable(let why):
                Text(why).foregroundStyle(.secondary)
            }
        }
        .padding(Style.sheetPadding)
        .frame(width: 380)
    }

    /// The words as they are recognised, so you can see it is hearing you.
    ///
    /// Room for a paragraph, not a line: a dictated task is often three sentences, and a
    /// box that scrolls after one of them hides what you have already said just as you
    /// are deciding whether to keep going. It scrolls once it is past that. (T351.)
    private var listening: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Listening")
                    .font(.headline)
                Spacer(minLength: 0)
                Text("Stops on its own when you do")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                Text(dictation.text.isEmpty ? "Say what to add, and which project it is for." : dictation.text)
                    .font(.callout)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: 180)
            HStack {
                Spacer()
                Button("Stop", systemImage: "stop.fill") { stop() }
                    .buttonStyle(.glassProminent)
            }
        }
        // A pause is the end of what you were saying. Nothing is filed by it: it stops
        // the listening and shows you the row, which is where it was always going.
        .onChange(of: dictation.text) { lastWords = .now }
    }

    /// What it understood, as something to correct rather than something that happened.
    @ViewBuilder
    private var proposal: some View {
        if let heard {
            VStack(alignment: .leading, spacing: 10) {
                Text(heard.projectWasSaid ? "You said which project" : "On the project you are looking at")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Project", selection: $projectID) {
                    Text("Pick a project").tag(String?.none)
                    ForEach(model.snapshot.projects, id: \.id) { project in
                        Text(project.name).tag(String?.some(project.id))
                    }
                }
                .labelsHidden()
                TextField("What to add", text: $title, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                HStack {
                    Button("Say it again", systemImage: "mic") { start() }
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Throw away") { showing = false }
                    Button("Add", action: add)
                        .buttonStyle(.glassProminent)
                        .disabled(projectID == nil || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        } else {
            Text("Nothing was heard.")
                .foregroundStyle(.secondary)
        }
    }

    /// The app's own words before the system alert, the way every other permission here
    /// is asked for.
    private var primer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say what to add")
                .font(.headline)
            Text("Talk to the factory and it works out which project you mean and what to put on its backlog. "
                 + "The words are recognised on this Mac and nothing is recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Continue") { Task { await dictation.ask(); start() } }
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private var denied: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The microphone is off for this app")
                .font(.headline)
            Text("Turn it on in System Settings, under Privacy & Security, and come back.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func start() {
        heard = nil
        lastWords = .now
        Task { await dictation.start() }
        watching?.cancel()
        watching = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard dictation.isListening else { continue }
                // Only after something has been said: opening it and thinking for three
                // seconds should not close it again.
                guard !dictation.text.isEmpty,
                      Date().timeIntervalSince(lastWords) >= Self.pause else { continue }
                stop()
                return
            }
        }
    }

    private func stop() {
        watching?.cancel()
        watching = nil
        Task {
            await dictation.stop()
            let understood = Spoken.heard(dictation.text, projects: model.snapshot.projects,
                                          lookingAt: lookingAt)
            heard = understood
            title = understood.title
            said = understood.said
            projectID = understood.projectID
        }
    }

    /// Closing the popover ends the listening, whatever was said.
    private func finish() {
        watching?.cancel()
        watching = nil
        if dictation.isListening { Task { await dictation.stop() } }
        heard = nil
        title = ""
        said = ""
        projectID = nil
    }

    private func add() {
        guard let projectID, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // The first word is the work, exactly as it is when the row is typed. Saying
        // "fix the timetable" files a Fix without dictation knowing about work at all.
        let parsed = FactoryTask.Work.reading(title: title)
        // Everything said goes in the note, whole, unless the title already is all of
        // it. If the split into a title was wrong the words are still there to read.
        let whole = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (whole.isEmpty || whole == title) ? "" : "Said: \(whole)"
        model.addTask(to: projectID, title: parsed.title, note: note, work: parsed.work)
        showing = false
    }
}
