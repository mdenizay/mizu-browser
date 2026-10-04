import AppKit
import SwiftUI

extension Color {
    init(hex: Int) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

/// A colour field in the manner of Arc and Zen: drag a dot to choose the
/// colour, add a second dot for a gradient, pick light or dark, and set how
/// strongly the colours wash over the window. Each profile has its own.
struct ThemePicker: View {
    @ObservedObject var profile: Profile
    @ObservedObject private var prefs = Prefs.shared

    private static let presets: [(Int, Int)] = [
        (0x0A84FF, -1), (0x1DAA61, -1), (0x8E5BE8, -1), (0xE8497F, -1), (0xE8792B, -1), (0x6E6E73, -1),
        (0xF2709C, 0xFF9472), (0x7F7FD5, 0x91EAE4), (0x11998E, 0x38EF7D), (0xF7971E, 0xFFD200), (0x654EA3, 0xEAAFC8), (0x2193B0, 0x6DD5ED),
    ]

    /// Where a colour sits on the field: hue across, vividness down.
    static func position(of hex: Int) -> CGPoint {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        NSColor(hex: hex).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return CGPoint(x: h, y: 1 - min(max((s - 0.15) / 0.8, 0), 1))
    }

    static func color(at point: CGPoint) -> Int {
        let color = NSColor(hue: min(max(point.x, 0), 0.999), saturation: 0.15 + 0.8 * (1 - min(max(point.y, 0), 1)), brightness: 0.86, alpha: 1)
            .usingColorSpace(.sRGB) ?? .systemBlue
        return Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255)
    }

    private var colors: [Int] { profile.color2 >= 0 ? [profile.color1, profile.color2] : [profile.color1] }

    /// The point straight across the centre of the field: the opposite colour.
    static func opposite(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - min(max(point.x, 0), 1), y: 1 - min(max(point.y, 0), 1))
    }

    /// Moves a dot. With two dots they stay opposite each other, so dragging
    /// either one carries the other across the field.
    private func move(_ index: Int, to point: CGPoint) {
        let paired = profile.color2 >= 0
        let own = Self.color(at: point), other = Self.color(at: Self.opposite(point))
        if index == 0 {
            profile.color1 = own
            if paired { profile.color2 = other }
        } else {
            profile.color2 = own
            profile.color1 = other
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            field
            HStack(spacing: 8) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        profile.color1 = preset.0
                        profile.color2 = preset.1
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: preset.0), Color(hex: preset.1 >= 0 ? preset.1 : preset.0)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $profile.intensity, in: 0.0...0.6)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
            }
            .help(L("How strongly the colours tint the window"))
        }
    }

    private var field: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // The field shows the colours it stands for, softly, under a dot grid.
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.125).map { Color(hue: $0, saturation: 0.55, brightness: 0.92) },
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(0.35)
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.75)], startPoint: .top, endPoint: .bottom)
                Canvas { context, canvas in
                    for x in stride(from: 6.0, to: canvas.width, by: 9) {
                        for y in stride(from: 6.0, to: canvas.height, by: 9) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.primary.opacity(0.18)))
                        }
                    }
                }
                // Light or dark, as in the browsers this is borrowed from.
                HStack(spacing: 4) {
                    ForEach([("system", "sparkles"), ("light", "sun.max.fill"), ("dark", "moon.fill")], id: \.0) { mode, icon in
                        Button { prefs.appearance = mode } label: {
                            Image(systemName: icon).font(.system(size: 12))
                                .frame(width: 26, height: 24)
                                .background(prefs.appearance == mode ? AnyShapeStyle(.primary.opacity(0.14)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                // One dot, or two for a gradient.
                HStack(spacing: 14) {
                    Button { profile.color2 = -1 } label: { Image(systemName: "minus") }
                        .disabled(profile.color2 < 0)
                    Button {
                        // The second colour starts as the first one's opposite.
                        profile.color2 = Self.color(at: Self.opposite(Self.position(of: profile.color1)))
                    } label: { Image(systemName: "plus") }
                        .disabled(profile.color2 >= 0)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)

                ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                    let point = Self.position(of: hex)
                    Circle().fill(Color(hex: hex))
                        .frame(width: index == 0 ? 34 : 22, height: index == 0 ? 34 : 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        // Kept a little inside the field so a dot at the edge stays whole.
                        .position(x: 20 + point.x * (size.width - 40), y: 34 + point.y * (size.height - 68))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            move(index, to: CGPoint(x: (value.location.x - 20) / (size.width - 40),
                                                    y: (value.location.y - 34) / (size.height - 68)))
                        })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
        .frame(height: 190)
    }
}
