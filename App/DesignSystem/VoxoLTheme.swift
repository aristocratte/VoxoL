import AppKit
import CoreText
import Observation
import SwiftUI

@MainActor
@Observable
final class VoxoLTheme {
    let canvas = Color(nsColor: .voxol(light: 0xF4F1E8, dark: 0x191816))
    let surface = Color(nsColor: .voxol(light: 0xFFFDF8, dark: 0x22201D))
    let raisedSurface = Color(nsColor: .voxol(light: 0xFFFFFF, dark: 0x292621))
    let ink = Color(nsColor: .voxol(light: 0x171713, dark: 0xF5F1E9))
    let secondaryInk = Color(nsColor: .voxol(light: 0x77736A, dark: 0xB8B1A6))
    let line = Color(nsColor: .voxol(light: 0xE8E8E2, dark: 0x3A3631))
    let selection = Color(nsColor: .voxol(light: 0xEEEBE2, dark: 0x34302B))
    let recording = Color(nsColor: .voxol(light: 0xC84D45, dark: 0xE06A62))
    let warning = Color(nsColor: .voxol(light: 0xA66B20, dark: 0xD39A4A))
    let success = Color(nsColor: .voxol(light: 0x2E6B51, dark: 0x71A27F))
    let cobalt = Color(nsColor: .voxol(light: 0x2449F8, dark: 0x7892FF))
    let cobaltSoft = Color(nsColor: .voxol(light: 0xDCE4FF, dark: 0x263257))
    let coral = Color(nsColor: .voxol(light: 0xFF7048, dark: 0xFF8A68))
    let coralSoft = Color(nsColor: .voxol(light: 0xFFE1D7, dark: 0x4B2C26))
    let sageSoft = Color(nsColor: .voxol(light: 0xDEEEE4, dark: 0x253A2D))

    init() {
        VoxoLTypography.registerOutfit()
    }
}

enum VoxoLTypography {
    static func font(
        size: CGFloat,
        weight: Font.Weight = .regular,
        relativeTo textStyle: Font.TextStyle = .body
    ) -> Font {
        registerOutfit()
        return .custom("Outfit", size: size, relativeTo: textStyle).weight(weight)
    }

    static func registerOutfit() {
        _ = outfitRegistration
    }

    private static let outfitRegistration: Void = {
        guard
            let fontURL = Bundle.main.url(
                forResource: "Outfit-Variable",
                withExtension: "ttf"
            )
        else {
            return
        }
        CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()
}

private extension NSColor {
    static func voxol(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return color(hex: isDark ? dark : light)
        }
    }

    static func color(hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// The Grain mark: a halftone sphere of ink dots, lit from the upper left, ringed by six arcs.
/// The same form the preflight draws live, frozen at readiness.
struct VoxoLMark: View {
    @Environment(VoxoLTheme.self) private var theme

    var size: CGFloat = 34

    var body: some View {
        Canvas { context, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            guard side > 4 else { return }
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            let radius = side * 0.34

            var lightX = -0.45
            var lightY = -0.55
            var lightZ = 0.72
            let norm = (lightX * lightX + lightY * lightY + lightZ * lightZ).squareRoot()
            lightX /= norm
            lightY /= norm
            lightZ /= norm

            func hash(_ x: Double, _ y: Double) -> Double {
                let value = sin(x * 127.1 + y * 311.7 + 47.3) * 43758.5453
                return value - value.rounded(.down)
            }

            let cell = max(1.3, radius / 7)
            var ink = Path()
            var voice = Path()

            var row = 0.0
            var y = centre.y - radius
            while y <= centre.y + radius {
                var column = 0.0
                var x = centre.x - radius
                while x <= centre.x + radius {
                    defer {
                        x += cell
                        column += 1
                    }
                    let sampleX = Double(x - centre.x) / Double(radius)
                    let sampleY = Double(y - centre.y) / Double(radius)
                    let radial = sampleX * sampleX + sampleY * sampleY
                    guard radial < 1 else { continue }

                    let normalZ = (1 - radial).squareRoot()
                    let lambert = max(
                        0, sampleX * lightX + sampleY * lightY + normalZ * lightZ)
                    let density = 0.24 + 0.7 * (1 - pow(lambert, 0.95))
                    let grain = hash(column, row)
                    guard grain < density else { continue }

                    let dot = cell * (0.4 + 0.62 * min(1, density))
                    let rect = CGRect(
                        x: x - dot / 2,
                        y: y - dot / 2,
                        width: dot,
                        height: dot
                    )
                    if grain > 0.88 {
                        voice.addEllipse(in: rect)
                    } else {
                        ink.addEllipse(in: rect)
                    }
                }
                y += cell
                row += 1
            }

            context.fill(ink, with: .color(theme.ink.opacity(0.9)))
            context.fill(voice, with: .color(theme.coral))

            let ringRadius = radius * 1.32
            let gap = 6.0
            let litPattern = [1.0, 0.3, 1.0, 1.0, 0.3, 1.0]
            for index in 0..<6 {
                let lit = litPattern[index]
                let start = -90.0 + Double(index) * 60 + gap
                var arc = Path()
                arc.addArc(
                    center: centre,
                    radius: ringRadius,
                    startAngle: .degrees(start),
                    endAngle: .degrees(start + 60 - gap * 2),
                    clockwise: false
                )
                context.stroke(
                    arc,
                    with: .color(theme.ink.opacity(0.14 + 0.76 * lit)),
                    style: StrokeStyle(
                        lineWidth: max(1, radius * 0.09),
                        lineCap: .round
                    )
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("VoxoL"))
    }
}

enum VoxoLBrand {
    static func statusItemImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 21, height: 18), flipped: false) { rect in
            let scale = min(rect.width, rect.height) / 64
            let offsetX = rect.midX - 32 * scale
            let offsetY = rect.midY - 32 * scale
            NSColor.black.setFill()
            NSColor.black.setStroke()

            func stroke(_ path: NSBezierPath) {
                path.lineWidth = max(1.7, 8 * scale)
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }

            for (x, y, radius) in [
                (8.0, 25.0, 2.0), (8, 39, 2),
                (16, 20, 2.5), (16, 32, 3), (16, 44, 2.5),
                (25, 17, 3), (25, 32, 4), (25, 47, 3),
            ] {
                NSBezierPath(
                    ovalIn: NSRect(
                        x: offsetX + (x - radius) * scale,
                        y: offsetY + (64 - y - radius) * scale,
                        width: radius * 2 * scale,
                        height: radius * 2 * scale
                    )
                ).fill()
            }

            let threshold = NSBezierPath()
            threshold.move(to: brandPoint(39, 13, scale: scale, x: offsetX, y: offsetY))
            threshold.curve(
                to: brandPoint(56, 32, scale: scale, x: offsetX, y: offsetY),
                controlPoint1: brandPoint(49.5, 16, scale: scale, x: offsetX, y: offsetY),
                controlPoint2: brandPoint(56, 22.5, scale: scale, x: offsetX, y: offsetY)
            )
            threshold.curve(
                to: brandPoint(39, 51, scale: scale, x: offsetX, y: offsetY),
                controlPoint1: brandPoint(56, 41.5, scale: scale, x: offsetX, y: offsetY),
                controlPoint2: brandPoint(49.5, 48, scale: scale, x: offsetX, y: offsetY)
            )
            stroke(threshold)

            return true
        }
        image.isTemplate = true
        return image
    }

    private static func brandPoint(
        _ x: CGFloat,
        _ y: CGFloat,
        scale: CGFloat,
        x offsetX: CGFloat,
        y offsetY: CGFloat
    ) -> NSPoint {
        NSPoint(x: offsetX + x * scale, y: offsetY + (64 - y) * scale)
    }
}

struct VoxoLCard<Content: View>: View {
    @Environment(VoxoLTheme.self) private var theme

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(20)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            }
    }
}

