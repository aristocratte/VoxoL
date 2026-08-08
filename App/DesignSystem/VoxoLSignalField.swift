import SwiftUI

/// The faces the signal can take. Mode ordering is shared with `VoxoLSignal.metal`.
enum VoxoLSignalMode: Int, Equatable {
    case idle = 0
    case voice = 1
    case processing = 2
    case insights = 3
    case meeting = 4
    case transformation = 5
    case permissions = 6
    case engines = 7
    case ready = 8
}

/// How lively the signal is.
///
/// The approved direction keeps the dither functional rather than decorative, so a calm screen
/// drifts and only a genuinely live runtime state runs hot. Both are drawn by the GPU, so the
/// difference is one of intent rather than cost.
enum VoxoLSignalCadence {
    case still
    case ambient
    case live

    /// How fast the field itself advances. The ambient drift has to be slow enough to stay calm
    /// but fast enough to read as movement.
    var rate: Double {
        switch self {
        case .still: 0
        case .ambient: 0.55
        case .live: 1
        }
    }

    /// Shading is free, but every tick still costs a SwiftUI update: the shader arguments are
    /// rebuilt and the tree re-evaluated. An uncapped timeline runs at the display's 120 Hz for no
    /// visible benefit, so both cadences are pinned to a rate that already reads as continuous.
    var interval: Double {
        switch self {
        case .still: 1
        case .ambient: 1 / 30
        case .live: 1 / 60
        }
    }
}

