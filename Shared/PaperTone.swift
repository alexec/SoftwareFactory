import SwiftUI
import SoftwareFactoryKit

/// The colours of paper, as SwiftUI knows them, off the same tokens the documents are set
/// in. One source, so the agent's page and a document it filed cannot drift apart.
/// (Alex, 16 Sep 2026.)
extension Color {
    init(_ tone: Paper.Tone) {
        #if os(macOS)
        self = Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: dark ? tone.hex.dark : tone.hex.light)
        })
        #else
        self = Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? tone.hex.dark : tone.hex.light)
        })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    /// Six digits, no hash. Anything else is magenta, which is a colour you notice.
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0xFF00FF
        self.init(srgbRed: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0xFF00FF
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  alpha: 1)
    }
}
#endif
