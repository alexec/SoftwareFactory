import Foundation

/// The measurements the Mac app is built to.
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
}
