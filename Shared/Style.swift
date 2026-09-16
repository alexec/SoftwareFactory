import SwiftUI

/// The measurements both apps are built to.
///
/// It lived in the Mac's own sources, so the phone had its own numbers and drifted: two
/// corner radii it had picked for itself, and paddings that were nearly but not quite
/// these. One file in `Shared`, and a corner is the same corner on both.
/// (Alex, 16 Sep 2026: harmonize the iPhone interface.)
///
/// They were each written where they were used, so the same thing came out at four
/// sizes: a card at 18 points of corner and a card at 14, a box inside a card at 12 and
/// another at 8, a chip that was a capsule in five places and a rounded rectangle in the
/// sixth. None of it is wrong on its own and all of it together reads as an app made by
/// several people. (T343, Alex, 15 Sep 2026.)
///
/// Four sizes, and what each is for:
///
/// - `card`: anything sitting on glass in its own right. An agent's card, a document, a
///   question, a stat tile, the banner that says a write failed.
/// - `panel`: a box inside a card, which is always tighter than the card around it or
///   the two curves fight.
/// - `chip`: one word with a background. Capsule, not a radius: a chip is as round as it
///   is tall.
/// - `page`, `card padding`, `sheet padding`: the white space, in that order of size.
enum Style {
    static let card = 18.0
    static let panel = 12.0
    /// A page's own margin, around everything on it.
    static let page = 24.0
    /// Inside a card, from its edge to its words.
    static let cardPadding = 16.0
    /// Inside a sheet or a popover, which is a page rather than a card.
    static let sheetPadding = 20.0

    /// The type, and what each size is for.
    ///
    /// The corners were written down in T343 because the same thing had come out at four
    /// sizes; the type was left where it was used and did the same thing more quietly.
    /// Both apps tallied on 15 Sep 2026: callout fifty times, caption forty-eight,
    /// headline twenty-eight, which is a scale, and then five rows on the phone a step
    /// smaller than the same row on the Mac, two hard-coded pixel sizes that are the only
    /// text in either app that does not grow with Dynamic Type, and a heading inside a
    /// document smaller than the words around it.
    ///
    /// Every size here is a Dynamic Type style rather than a number, so all of it grows
    /// when the person's text does. A new piece of text names one of these or it is a
    /// decision worth arguing for, the same rule the corners follow. (T459.)
    enum Text {
        /// A page's own name. One per screen.
        static let page = Font.title2.weight(.semibold)
        /// A thing on that page: an agent, a project, a document.
        static let thing = Font.title3.weight(.semibold)
        /// What a row says. The ordinary size, and the one to reach for first.
        static let row = Font.callout
        /// The same, when it is the name of something rather than a sentence about it.
        static let rowName = Font.headline
        /// Said quietly: a date, a count, a hint, something read only when gone looking for.
        static let quiet = Font.caption
        /// A number to be read across the room: a gauge on the Capacity page.
        static let gauge = Font.system(.title, design: .rounded).weight(.semibold)
        /// The one word at the top of a first-run sheet, which is read once.
        static let welcome = Font.system(.largeTitle, design: .rounded).weight(.bold)
        /// A path, a pid, a command: the machine talking.
        static let machine = Font.caption.monospaced()
        /// The smallest thing that is still a control, such as the cross on a tab. Named
        /// rather than given a pixel size, so it grows with everything else.
        static let tiny = Font.caption2
    }
}
