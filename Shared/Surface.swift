import SwiftUI

/// What a card is made of.
///
/// Liquid Glass is the material of the controls and the navigation layer: the button you
/// press, the bar that floats over a page, the field at the foot of a conversation. It is
/// not what content is made of, and the convention says so in as many words. Every card
/// in both apps was glass, which on a floor of sixteen agents meant sixteen sheets of it
/// sampling each other with nothing underneath for any of them to sample. Glass over
/// glass is not twice as much glass; it is a grey rectangle.
///
/// So a card is the system's own secondary ground with a hairline around it, and the
/// glass stays where it does something: the microphone, the input bar, the option you
/// pick, and every button in both apps.
///
/// A tint is the one thing a card is allowed to say for itself, and it is spent on the
/// same thing the alarm is: a question waiting, a report gone stale. It sits over the
/// ground rather than replacing it, so a tinted card is the same card.
/// (Alex, 16 Sep 2026: conventional Liquid Glass.)
extension View {
    func cardSurface(cornerRadius: Double = Style.card, tint: Color? = nil) -> some View {
        self
            .background(tint?.opacity(0.14) ?? Color.clear, in: .rect(cornerRadius: cornerRadius))
            .background(.background.secondary, in: .rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator, lineWidth: 1))
    }
}
