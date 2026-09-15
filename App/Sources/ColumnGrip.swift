import AppKit
import SwiftUI

/// The divider between a page and the documents beside it, and the handle that moves it.
///
/// Used on an agent's page, where the other column is its terminal, and on a project's,
/// where it is the backlog. (T329, then T349.)
///
/// A fixed width was a guess about how much of the window a document is worth, and the
/// answer changes with what you are reading: a status report wants a third of the page,
/// a screenshot wants most of it. The width is remembered, so it is set once rather than
/// every time. (Alex, 15 Sep 2026.)
struct ColumnGrip: View {
    @Binding var width: Double
    /// How wide the whole page is, so the drag can be held to what is left after the
    /// other column has what it needs.
    var beside: Double
    /// Where the column started when this drag began, so the pointer stays on the
    /// divider instead of drifting away from it over a long drag.
    @State private var startedAt: Double?

    var body: some View {
        Divider()
            // The line is a hairline and a hairline is not a target. The hit region is
            // wider than what is drawn, which is how every split view on this Mac works.
            .overlay {
                Color.clear
                    .frame(width: 10)
                    .contentShape(.rect)
                    .onHover { inside in
                        // The pointer says what will happen before anything does.
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                let from = startedAt ?? width
                                if startedAt == nil { startedAt = from }
                                // Dragging left makes the documents wider: the divider
                                // is on their left-hand side.
                                width = Self.width(from - drag.translation.width, beside: beside)
                            }
                            .onEnded { _ in startedAt = nil }
                    )
            }
    }

    /// What the column may be, on a page this wide. The other side keeps enough to be
    /// itself and the documents keep enough for a line of text to be worth reading; on a
    /// narrow window the two limits meet and the drag does nothing, which is the honest
    /// answer rather than a column squeezed to a stripe.
    static func width(_ wanted: Double, beside page: Double) -> Double {
        let smallest = 260.0
        let largest = max(smallest, page - 380)
        return min(max(wanted, smallest), largest)
    }
}

