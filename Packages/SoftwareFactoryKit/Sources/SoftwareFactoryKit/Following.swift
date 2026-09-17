import Foundation

/// Whether a conversation follows its own end.
///
/// A chat follows the newest thing while you are watching it and leaves you alone while you
/// are reading something further up. Both apps want it, and getting it right is subtle
/// enough that it belongs here with a test rather than in a view where it can only be
/// checked by hand. (Alex, 16 Sep 2026: work really hard to get the chat scrolling correct.
/// It needs to auto-scroll new content into view unless the user has scrolled up.)
///
/// **The trap, which is what this type exists for.** The obvious version asks the scroll
/// geometry "is the end on screen?" whenever the geometry changes, and believes the answer.
/// But content arriving *is* a geometry change: the content gets taller, the offset does
/// not move, so the end is suddenly off screen and the answer is no, a hair before the code
/// that wanted to scroll there reads it. The first thing an agent said turned following off
/// for good, which is exactly backwards: the page stopped following at the moment there was
/// something to follow.
///
/// **The rule.** Only a change with the content the same height is somebody moving the page.
/// Content growing or shrinking says nothing about what the person wants and is ignored.
/// So scrolling up turns following off, scrolling back to the end turns it on, and an agent
/// talking never touches it either way. A scroll of our own lands at the end with the height
/// unchanged, so it turns following back on, which is what should happen after a send.
public struct Following: Sendable, Equatable {
    /// How near the end counts as at it. A few points of slack, because a page that has just
    /// animated to the end often stops a pixel short and would otherwise decide it had been
    /// scrolled away from.
    public static let slack = 24.0

    /// Where a scroll view is, as the three numbers that say it.
    public struct Where: Sendable, Equatable {
        public var offset: Double
        public var container: Double
        public var content: Double

        public init(offset: Double, container: Double, content: Double) {
            self.offset = offset
            self.container = container
            self.content = content
        }

        /// Whether the end is on screen, within the slack.
        public var isAtEnd: Bool { offset + container >= content - Following.slack }

        /// Whether there is anything to scroll at all. A conversation shorter than the
        /// window sits at offset zero for ever, which reads as both ends at once.
        public var scrolls: Bool { content > container }
    }

    /// True while the page follows the end.
    public private(set) var isOn: Bool

    public init(isOn: Bool = true) {
        self.isOn = isOn
    }

    /// The geometry changed. Answers the new state, which is the old one unless the person
    /// moved the page.
    public mutating func moved(from was: Where, to now: Where) {
        guard now.content == was.content else { return }
        isOn = now.isAtEnd
    }

    /// Said something, which is asking to be taken to the end whatever was being read: what
    /// you said is now the end of it.
    public mutating func said() { isOn = true }
}
