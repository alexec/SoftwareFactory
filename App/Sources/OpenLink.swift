import AppKit
import SwiftUI

/// A name on a card that goes somewhere.
///
/// Plain until the pointer is over it, then underlined, with the pointing hand to say so
/// before the click. A page of cards is mostly names, and colouring every one of them
/// would turn a quiet page into a page of blue; a Mac says this with the cursor and an
/// underline that turns up when you are already looking at it. (T338, Alex, 15 Sep 2026.)
struct OpenLink<Label: View>: View {
    var help: String
    var open: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            label.underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(help)
    }
}
