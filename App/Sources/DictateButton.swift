import SwiftUI
import SoftwareFactoryKit

/// Talking to the factory. A microphone in the corner of the window: press it, say what
/// you want, and the words land in a task you can correct before it is filed.
///
/// One view rather than two. It listened on one screen and showed what it understood on
/// another, so you said your piece to a box that was about to be replaced, and a second
/// thought after the pause had nowhere to go: it had already stopped listening. Now the
/// project is the top line, the task is the middle, Add is the bottom, and it goes on
/// listening the whole time. A pause is not the end of anything; it is where the factory
/// looks at what you have said so far and works out which project you meant. Every word
/// goes in the field, the ones still being revised as well, and the next revision
/// replaces the tail it wrote last. (T372, T363, was T340, and design/dictation.md.)
///
/// It still proposes and never files. Nothing happens until Add. A misheard project name
/// that quietly filed work on the wrong backlog would be worse than typing it, because
/// you would not find out for a week.
struct DictateButton: View {
    @Environment(AppModel.self) private var model
    /// The project whose page is open, which is the project until the words name one.
    var lookingAt: String?

    @State private var showing = false
    /// The task, as it will be filed. Dictation lands in it; you can edit it where it is.
    @State private var words = ""
    @State private var projectID: String?
    /// How much of what the recogniser has settled is already in `words`, so the next
    /// burst is appended rather than the lot being written over your corrections.
    @State private var folded = ""
    /// The end of `words` that the recogniser is still revising, so the next revision
    /// replaces it instead of being said twice. (T372.)
    @State private var tail = ""
    /// When the words last changed, so a pause can be told from a thought. (T351.)
    @State private var lastWords = Date()
    /// What `words` held when the last pause was read, so one pause is read once.
    @State private var lastSettled = ""
    @State private var watching: Task<Void, Never>?

    /// How long a silence has to be before the factory takes a look at what was said.
    /// Long enough to think mid-sentence.
    private static let pause: TimeInterval = 2.5

    private var dictation: Dictation { model.dictation }

    private var canAdd: Bool {
        projectID != nil && !words.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Button {
            showing = true
            begin()
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
            case .allowed: row
            case .notAsked: primer
            case .denied: denied
            case .unavailable(let why):
                Text(why).foregroundStyle(Color(.quiet))
            }
        }
        .padding(Style.sheetPadding)
        .frame(width: 380)
    }

    /// The whole of it: which project, what to add, and Add.
    private var row: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Project", selection: $projectID) {
                    Text("Which project?").tag(String?.none)
                    ForEach(model.snapshot.projects, id: \.id) { project in
                        Text(project.name).tag(String?.some(project.id))
                    }
                }
                .labelsHidden()
                Spacer(minLength: 0)
                listeningMark
            }

            // Every word goes in the field, including the ones still being revised.
            // They used to sit in grey underneath it, which kept the field still and
            // meant reading your own sentence in two places, the half you were watching
            // being the half you could not touch. (T372.)
            TextField("Say what to add, and which project it is for", text: $words, axis: .vertical)
                .lineLimit(3...10)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            HStack {
                Button("Clear") { words = ""; folded = dictation.settled; tail = "" }
                    .buttonStyle(.glass)
                    .disabled(words.isEmpty)
                Spacer()
                Button("Add", action: add)
                    .buttonStyle(.glassProminent)
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
            }
        }
        // Every burst of recognised words is added to the task rather than replacing it,
        // so a correction typed into the field survives the next sentence.
        .onChange(of: dictation.settled) { speak() }
        .onChange(of: dictation.volatile) { speak() }
        .onChange(of: words) { lastWords = .now }
    }

    private var listeningMark: some View {
        Label(dictation.isListening ? "Listening" : "Not listening",
              systemImage: dictation.isListening ? "waveform" : "mic.slash")
            .font(.caption)
            .foregroundStyle(Color(.quiet))
            .labelStyle(.titleAndIcon)
            .symbolEffect(.variableColor, isActive: dictation.isListening)
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
                .foregroundStyle(Color(.quiet))
            HStack {
                Spacer()
                Button("Continue") { Task { await dictation.ask(); begin() } }
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
                .foregroundStyle(Color(.quiet))
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

    /// Opens on the project you are looking at, so the top line is right before you have
    /// said anything. Naming another one in the words still wins.
    private func begin() {
        words = ""
        folded = ""
        tail = ""
        lastSettled = ""
        projectID = lookingAt
        lastWords = .now
        listen()
    }

    /// Listening, and staying listening. The recogniser ends its own session now and
    /// then, and an agent who has stopped mid-thought to think should not find the
    /// microphone off when they start again. (T363.)
    private func listen() {
        watching?.cancel()
        watching = Task { @MainActor in
            await dictation.start()
            folded = dictation.settled
            tail = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard showing else { return }
                if !dictation.isListening {
                    await dictation.start()
                    folded = dictation.settled
                    tail = ""
                    continue
                }
                readThePause()
            }
        }
    }

    /// Everything the recogniser has said since we last looked, put in the field: what
    /// has settled goes into the task, and what is still being revised goes in after it
    /// as a tail the next revision replaces. (T372.)
    private func speak() {
        // The tail comes out first: what settles belongs in front of it, and the words
        // being revised are about to be said again.
        var base = Spoken.live(words: words, tail: tail, volatile: "").words
        let settled = dictation.settled
        if settled != folded {
            // A restarted session begins its transcript again, so anything that is not
            // more of what we have already folded is new words rather than a revision.
            let addition = settled.hasPrefix(folded) ? String(settled.dropFirst(folded.count)) : settled
            folded = settled
            base = Spoken.appended(base, addition)
        }
        let shown = Spoken.live(words: base, tail: "", volatile: dictation.volatile)
        words = shown.words
        tail = shown.tail
    }

    /// A silence, and what the factory makes of what was said. It never files and it
    /// never stops the listening: it reads the project out of the words, takes the naming
    /// of it out of the task, and leaves everything else where it is.
    private func readThePause() {
        guard Date().timeIntervalSince(lastWords) >= Self.pause else { return }
        // The task as it stands, without the tail the recogniser is still revising: the
        // project is read out of words somebody has finished saying.
        let bare = Spoken.live(words: words, tail: tail, volatile: "").words
        let said = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, said != lastSettled else { return }
        lastSettled = said
        let settled = Spoken.settling(bare, projects: model.snapshot.projects, project: projectID)
        projectID = settled.projectID
        if settled.projectWasSaid {
            let shown = Spoken.live(words: settled.words, tail: "", volatile: dictation.volatile)
            words = shown.words
            tail = shown.tail
            lastSettled = settled.words.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Closing the popover ends the listening, whatever was said.
    private func finish() {
        watching?.cancel()
        watching = nil
        if dictation.isListening { Task { await dictation.stop() } }
        words = ""
        folded = ""
        tail = ""
        lastSettled = ""
        projectID = nil
    }

    /// Files it, and goes on listening: the next thing you say is the next task, on the
    /// same project until you name another.
    private func add() {
        guard let projectID, canAdd else { return }
        // The first sentence is the title and the whole of it goes in the note, so a bad
        // split loses nothing. The first word is the work, exactly as it is when the row
        // is typed: saying "fix the timetable" files a Fix without dictation knowing
        // about work at all.
        let filed = Spoken.filing(words)
        let parsed = FactoryTask.Work.reading(title: filed.title)
        model.addTask(to: projectID, title: parsed.title, note: filed.note, work: parsed.work)
        words = ""
        folded = dictation.settled
        tail = ""
        lastSettled = ""
    }
}
