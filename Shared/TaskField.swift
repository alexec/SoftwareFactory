import SwiftUI
import SoftwareFactoryKit

/// The field a task is typed into, on both apps: the add row on a backlog, and the row
/// being edited.
///
/// It was `WorkField`, and the first word of what you typed named the kind of work: Design,
/// Plan, Code, Fix, Review, Investigate, Ship. Nothing was ever offered while you typed it,
/// because a row of words under the field is something to read and dismiss on every task
/// (T366), and now the work itself is gone (T417), so what is left is a text field that
/// grows to a few lines. Kept as a type rather than inlined, because the add row, the parked
/// add row and the edit row should stay the same field on both apps, which is what it was
/// always really for.
struct TaskField: View {
    var prompt: String
    @Binding var text: String
    var lineLimit: ClosedRange<Int> = 1...5

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(lineLimit)
    }
}
