import SwiftUI
import SoftwareFactoryKit

/// A task field. The first word is the work: Design, Plan, Code, Fix, Review,
/// Investigate, Ship. Nothing is offered while you type it. The completions were
/// here and are gone: a row of words under the field you are dictating into is
/// something to read and dismiss on every task, and the first word is either one
/// of seven or it is Code. (T366.)
struct WorkField: View {
    var prompt: String
    @Binding var text: String
    var lineLimit: ClosedRange<Int> = 1...5

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(lineLimit)
    }
}