/// The VoxoL dither, rendered by a Metal shader.
///
/// Two fields are always available: `mode` is what the surface shows, `secondaryMode` is where it
/// is heading, and `blend` crosses between them. Panning and crossing happen inside the shader, so
/// a caller can move the signal continuously without ever replacing a view.
struct VoxoLSignalField: View {
    @Environment(VoxoLTheme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let mode: VoxoLSignalMode
    var secondaryMode: VoxoLSignalMode?
    var blend: Double = 0
    /// Horizontal travel of the field, in field widths.
    var pan: Double = 0
    /// Vertical centre of the signal band, normalized. Only used when `focusSpread` is non-zero.
    var focus: Double = 0.5
    /// Width of the vertical envelope. Zero spreads the field over the whole surface.
    var focusSpread: Double = 0
    /// Where the pointer is, normalized to the field. The signal leans towards it.
    var pointer: CGPoint = .zero
    /// How strongly the field answers the pointer. Zero leaves it untouched.
    var pointerEnergy: Double = 0
    var cadence: VoxoLSignalCadence = .ambient
    /// Cell pitch in points. The dot inside a cell stays 2–4 pt, as in the reference renders.
    var cellSize: CGFloat = 8

    /// Resolved once: looking the function up through `ShaderLibrary`'s dynamic member lookup on
    /// every tick showed up as real per-frame cost.
    private static let function = ShaderLibrary.voxolDither

    var body: some View {
        GeometryReader { geometry in
            TimelineView(
                .animation(minimumInterval: resolvedCadence.interval, paused: isPaused)
            ) { timeline in
                let clock = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3600)

                Rectangle()
                    .fill(theme.canvas)
                    .colorEffect(
                        Self.function(
                            .float2(geometry.size),
                            .float(elapsed(clock)),
                            .float(Double(mode.rawValue)),
                            .float(Double((secondaryMode ?? mode).rawValue)),
                            .float(secondaryMode == nil ? 0 : min(max(blend, 0), 1)),
                            .float(pan),
                            .float(focus),
                            .float(max(0, focusSpread)),
                            .float2(pointer),
                            .float(min(max(pointerEnergy, 0), 1)),
                            .float(cellSize),
                            .color(theme.cobalt),
                            .color(theme.coral),
                            .color(theme.ink)
                        )
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var resolvedCadence: VoxoLSignalCadence {
        reduceMotion ? .still : cadence
    }

    private var isPaused: Bool {
        resolvedCadence.rate == 0
    }

    /// The shader runs in single precision under fast math, where a clock in the thousands stops
    /// resolving the small per-frame increments and the field silently stalls. The scaled time is
    /// therefore folded back onto a whole number of turns, which keeps every angle small and makes
    /// the fold itself invisible for the dominant wave terms.
    private func elapsed(_ clock: Double) -> Double {
        guard resolvedCadence.rate > 0 else { return 0.4 }
        let period = 2 * Double.pi * 16
        let scaled = clock * (mode == .voice ? 1.1 : 0.42) * resolvedCadence.rate
        return scaled.truncatingRemainder(dividingBy: period)
    }
}

/// Rebuilds any view out of the signal's dot grid while it arrives or leaves.
///
/// `progress` runs 0 (entirely dispersed into the field) to 1 (fully resolved). Conforming to
/// `Animatable` lets a single spring on the caller's side drive the whole material change.
struct VoxoLMaterialize: ViewModifier, Animatable {
    var progress: Double
    var scatter: CGFloat = 30
    var cellSize: CGFloat = 7
    var seed: Double = 3
    /// Where the cells come from and return to, in the view's own coordinates.
    var origin: CGPoint = .zero
    /// How strongly the cells are drawn out of that point. Zero scatters them in place.
    var originPull: Double = 0

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let settled = progress >= 0.998
        content.visualEffect { view, proxy in
            view.layerEffect(
                ShaderLibrary.voxolMaterialize(
                    .float2(proxy.size),
                    .float(min(max(progress, 0), 1)),
                    .float(cellSize),
                    .float(scatter),
                    .float(seed),
                    .float2(origin),
                    .float(min(max(originPull, 0), 1))
                ),
                // Cells can be read from anywhere on the page when they are being pulled out of a
                // single point, so the whole layer has to stay available.
                maxSampleOffset: originPull > 0
                    ? CGSize(width: proxy.size.width, height: proxy.size.height)
                    : CGSize(width: scatter + cellSize, height: scatter + cellSize),
                isEnabled: !settled
            )
        }
    }
}

extension View {
    /// Materializes the view out of the dither, or lets it dissolve back into it.
    func voxolMaterialize(
        _ progress: Double,
        scatter: CGFloat = 30,
        cellSize: CGFloat = 7,
        seed: Double = 3,
        origin: CGPoint = .zero,
        originPull: Double = 0
    ) -> some View {
        modifier(
            VoxoLMaterialize(
                progress: progress,
                scatter: scatter,
                cellSize: cellSize,
                seed: seed,
                origin: origin,
                originPull: originPull
            )
        )
    }
}

// MARK: - The grain sphere

/// The six arcs of the sphere's readiness ring, animated as one value.
struct VoxoLRingVector: VectorArithmetic, Equatable {
    var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    /// A ring with nothing gathered yet.
    static var zero: VoxoLRingVector { VoxoLRingVector(values: Array(repeating: 0, count: 6)) }

    static func + (lhs: VoxoLRingVector, rhs: VoxoLRingVector) -> VoxoLRingVector {
        VoxoLRingVector(values: zip(lhs.values, rhs.values).map { $0 + $1 })
    }

    static func - (lhs: VoxoLRingVector, rhs: VoxoLRingVector) -> VoxoLRingVector {
        VoxoLRingVector(values: zip(lhs.values, rhs.values).map { $0 - $1 })
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

/// The voice as matter: a ball of ink grain on a fixed dither grid, lit from the upper left.
///
/// This is the mark the whole interface is built from — the preflight draws it large with its
/// readiness ring, the voice capsule draws it small without one. Every parameter maps to something
/// real: `resolution` is how gathered the system is (loose grain when something is missing, a
/// crisp form when everything is there), `energy` is live voice moving through it, `churn` is work
/// in progress, `bloom` a transient swell.
struct VoxoLGrainSphere: View, Animatable {
    @Environment(VoxoLTheme.self) private var theme

    var ring: VoxoLRingVector
    var resolution: Double
    var energy: Double
    var bloom: Double
    /// Sphere radius as a fraction of the view's shortest side.
    var radiusFactor: Double
    /// Grain pitch: the radius is divided by this to get the dither cell size.
    var cellDivisor: Double
    /// How fast the light travels around the form while the pipeline is working.
    var churn: Double
    var showsRing: Bool
    var paused: Bool

    init(
        ring: VoxoLRingVector = .zero,
        resolution: Double,
        energy: Double = 0,
        bloom: Double = 0,
        radiusFactor: Double = 0.25,
        cellDivisor: Double = 16,
        churn: Double = 0,
        showsRing: Bool = true,
        paused: Bool = false
    ) {
        self.ring = ring
        self.resolution = resolution
        self.energy = energy
        self.bloom = bloom
        self.radiusFactor = radiusFactor
        self.cellDivisor = cellDivisor
        self.churn = churn
        self.showsRing = showsRing
        self.paused = paused
    }

    nonisolated var animatableData:
        AnimatablePair<VoxoLRingVector, AnimatablePair<Double, AnimatablePair<Double, Double>>>
    {
        get { AnimatablePair(ring, AnimatablePair(resolution, AnimatablePair(energy, bloom))) }
        set {
            ring = newValue.first
            resolution = newValue.second.first
            energy = newValue.second.second.first
            bloom = newValue.second.second.second
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { timeline in
            let clock =
                paused
                ? 1.7
                : timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 2 * Double.pi * 64)

            Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) {
                context, size in
                draw(in: &context, size: size, clock: clock)
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, clock: Double) {
        let side = min(size.width, size.height)
        guard side > 8 else { return }

        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = side * radiusFactor
        let swell = 1 + bloom * 0.14 + energy * 0.07
        let sphereRadius = radius * (1 + 0.022 * sin(clock * 1.3)) * swell

        // The light drifts slowly around the upper left, so the ball feels alive even at rest,
        // and sweeps round it while the pipeline is actually working.
        let travel = clock * (1 + churn * 7)
        var lightX = -0.45 + 0.14 * cos(travel * 0.22) - churn * 0.5 * sin(travel * 0.22)
        var lightY = -0.55 + 0.12 * sin(travel * 0.29)
        var lightZ = 0.72
        let lightNorm = (lightX * lightX + lightY * lightY + lightZ * lightZ).squareRoot()
        lightX /= lightNorm
        lightY /= lightNorm
        lightZ /= lightNorm

        // An unresolved system has not gathered yet: its cells read the sphere from a displaced
        // position and the form goes loose. Bloom shakes a little extra matter free.
        let disperse = Double(radius) * ((1 - resolution) * 0.12 + bloom * 0.1)

        let cell = max(1.2, radius / cellDivisor)
        var ink = Path()
        var voice = Path()

        var y = centre.y - radius * 1.3
        while y < centre.y + radius * 1.3 {
            var x = centre.x - radius * 1.3
            while x < centre.x + radius * 1.3 {
                defer { x += cell }
                let grain = Self.hash((x / cell).rounded(.down), (y / cell).rounded(.down))

                let wander = grain * 2 * Double.pi
                let sampleX =
                    (Double(x + cell / 2 - centre.x) + cos(wander) * disperse)
                    / Double(sphereRadius)
                let sampleY =
                    (Double(y + cell / 2 - centre.y) + sin(wander) * disperse)
                    / Double(sphereRadius)
                let radial = sampleX * sampleX + sampleY * sampleY
                guard radial < 1 else { continue }

                // Classic halftone: the shadow side carries the big dots, but even the lit side
                // keeps a sparse grain so the full form stays legible.
                let normalZ = (1 - radial).squareRoot()
                let lambert = max(
                    0, sampleX * lightX + sampleY * lightY + normalZ * lightZ)
                var density = 0.24 + 0.7 * (1 - pow(lambert, 0.95))

                // Live voice: the grain flutters like sound moving through it.
                density += energy * 0.22 * sin(clock * 8.9 + grain * 6.28)
                guard grain < density else { continue }

                let dot = cell * (0.4 + 0.62 * min(1, density))
                let jitter = energy * cell * 0.5
                let rect = CGRect(
                    x: x + (cell - dot) / 2 + CGFloat(sin(clock * 7.1 + grain * 47) * jitter),
                    y: y + (cell - dot) / 2 + CGFloat(cos(clock * 6.3 + grain * 31) * jitter),
                    width: dot,
                    height: dot
                )

                // A few cells are the voice itself and stay coral, like the mark's raw dots.
                if grain > 0.88 {
                    voice.addEllipse(in: rect)
                } else {
                    ink.addEllipse(in: rect)
                }
            }
            y += cell
        }

        context.fill(ink, with: .color(theme.ink.opacity(0.9)))
        context.fill(voice, with: .color(theme.coral.opacity(0.72 + 0.28 * energy)))

        // Ripples while the voice is live.
        if energy > 0.02 {
            for wave in 0..<2 {
                let progress = (clock * 0.8 + Double(wave) * 0.5)
                    .truncatingRemainder(dividingBy: 1)
                let rippleRadius = radius * (1.05 + progress * 0.75)
                let rect = CGRect(
                    x: centre.x - rippleRadius,
                    y: centre.y - rippleRadius,
                    width: rippleRadius * 2,
                    height: rippleRadius * 2
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(theme.coral.opacity((1 - progress) * 0.4 * energy)),
                    lineWidth: 1.5
                )
            }
        }

        guard showsRing else { return }

        // The ring of six: what is gathered is what is ready.
        let ringRadius = radius * 1.3
        let gap = 12.0
        let sweep = 360.0 / 6 - gap
        for index in 0..<6 {
            let value = ring.values.indices.contains(index) ? ring.values[index] : 0
            let start = -90.0 + Double(index) * 360.0 / 6 + gap / 2
            var alpha = 0.14 + 0.76 * value
            if value > 0.05, value < 0.95 {
                alpha += 0.1 * sin(clock * 3.2 + Double(index))
            }

            var arc = Path()
            arc.addArc(
                center: centre,
                radius: ringRadius,
                startAngle: .degrees(start),
                endAngle: .degrees(start + sweep),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .color(theme.ink.opacity(alpha)),
                style: StrokeStyle(lineWidth: 1.8 + value * 1.2, lineCap: .round)
            )
        }
    }

    private static func hash(_ x: CGFloat, _ y: CGFloat) -> Double {
        let value = sin(Double(x) * 127.1 + Double(y) * 311.7 + 47.3) * 43758.5453
        return value - value.rounded(.down)
    }
}

/// A still sheet of the dither, used to give a small surface the page's paper grain.
struct VoxoLGrainTexture: View {
    @Environment(VoxoLTheme.self) private var theme

    var pitch: CGFloat = 3
    var intensity: Double = 0.5

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear) { context, size in
            var dots = Path()
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    defer { x += pitch }
                    let grain = Self.hash((x / pitch).rounded(), (y / pitch).rounded())
                    guard grain < 0.5 else { continue }
                    let dot = pitch * 0.32
                    dots.addEllipse(
                        in: CGRect(x: x, y: y, width: dot, height: dot)
                    )
                }
                y += pitch
            }
            context.fill(dots, with: .color(theme.ink.opacity(0.09 * intensity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func hash(_ x: CGFloat, _ y: CGFloat) -> Double {
        let value = sin(Double(x) * 91.7 + Double(y) * 213.3 + 11.9) * 43758.5453
        return value - value.rounded(.down)
    }
}