struct StudioHeader: View {
    @Environment(VoxoLTheme.self) private var theme

    let eyebrow: LocalizedStringKey
    let title: LocalizedStringKey
    let summary: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.secondaryInk)
                .textCase(.uppercase)
                .tracking(0.8)

            Text(title)
                .font(.system(size: 28, weight: .semibold, design: .default))
                .foregroundStyle(theme.ink)

            Text(summary)
                .font(.body)
                .foregroundStyle(theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}

struct StatusPill: View {
    @Environment(VoxoLTheme.self) private var theme

    let title: LocalizedStringKey
    let symbol: String
    var tone: Color?

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tone ?? theme.secondaryInk)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.selection.opacity(0.72))
            .clipShape(Capsule())
    }
}

struct KeyboardShortcutBadge: View {
    @Environment(VoxoLTheme.self) private var theme

    let keys: String

    var body: some View {
        Text(keys)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(theme.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            }
            .accessibilityLabel(Text("Shortcut: \(keys)"))
    }
}

struct PrototypeBadge: View {
    @Environment(VoxoLTheme.self) private var theme

    var body: some View {
        Text("Design prototype")
            .font(.caption2.weight(.bold))
            .foregroundStyle(theme.secondaryInk)
            .textCase(.uppercase)
            .tracking(0.7)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(theme.selection)
            .clipShape(Capsule())
    }
}

struct VoxoLPrimaryButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? theme.surface : theme.secondaryInk)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                isEnabled
                    ? (configuration.isPressed ? theme.secondaryInk : theme.ink)
                    : theme.selection
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .scaleEffect(isEnabled && configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.72)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

struct VoxoLSecondaryButtonStyle: ButtonStyle {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(isEnabled ? theme.ink : theme.secondaryInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isEnabled && configuration.isPressed ? theme.selection : theme.raisedSurface
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.line, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.58)
    }
}

#Preview("Warm design system") {
    VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 12) {
            VoxoLMark(size: 42)
            VStack(alignment: .leading) {
                Text("VoxoL")
                    .font(.title2.weight(.semibold))
                Text("Your voice, ready to use.")
                    .foregroundStyle(.secondary)
            }
        }

        VoxoLCard {
            StudioHeader(
                eyebrow: "Dictation",
                title: "Speak naturally",
                summary: "VoxoL preserves your meaning and prepares the text locally."
            )
        }

        HStack {
            Button("Try the capsule") {}
                .buttonStyle(VoxoLPrimaryButtonStyle())
            StatusPill(title: "Local on this Mac", symbol: "lock")
        }
    }
    .padding(32)
    .frame(width: 620)
    .background(Color(nsColor: .windowBackgroundColor))
    .environment(VoxoLTheme())
}
