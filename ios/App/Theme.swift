import SwiftUI

enum Theme {
    static let surface = Color(red: 0x0E / 255, green: 0x10 / 255, blue: 0x12 / 255)
    static let card = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x21 / 255)
    static let accent = Color(red: 0xFF / 255, green: 0x7A / 255, blue: 0x1A / 255)
    static let unlocked = Color(red: 0x3D / 255, green: 0xD6 / 255, blue: 0x8C / 255)
    static let locked = Color(red: 0xFF / 255, green: 0x5A / 255, blue: 0x5A / 255)
    static let secondaryText = Color.white.opacity(0.65)
    static let divider = Color.white.opacity(0.12)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
