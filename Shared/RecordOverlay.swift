import SwiftUI

/// Dictating a task: hold the button, say it, let go. The words are added as a task the
/// moment the button is released; nothing lands in a text field first. (Alex, 12 Sep
/// 2026: press and hold to record, release to save.) The microphone primer and the
/// denied and unavailable states live here too, so the add row stays one line.
struct RecordOverlay: View {
    var dictation: Dictation
    var onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var holding = false
    @State private var heardNothing = false
    @State private var finishing = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("Dictate a task")
                    .font(.headline)
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            }

            switch dictation.standing {
            case .notAsked:
                primer
            case .denied:
                Text(Self.deniedText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable(let why):
                Text(why)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .allowed:
                recorder
            }
        }
        .padding(20)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 300)
        .onDisappear { if dictation.isListening { _Concurrency.Task { await dictation.stop() } } }
    }

    private var primer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Software Factory listens while you hold the button. The words are recognised on this device as you say them, and nothing is recorded.")
                .fixedSize(horizontal: false, vertical: true)
            Button {
                _Concurrency.Task { await dictation.ask() }
            } label: {
                Text("Continue").frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.glassProminent)
        }
    }

    private var recorder: some View {
        VStack(spacing: 16) {
            ScrollView {
                Text(dictation.text.isEmpty ? (heardNothing ? "Nothing heard. Hold the button and try again." : "Hold the button and say the task. Let go to add it.") : dictation.text)
                    .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.default, value: dictation.text)
            }
            .frame(minHeight: 90)

            ZStack {
                Circle()
                    .fill(holding ? Color.red : Color.accentColor)
                    .frame(width: holding ? 96 : 84, height: holding ? 96 : 84)
                    .shadow(color: (holding ? Color.red : Color.accentColor).opacity(0.35), radius: holding ? 18 : 8)
                Image(systemName: finishing ? "ellipsis" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: holding)
            }
            .animation(.snappy, value: holding)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !holding, !finishing { begin() } }
                    .onEnded { _ in if holding { finish() } }
            )
            .accessibilityLabel("Hold to record")
            .accessibilityHint("Say the task, then let go to add it")

            Text(holding ? "Listening. Let go to add it." : "Hold to record")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func begin() {
        holding = true
        heardNothing = false
        dictation.clear()
        _Concurrency.Task { await dictation.start() }
    }

    private func finish() {
        holding = false
        finishing = true
        _Concurrency.Task {
            let words = await dictation.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            finishing = false
            if words.isEmpty {
                heardNothing = true
            } else {
                onSave(words)
                dictation.clear()
                dismiss()
            }
        }
    }

    private func cancel() {
        _Concurrency.Task {
            if dictation.isListening { await dictation.stop() }
            dictation.clear()
            dismiss()
        }
    }

    #if os(macOS)
    static let deniedText = "Dictation needs the microphone, which can be turned on for Software Factory in System Settings, Privacy and Security."
    #else
    static let deniedText = "Dictation needs the microphone, which can be turned on for Software Factory in the iOS Settings app."
    #endif
}
