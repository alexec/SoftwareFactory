import SwiftUI
import SoftwareFactoryKit

/// A microphone on a text field: talk, and the words land in it as you go.
///
/// The same idea as the factory's own dictate button and the same rules underneath,
/// `Spoken.appended` and `Spoken.live`: what has settled is added rather than written
/// over, so a correction typed into the field survives the next sentence, and what is
/// still being recognised sits on the end as a tail that the next revision replaces
/// instead of saying twice. (T445, Alex, 15 Sep 2026; the rules are T372's.)
///
/// It stops when you tap it again, when the field is sent, or when the view goes away. A
/// microphone left listening to an empty room is the one failure worth designing out.
struct DictateIntoField: View {
    @Environment(AppModel.self) private var model
    @Binding var words: String
    /// What to say while asking for the microphone, in the app's own voice, before the
    /// system alert.
    var about: String

    /// The end of `words` the recogniser is still revising.
    @State private var tail = ""
    @State private var folded = ""
    @State private var priming = false

    private var dictation: Dictation { model.dictation }
    private var listening: Bool { dictation.isListening }

    var body: some View {
        Button(action: tapped) {
            Image(systemName: listening ? "waveform" : "mic")
                .symbolEffect(.variableColor, isActive: listening)
                .foregroundStyle(listening ? Color(.alarm) : Color(.quiet))
        }
        .buttonStyle(.borderless)
        .help(listening ? "Stop listening" : "Say it instead of typing it")
        .accessibilityLabel(listening ? "Stop dictating" : "Dictate")
        .popover(isPresented: $priming, arrowEdge: .top) { primer }
        .onChange(of: dictation.settled) { _, _ in tookSettled() }
        .onChange(of: dictation.volatile) { _, _ in tookVolatile() }
        .onDisappear { if listening { Task { _ = await dictation.stop() } } }
    }

    /// Asked in the app's own words before the system alert, and never twice.
    private var primer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Say it instead of typing it")
                .font(.headline)
            Text(about)
                .font(.callout)
                .foregroundStyle(Color(.quiet))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continue") {
                    priming = false
                    Task {
                        await dictation.ask()
                        if dictation.standing == .allowed { await begin() }
                    }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(Style.sheetPadding)
        .frame(width: 300)
    }

    private func tapped() {
        if listening {
            Task { _ = await dictation.stop() }
            return
        }
        switch dictation.standing {
        case .allowed: Task { await begin() }
        case .notAsked: priming = true
        case .denied, .unavailable: priming = true
        }
    }

    private func begin() async {
        folded = ""
        tail = ""
        await dictation.start()
    }

    /// Words that have settled go in once, appended, so anything typed in front of them
    /// stays where it was.
    private func tookSettled() {
        let settled = dictation.settled
        guard settled.count > folded.count else { return }
        let addition = String(settled.dropFirst(folded.count))
        folded = settled
        if !tail.isEmpty, words.hasSuffix(tail) { words = String(words.dropLast(tail.count)) }
        tail = ""
        words = Spoken.appended(words, addition)
    }

    private func tookVolatile() {
        let shown = Spoken.live(words: words, tail: tail, volatile: dictation.volatile)
        words = shown.words
        tail = shown.tail
    }
}
