import SwiftUI

/// A text field whose trailing control is a microphone while it is empty, and
/// whatever the caller's own submit control is once there is something to send,
/// typed or just dictated. Tapping (or, on the phone, holding) the microphone
/// records; the words said so far show live in a popover above the button, which
/// throbs while it listens. Letting go settles the words into the field, the same
/// place typing would have put them — the popover is gone, the submit control is
/// there instead. (Alex, 12 Sep 2026: click to start and click again to stop on the
/// Mac; hold on the phone, as dictating a task already worked.)
struct DictateField<Submit: View>: View {
    var placeholder: String
    @Binding var text: String
    var dictation: Dictation
    @ViewBuilder var submit: () -> Submit

    @State private var popoverOpen = false
    @State private var heardNothing = false

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...5)
            if isEmpty {
                recordButton
            } else {
                submit()
            }
        }
    }

    private var recordButton: some View {
        ZStack {
            Circle()
                .fill(dictation.isListening ? Color.red : Color.secondary.opacity(0.15))
                .frame(width: 36, height: 36)
            Image(systemName: "mic.fill")
                .font(Style.Text.rowName)
                .foregroundStyle(dictation.isListening ? .white : .secondary)
                .symbolEffect(.pulse, isActive: dictation.isListening)
        }
        .scaleEffect(dictation.isListening ? 1.15 : 1)
        .animation(.snappy, value: dictation.isListening)
        .contentShape(Circle())
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !dictation.isListening { begin() } }
                .onEnded { _ in if dictation.isListening { finish() } }
        )
        #else
        .onTapGesture { dictation.isListening ? finish() : begin() }
        #endif
        .accessibilityLabel(dictation.isListening ? "Recording. Let go to add the words." : "Dictate")
        .popover(isPresented: $popoverOpen) {
            popoverContent
                .padding(16)
                .frame(minWidth: 220, idealWidth: 260)
                .onDisappear {
                    if dictation.isListening { _Concurrency.Task { await dictation.stop() } }
                }
        }
    }

    @ViewBuilder
    private var popoverContent: some View {
        switch dictation.standing {
        case .notAsked:
            primer
        case .denied:
            Text(DictationHelp.deniedText)
                .foregroundStyle(Color(.quiet))
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable(let why):
            Text(why)
                .foregroundStyle(Color(.quiet))
                .fixedSize(horizontal: false, vertical: true)
        case .allowed:
            Text(dictation.text.isEmpty ? (heardNothing ? "Nothing heard. Try again." : "Listening…") : dictation.text)
                .foregroundStyle(dictation.text.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.default, value: dictation.text)
        }
    }

    private var primer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Taktu: Software Factory listens while you dictate. Words are recognised on this device; nothing is recorded.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Continue") { _Concurrency.Task { await dictation.ask() } }
                .buttonStyle(.glassProminent)
        }
    }

    private func begin() {
        popoverOpen = true
        guard dictation.standing == .allowed else { return }
        heardNothing = false
        dictation.clear()
        _Concurrency.Task { await dictation.start() }
    }

    private func finish() {
        _Concurrency.Task {
            let words = await dictation.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            if words.isEmpty {
                heardNothing = true
            } else {
                text = words
                popoverOpen = false
            }
        }
    }
}

/// Not on `DictateField` itself: Swift does not allow a stored static property on a
/// generic type.
private enum DictationHelp {
    #if os(macOS)
    static let deniedText = "Dictation needs the microphone, which can be turned on for Taktu: Software Factory in System Settings, Privacy and Security."
    #else
    static let deniedText = "Dictation needs the microphone, which can be turned on for Taktu: Software Factory in the iOS Settings app."
    #endif
}
