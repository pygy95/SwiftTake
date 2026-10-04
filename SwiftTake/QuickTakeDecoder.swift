// MARK: - QuickTakeDecoder
//
// Decodes QuickTake 100/150 QTK archives using a native Swift pipeline.
//
// Decompression is adapted from Dave Coffin's dcraw: quicktake_100_load_raw
// and kodak_radc_load_raw. Copyright 1997-2018 Dave Coffin. See
// dcraw-notice.txt for the compared upstream source and its licensing notice.
// The Swift port adds bounds checks, truncated-payload handling and flat buffers.
//
// Rendering uses the recovered Apple/Kodak matrix and transfer curve, with
// daylight white balance and an AHD-Lite demosaic based on the adaptive
// homogeneity-directed approach described by Hirakawa and Parks (2005).
//
// Pipeline:
//   QTK header -> QT100 predictor / QT150 RADC decompression -> Bayer samples
//   -> AHD-Lite demosaic -> white balance and colour matrix -> capped brightness
//   -> Kodak transfer curve -> chroma median -> optional NewTake enhancement
//   -> optional second chroma median -> SDR or HDR image.
//
// Vintage and NewTake share the decoding and base colour pipeline. NewTake
// applies EnhancementRecipe.bayer by default; callers can supply another recipe.
// HDR is independent of the selected look. Both outputs receive the same
// post-processing before the SDR quantisation or extended-linear-sRGB HDR tail.

import AppKit
import CoreGraphics

enum BayerPattern: String, CaseIterable, Identifiable {
    case gbrg = "GBRG"
    case rggb = "RGGB"
    case bggr = "BGGR"
    case grbg = "GRBG"

    var id: String { rawValue }
}

/// `nonisolated` for the same reason as `QTKDecoder`: the project-wide
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build setting would
/// otherwise pin this struct (and every `init` / `getBits` / `getBitHuff`
/// call) to the main actor, blocking off-main-thread decoding. The struct
/// is plain value-typed bookkeeping over a `Data` buffer and is
/// actor-agnostic.
nonisolated struct BitReader {
    private let data: Data
    private let allowsPaddedLookahead: Bool
    private var byteOffset: Int
    private var bitBuf: UInt32 = 0
    private var vBits: Int = 0
    /// A required bit or Huffman code was missing, rather than just look-ahead padding.
    private(set) var isExhausted = false

    init(data: Data, offset: Int, allowsPaddedLookahead: Bool = true) {
        self.data = data
        self.byteOffset = offset
        self.allowsPaddedLookahead = allowsPaddedLookahead
    }

    mutating func getBits(_ nbits: Int) -> Int {
        if nbits < 0 {
            bitBuf = 0
            vBits = 0
            isExhausted = false
            return 0
        }
        if nbits == 0 { return 0 }
        if vBits < 0 { return 0 }

        while vBits < nbits && byteOffset < data.count {
            let c = data[byteOffset]
            byteOffset += 1
            bitBuf = (bitBuf << 8) | UInt32(c)
            vBits += 8
        }

        if vBits < nbits {
            vBits = -1
            isExhausted = true
            return 0
        }

        let c = Int((bitBuf << (32 - vBits)) >> (32 - nbits))
        vBits -= nbits
        return c
    }

    mutating func getBitHuff(nbits: Int, huff: [UInt16]) -> Int {
        if nbits < 0 {
            bitBuf = 0
            vBits = 0
            isExhausted = false
            return 0
        }
        if nbits == 0 { return 0 }
        if vBits < 0 { return 0 }

        while vBits < nbits && byteOffset < data.count {
            let c = data[byteOffset]
            byteOffset += 1
            bitBuf = (bitBuf << 8) | UInt32(c)
            vBits += 8
        }

        // Huffman lookup peeks more bits than a short code consumes. At EOF,
        // pad only the lookup index, then require the selected code's real bits.
        if !allowsPaddedLookahead && vBits < nbits {
            vBits = -1
            isExhausted = true
            return 0
        }
        let c = vBits == 0 ? 0 : Int((bitBuf << (32 - vBits)) >> (32 - nbits))
        let huffVal = huff[c]
        let consumed = Int(huffVal >> 8)
        guard consumed > 0, consumed <= vBits else {
            vBits = -1
            isExhausted = true
            return 0
        }
        vBits -= consumed
        return Int(huffVal & 0xFF)
    }
}

/// `nonisolated` overrides the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor` setting so the decoder isn't bound to the main actor.
/// Without it, `Task.detached { QTKDecoder()... }` fails to compile: the
/// implicit `@MainActor` on `init` would require an `await` from the
/// detached closure, defeating the point of decoding off the main thread.
///
/// `@unchecked Sendable` lets the instance cross actor boundaries. Every
/// stored property is a `let` of a Sendable type (`[Double]` and a
/// `(Double, Double, Double)` tuple), so the instance is immutable after
/// `init` and safe to share. Swift's auto-derivation doesn't reach this
/// configuration, hence the explicit `@unchecked`.
// MARK: - EnhancementRecipe

/// The four enhancement steps' constants, so the same chain can be tuned
/// per camera family instead of forked.
///
/// The two families arrive in different states and cannot share numbers.
/// The QTK Bayer decode hands over a comparatively flat render — SwiftTake
/// did the tone mapping, and deliberately did it the way Apple's 1995
/// software did. A QuickTake 200 hands over a finished JPEG the camera
/// already tone-mapped in 1997, so its bright regions sit high in the
/// range before we touch anything.
///
/// Running the Bayer numbers over an already-contrasty JPEG measured at
/// 7.6% of samples clipped to flat white, against 1.8% for the camera's
/// own output. Hence a second recipe rather than one compromise.
nonisolated struct EnhancementRecipe: Sendable {
    let shadowLift: Float
    let shadowKnee: Float
    let clarityRadius: Int
    let clarityAmount: Double
    let sharpenRadius: Int
    let sharpenAmount: Double
    let saturation: Float
    /// How much of the shadow lift preserves colour.
    ///
    /// 0 = the original lift: each channel moves toward white
    ///     independently. Desaturates badly (-49% in shadows) but is
    ///     self-damping — compressing the channels flattens chroma noise
    ///     as a side effect, which is part of why it looked clean.
    /// 1 = pure luminance-ratio gain. Chromaticity preserved exactly, but
    ///     a gain amplifies chroma noise as readily as chroma (+115%).
    ///
    /// Neither end is right. The value is kept as a knob, not baked in, so
    /// the original behaviour remains reachable.
    let shadowChromaPreserve: Float
    /// Shadow GAMMA — the accurate way to brighten. 1.0 = off.
    ///
    /// A lift ADDS brightness, which raises the black floor and squashes
    /// the tonal separation in the dark end: measured on a real frame, the
    /// lift pushed the black point from 0.072 to 0.227 while REDUCING
    /// shadow gradation from 0.038 to 0.028. That is what "destroys the
    /// shadows" means, and no amount of tuning the lift fixes it, because
    /// it is what a lift IS.
    ///
    /// A gamma bends the curve instead. Same frame at 1.25: shadows 53%
    /// brighter and gradation UP to 0.049 — more separation than the
    /// original had, not less.
    ///
    /// Applied to LUMINANCE with RGB scaled by the ratio, so chromaticity
    /// is untouched and saturation stays at 99.7% of the reference. No
    /// boost, no loss — accuracy is the point.
    let shadowGamma: Float
    /// Pulls the black floor back down after the gamma has bent the curve.
    ///
    /// A gamma brightens everything except true zero, so the darkest tone
    /// in the picture rises and some depth goes with it. Subtracting a
    /// small offset and rescaling puts that floor back where PerfectColor
    /// had it, while leaving the opened-up shadows above it opened up.
    /// 0 = off.
    let blackAnchor: Float
    /// Second chroma median after the post-process, to clean what the lift
    /// amplified. Only worth its cost when `shadowChromaPreserve` is high.
    let secondChromaMedian: Bool

    /// QTK Bayer enhancement for QuickTake 100/150.
    ///
    /// Shadow gamma opens dark tones without the additive lift that raises
    /// the black floor. The anchor restores depth; chroma filtering and a
    /// small sharpening pass retain detail without a global saturation boost
    /// or broad clarity halos. Lift, saturation boost and clarity are disabled.
    ///
    /// Gamma 1.45 and anchor 0.08 were selected through image comparisons.
    /// Increasing the anchor beyond roughly 0.085 crushed shadow detail in
    /// the reference scenes. Preserve the decoder baselines when changing
    /// this recipe and inspect actual images as well as numerical results.
    static let bayer = EnhancementRecipe(
        shadowLift: 0.0, shadowKnee: 0.55,
        clarityRadius: 20, clarityAmount: 0.0,
        sharpenRadius: 1,  sharpenAmount: 0.15,
        saturation: 1.0,
        shadowChromaPreserve: 0.35,
        shadowGamma: 1.45,
        blackAnchor: 0.08,
        secondChromaMedian: true)

    /// Finished camera JPEGs (QuickTake 200 / Fujifilm DS-7).
    ///
    /// Chosen by sweeping against a real sunlit QT200 frame, targeting the
    /// most improvement obtainable without turning highlights into flat
    /// white. Clarity is the lever that matters — it is what pushes large
    /// bright regions (concrete, pale clapboard) past white — so it takes
    /// the biggest cut. Shadow lift stays close to full: it acts only
    /// below mid-luma and costs nothing in the highlights.
    /// Swept across 28 real QuickTake 200 frames (means 43 to 136, so
    /// genuinely mixed, not just the sunlit ones), scoring clipped-to-white
    /// against change that SURVIVES — magnitude measured only where the
    /// result did not clip. Effect dumped into a blown highlight is cost
    /// without benefit, and plain mean-delta cannot tell those apart.
    ///
    ///   - CLARITY earns nothing here and is off. Over the whole set,
    ///     0.00 -> 0.30 bought +7% surviving change for +3.4 points of
    ///     clipping. It does not pay on DARK frames either (+3% for +2.5
    ///     points), which is where the first, one-image guess assumed it
    ///     would. Checked by eye too, since a per-pixel metric under-credits
    ///     local contrast: the two renders are near indistinguishable, and
    ///     what difference exists is the building facade going brighter —
    ///     i.e. the clipping itself. A radius-20 unsharp mostly re-does
    ///     tone mapping the camera already did in 1997.
    ///   - SHADOW LIFT held at the Bayer value. The sweep scores higher
    ///     with more, but that metric rewards change, not improvement, and
    ///     a bigger lift mostly buys a milkier picture.
    ///   - SHARPEN is cheap and survives; kept near full.
    ///   - SATURATION eased slightly — the camera already saturated once.
    /// Adopts the graded lift/knee/preserve from `.bayer` — those settle a
    /// mechanism (how to brighten without washing out or speckling), not a
    /// taste, so they carry across. Clarity stays off and saturation stays
    /// at this family's own swept 1.08: both were tuned against 28 real
    /// QT200 frames and no comparable grading has been run here.
    static let finished = EnhancementRecipe(
        shadowLift: 0.20, shadowKnee: 0.55,
        clarityRadius: 20, clarityAmount: 0.0,
        sharpenRadius: 1,  sharpenAmount: 0.22,
        saturation: 1.08,
        shadowChromaPreserve: 0.35,
        shadowGamma: 1.0,
        blackAnchor: 0.0,
        secondChromaMedian: true)
}

nonisolated final class QTKDecoder: @unchecked Sendable {

    // MARK: - Color Science Constants
    //
    // Measured spectral response data for the Kodak KAF-0400 sensor used in
    // both QuickTake 100 and 150. These are the only known laboratory
    // measurements of this sensor's color response.
    //
    // Raw integer coefficients: {21392,-5653,-3353, 2406,8010,-415, 7166,1427,2078}
    // Represents camera_sensor = camXYZ × XYZ_light (maps scene XYZ to sensor response)

    /// Camera sensor → CIE XYZ, the standard "Apple","QuickTake" coefficients.
    private static let camXYZ: [Double] = [
         2.1392, -0.5653, -0.3353,
         0.2406,  0.8010, -0.0415,
         0.7166,  0.1427,  0.2078
    ]

    /// sRGB → CIE XYZ (D65 white point)
    /// Standard IEC 61966-2-1 matrix.
    private static let sRGBToXYZ: [Double] = [
        0.4124564, 0.3575761, 0.1804375,
        0.2126729, 0.7151522, 0.0721750,
        0.0193339, 0.1191920, 0.9503041
    ]

    /// Camera RGB → sRGB matrix, the Kodak factory values from the 1995
    /// Apple/Kodak QuickTake software. The universal fallback matrix used
    /// when the camera EEPROM doesn't supply a per-unit one.
    ///
    /// Row sums are exactly 1.0, so a neutral camera (1,1,1) maps to neutral
    /// sRGB (1,1,1) — Kodak's hand-picked engineering values, not derived
    /// from the `cam_xyz_coeff` recipe. These avoid the over-saturated,
    /// harsh look of the derived matrix (blue diagonal 3.48 vs Kodak's 2.67).
    private static let kodakDefaultRGBCam: [Double] = [
         1.893, -0.418, -0.476,
        -0.495,  1.773, -0.278,
        -1.017, -0.655,  2.672
    ]

    /// Active camera→sRGB matrix: the Kodak-shipped values.
    private let colorMatrix: [Double]

    /// The single canonical 256-entry transfer curve `f(x)` that Apple/Kodak
    /// used in the runtime matrix LUTs. Each LUT entry is
    /// `matrix[i,j] * f(input/255) * 1024`, and the same `f` appears in all
    /// three diagonal entries (R/G/B) within 0.04%.
    ///
    /// Effective gamma varies from ~1.5 in shadows to ~3.0 in mid-highs to
    /// ~1.0 at white, so it is **not** a pure power; it's the measured
    /// CRT-phosphor + camera-sensor combined response from circa 1995.
    /// Stored normalized so `f(0)=0`, `f(255)=65535`.
    static let kodakGammaCurve256: [UInt16] = [
            0,    72,   120,   192,   263,   311,   383,   455,   503,   575,   695,   766,   838,   886,   958,  1030,
         1078,  1150,  1222,  1269,  1341,  1413,  1461,  1533,  1605,  1653,  1725,  1796,  1844,  1916,  2060,  2108,
         2180,  2251,  2299,  2371,  2443,  2491,  2563,  2635,  2683,  2754,  2826,  2874,  2946,  3018,  3066,  3138,
         3210,  3257,  3401,  3449,  3521,  3593,  3641,  3713,  3784,  3832,  3904,  3976,  4024,  4096,  4168,  4216,
         4287,  4359,  4407,  4479,  4551,  4599,  4742,  4790,  4862,  4934,  4982,  5054,  5126,  5174,  5245,  5317,
         5365,  5509,  5629,  5748,  5892,  6012,  6203,  6347,  6467,  6587,  6730,  6850,  7042,  7162,  7305,  7425,
         7545,  7689,  7880,  8000,  8120,  8263,  8383,  8575,  8694,  8838,  8958,  9078,  9221,  9413,  9533,  9653,
         9796,  9916, 10108, 10251, 10371, 10491, 10635, 10754, 10946, 11066, 11209, 11329, 11449, 11593, 11784, 11904,
        12024, 12167, 12287, 12479, 12599, 12742, 12862, 12982, 13126, 13317, 13437, 13557, 13700, 13820, 13940, 14155,
        14275, 14467, 14730, 15042, 15305, 15617, 15880, 16120, 16455, 16694, 16958, 17269, 17533, 17796, 18108, 18371,
        18634, 18946, 19209, 19521, 19784, 20024, 20359, 20598, 20862, 21173, 21437, 21700, 22012, 22275, 22539, 22850,
        23113, 23353, 23688, 23928, 24263, 24503, 24766, 25077, 25341, 25604, 25916, 26179, 26443, 26754, 27018, 27257,
        27592, 27832, 28167, 28407, 28670, 28982, 29245, 29509, 29820, 30083, 30347, 30658, 30922, 31161, 31497, 31736,
        32000, 32502, 33221, 33988, 34682, 35401, 36095, 36790, 37556, 38275, 38969, 39688, 40383, 41149, 41844, 42562,
        43257, 43975, 44670, 45436, 46155, 46850, 47544, 48263, 49029, 49724, 50442, 51137, 51832, 52598, 53317, 54011,
        54730, 55424, 56191, 56885, 57604, 58299, 59017, 59712, 60478, 61173, 61891, 62586, 63304, 64071, 64765, 65460,
    ]

    /// Inverse of `kodakGammaCurve256`: maps a linear input in [0,1] to the
    /// matching encoded byte in [0,255] such that `f(out/255) ≈ in`. Built
    /// once at first use via binary search over `kodakGammaCurve256`. Used
    /// by the vintage PerfectColor path to encode display values through
    /// the *exact* Kodak transfer curve.
    ///
    /// 1024 entries is enough resolution for SDR 8-bit output (each output
    /// byte gets 4 input slots, roughly matches Q.10 fixed-point precision
    /// of the original byte-LUT pipeline).
    static let kodakGammaInverseLUT: [UInt8] = {
        var out = [UInt8](repeating: 0, count: 1024)
        for i in 0..<1024 {
            let target = UInt16(min(65535, i * 64))  // map [0,1024) → [0,65536)
            // Binary-search kodakGammaCurve256 for the smallest index whose
            // value is ≥ target. That index, normalized to [0,255], is the
            // encoded byte.
            var lo = 0, hi = 255
            while lo < hi {
                let mid = (lo + hi) / 2
                if kodakGammaCurve256[mid] < target { lo = mid + 1 } else { hi = mid }
            }
            out[i] = UInt8(lo)
        }
        return out
    }()

    /// Encode a linear value in [0,1] through the Kodak transfer curve,
    /// returning a value in [0,1] suitable for the 8-bit display
    /// quantization step. Lookup-based, so it includes the era-authentic
    /// quantization grain that smoother analytical curves miss.
    @inline(__always)
    fileprivate static func kodakGammaEncode(_ x: Double) -> Double {
        let clamped = max(0.0, min(1.0, x))
        let idx = Int(clamped * 1023.0 + 0.5)
        return Double(kodakGammaInverseLUT[idx]) / 255.0
    }

    /// Slope of the transfer curve at white, used to extend it past 1.0.
    /// Derived from the curve's own top step rather than assumed, so the
    /// extension meets the LUT tangentially instead of kinking at white.
    static let kodakGammaSlopeAtWhite: Double = {
        let linTop  = Double(kodakGammaCurve256[255]) / 65535.0
        let linPrev = Double(kodakGammaCurve256[254]) / 65535.0
        let dLinear = max(1e-6, linTop - linPrev)
        return (1.0 / 255.0) / dLinear
    }()

    /// `kodakGammaEncode`, extended above white.
    ///
    /// At or below 1.0 this is bit-for-bit the LUT path — the era-authentic
    /// quantization grain is the point of that table and is not smoothed
    /// away. Above 1.0 the curve continues along its own slope at white, so
    /// over-range highlights stay ordered and invertible instead of all
    /// collapsing onto white. Only the HDR path ever passes x > 1.
    @inline(__always)
    fileprivate static func kodakGammaEncodeExtended(_ x: Double) -> Double {
        if x <= 1.0 { return kodakGammaEncode(x) }
        return 1.0 + (x - 1.0) * kodakGammaSlopeAtWhite
    }

    /// Inverse of `kodakGammaEncodeExtended`, for getting a processed
    /// display value back to linear so it can be tone-mapped into headroom.
    ///
    /// Interpolates `kodakGammaCurve256` rather than stepping it: the input
    /// here is a *processed* float that no longer sits on the 1/255 grid,
    /// and rounding it to the grid would re-quantize work the float chain
    /// just did. The grain still comes from the encode side.
    @inline(__always)
    fileprivate static func kodakGammaDecodeExtended(_ y: Double) -> Double {
        if y > 1.0 { return 1.0 + (y - 1.0) / kodakGammaSlopeAtWhite }
        if y <= 0.0 { return 0.0 }
        let pos = y * 255.0
        let i = min(254, Int(pos))
        let frac = pos - Double(i)
        let a = Double(kodakGammaCurve256[i])     / 65535.0
        let b = Double(kodakGammaCurve256[i + 1]) / 65535.0
        return a + (b - a) * frac
    }

    /// Camera-matrix-derived daylight white balance multipliers (`pre_mul`),
    /// computed the standard way for cameras with a known color matrix but
    /// no shot-time WB metadata: `pre_mul[i] = 1 / row_sum(camRGB[i,:])`,
    /// then normalized so green = 1.0. For QuickTake this lands very close to
    /// (1, 1, 1) because the RADC stream already applies a per-row, per-channel
    /// `mul[c]` that crudely white-balances the data during compression.
    private let daylightPreMul: (r: Double, g: Double, b: Double)

    /// Blend scene-derived gray-world gains with the fixed daylight gains.
    /// Zero selects daylight gains for both Vintage and NewTake; gray-world
    /// correction overcompensated on the QuickTake reference scenes.
    private static let grayWorldBlendVintage: Double = 0.0

    /// Limit percentile-based brightening in both looks. A full stretch can
    /// amplify RADC quantisation noise and expose four-row stripe patterns.
    private static let autoBrightCapVintage: Double = 1.05
    private static let perfectColorRedBoost:  Double = 1.05   // gentle warm push
    private static let perfectColorBlueBoost: Double = 1.05   // gentle warm push

    nonisolated init() {
        // `colorMatrix` is kept for callers that read it directly.
        colorMatrix = QTKDecoder.kodakDefaultRGBCam
        daylightPreMul = QTKDecoder.computeDaylightPreMul()
    }

    /// Truncates an `Int` to `Int16` range, matching the `short buf[...]`
    /// storage of the reference RADC decoder. The decoder relies on
    /// signed-16-bit wrap-around for predictor arithmetic; without this
    /// truncation the arithmetic silently widens to 64-bit and drifts apart
    /// from the reference in highly compressed regions.
    @inline(__always)
    fileprivate static func toInt16(_ v: Int) -> Int {
        Int(Int16(truncatingIfNeeded: v))
    }

    /// Clamps `Int` to `UInt16` range without trapping. The decompressed
    /// Bayer image is stored as `ushort`, so any negative or overflow values
    /// produced by intermediate arithmetic should saturate, not crash.
    @inline(__always)
    fileprivate static func toUInt16Sat(_ v: Int) -> UInt16 {
        if v <= 0 { return 0 }
        if v >= 0xFFFF { return 0xFFFF }
        return UInt16(v)
    }

    /// Camera-matrix-derived daylight pre-multipliers, following the
    /// `cam_xyz_coeff` rule `pre_mul[i] = 1 / row_sum(camRGB[i,:])` exactly.
    /// Returned normalized so green = 1.0, the standard convention for
    /// `pre_mul`. For QuickTake this lands near (0.89, 1.0, 0.94).
    private static func computeDaylightPreMul() -> (r: Double, g: Double, b: Double) {
        var rowSum = [0.0, 0.0, 0.0]
        for i in 0..<3 {
            for j in 0..<3 {
                var v = 0.0
                for k in 0..<3 {
                    v += camXYZ[i*3 + k] * sRGBToXYZ[k*3 + j]
                }
                rowSum[i] += v
            }
        }
        guard rowSum[0] > 0, rowSum[1] > 0, rowSum[2] > 0 else {
            return (1.0, 1.0, 1.0)
        }
        let preR = 1.0 / rowSum[0]
        let preG = 1.0 / rowSum[1]
        let preB = 1.0 / rowSum[2]
        return (preR / preG, 1.0, preB / preG)
    }

    /// Standard 3×3 matrix inversion via cofactor expansion.
    private static func invert3x3(_ m: [Double]) -> [Double]? {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], k = m[8]

        let det = a*(e*k - f*h) - b*(d*k - f*g) + c*(d*h - e*g)
        guard abs(det) > 1e-10 else { return nil }

        let invDet = 1.0 / det
        return [
            (e*k - f*h) * invDet,  (c*h - b*k) * invDet,  (b*f - c*e) * invDet,
            (f*g - d*k) * invDet,  (a*k - c*g) * invDet,  (c*d - a*f) * invDet,
            (d*h - e*g) * invDet,  (b*g - a*h) * invDet,  (a*e - b*d) * invDet
        ]
    }

    /// Decode a QTK archive with the shared Vintage/NewTake colour pipeline.
    ///
    /// `enhanced` applies the selected enhancement recipe after gamma encoding
    /// and chroma filtering. `hdrEnabled` independently selects Float16 HDR output;
    /// enhancement runs before the HDR/SDR branch. Callers select a compatible
    /// export format. Invalid or incomplete archives return nil.
    nonisolated func decode(
        data: Data,
        enhanced: Bool = true,
        hdrEnabled: Bool = false,
        hdrHeadroom: Double = 1.5,
        recipe: EnhancementRecipe = .bayer
    ) -> NSImage? {
        // The selected look and HDR output range are independent.
        let allowHDR = hdrEnabled

        // Both looks use the recovered Kodak matrix. The retired dcraw-style
        // rendering alternative did not replace the shared dcraw-derived loaders.
        let activeMatrix: [Double] = QTKDecoder.kodakDefaultRGBCam

        // Header fields extend through byte 553. Reject truncation before
        // indexing, and never interpret an unrelated file as QT150 data.
        guard data.count >= 554,
              let magic = String(data: data.prefix(4), encoding: .ascii),
              magic == "qktk" || magic == "qktn" else { return nil }
        let isQT100 = magic == "qktk"
        var height = Int(data[544]) << 8 | Int(data[545])
        var width = Int(data[546]) << 8 | Int(data[547])
        let checkVal = Int(data[552]) << 8 | Int(data[553])
        let dataOffset = checkVal == 30 ? 738 : 736
        guard data.count > dataOffset else { return nil }
        // SwiftTake archives repeat the camera-reported payload length in the
        // reconstructed header. Native QTK headers use these bytes differently.
        let storedLength = Int(data[9]) << 16 | Int(data[10]) << 8 | Int(data[11])
        let repeatedLength = Int(data[15]) << 16 | Int(data[16]) << 8 | Int(data[17])
        let hasStoredLength = dataOffset == 736 && storedLength > 0 && storedLength == repeatedLength
        if hasStoredLength && data.count - dataOffset < storedLength { return nil }
        // Early SwiftTake archives omitted dimensions. Keep their historical
        // fallback only when the complete declared payload is still present.
        let legacyMissingDimensions = !isQT100 && width == 0 && height == 0 && hasStoredLength

        if height > width { swap(&height, &width) }

        // Sanity-clamp the header-supplied dimensions. QuickTake sensors top
        // out at 640×480, and the RADC path's dcraw-inherited stripe buffers
        // are 386 columns wide (valid for width ≤ 770) — a crafted or corrupt
        // header above that would index out of bounds and CRASH on a dropped
        // .qtk file. Anything implausible falls back to the standard HQ frame.
        if width == 0 || height == 0 || width > 768 || height > 768 {
            print("QTKDecoder: Invalid dimensions (\(width)x\(height)). Defaulting to 640x480.")
            width = 640
            height = 480
        }
        // RADC decodes four-pixel-wide groups in four-row stripes. A partial
        // group can drive its predictor column below zero on a corrupt file.
        guard isQT100 || (width.isMultiple(of: 4) && height.isMultiple(of: 4)) else { return nil }

        // 2. Decompress RAW Bayer data
        QTLog.note("DECODE", "decompressing", detail:
            "magic=\(isQT100 ? "qktk" : "qktn") → \(isQT100 ? "QT100 gradient" : "QT150 RADC") "
            + "\(width)x\(height) offset=\(dataOffset) payload=\(max(0, data.count - dataOffset))")
        guard let rawBayer = isQT100
                ? decodeQT100(data: data, offset: dataOffset, width: width, height: height)
                : decodeQT150(data: data, offset: dataOffset, width: width, height: height, allowLegacyExhaustion: legacyMissingDimensions)
        else {
            print("QTKDecoder: Failed to decompress raw Bayer data")
            QTLog.note("DECODE", "DECOMPRESS FAILED")
            return nil
        }

        let maxValue: UInt16 = isQT100 ? 1023 : 16383
        QTLog.frameStats(isQT100 ? "QT100" : "QT150", raw: rawBayer, maxValue: maxValue)

        // 3. White Balance — blended daylight + gray-world.
        //
        // Pure gray-world (dcraw -a) over-corrects on QuickTake because the
        // RADC stream's per-row `mul[c]` already approximates a per-channel
        // pre-balance during compression. Stacking a second per-image WB on
        // top tilts midtones magenta on scenes where the channel means
        // diverge from the daylight reference.
        //
        // The fix is to treat the daylight pre_mul (matrix-derived, fixed)
        // as the baseline — like `dcraw -w` for cameras with WB metadata —
        // and blend in only `grayWorldBlend` worth of scene adaptation.
        let gw = grayWorldWB(raw: rawBayer, width: width, height: height, maxValue: maxValue)
        let dl = daylightPreMul
        // Pure daylight WB, matching the 1995 software, which did not
        // gray-world correct.
        let blend = QTKDecoder.grayWorldBlendVintage
        var wbR = (1.0 - blend) * dl.r + blend * gw.r
        var wbG = (1.0 - blend) * dl.g + blend * gw.g
        var wbB = (1.0 - blend) * dl.b + blend * gw.b

        // Normalize: smallest multiplier = 1.0 (matches dcraw highlight=0)
        let minWB = min(wbR, min(wbG, wbB))
        if minWB > 0 {
            wbR /= minWB
            wbG /= minWB
            wbB /= minWB
        }
        // Small R/B gains were tuned against the vintage reference render.
        // Keep the values in the named constants rather than duplicating them here.
        wbR *= QTKDecoder.perfectColorRedBoost
        wbB *= QTKDecoder.perfectColorBlueBoost

        // 4. AHD-Lite reconstructs green along the lower-variance axis;
        // red and blue use the shared demosaic's chroma reconstruction.
        let fMaxValue = Double(maxValue)
        let (linearR, linearG, linearB) =
            demosaicAHDLite(raw: rawBayer, width: width, height: height, fMaxValue: fMaxValue)
        // 5. White Balance → Color Matrix → Hard Clip
        let pixelCount = width * height
        var linearOut = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: pixelCount)

        for i in 0..<pixelCount {
            let r = linearR[i] * wbR
            let g = linearG[i] * wbG
            let b = linearB[i] * wbB

            let outR = max(0.0, r * activeMatrix[0] + g * activeMatrix[1] + b * activeMatrix[2])
            let outG = max(0.0, r * activeMatrix[3] + g * activeMatrix[4] + b * activeMatrix[5])
            let outB = max(0.0, r * activeMatrix[6] + g * activeMatrix[7] + b * activeMatrix[8])
            linearOut[i] = (outR, outG, outB)
        }

        // 6. Auto-brightness: find 99th percentile, map it to white (matches dcraw default).
        //    Capped so that under-exposed scenes don't get amplified into noise.
        let perc = pixelCount / 100
        var histogram = [Int](repeating: 0, count: 8192)
        for i in 0..<pixelCount {
            let maxChan = max(linearOut[i].r, max(linearOut[i].g, linearOut[i].b))
            let bin = min(8191, Int(maxChan * 8191.0))
            histogram[bin] += 1
        }
        var white = 8191
        var total = 0
        while white > 32 {
            total += histogram[white]
            if total > perc { break }
            white -= 1
        }
        let rawScale = 8191.0 / Double(max(1, white))
        // Both looks cap the percentile-derived gain at autoBrightCapVintage
        // so dark scenes retain their exposure instead of being fully stretched.
        let autoBrightCap = QTKDecoder.autoBrightCapVintage
        let autoBrightScale = min(autoBrightCap, rawScale)

        // 7. Encode through the Kodak transfer curve in float precision.
        // HDR retains values above white until the output stage. SDR clips the
        // linear input to 1.0 and quantises only after shared post-processing.
        var rgb = [Float](repeating: 0, count: pixelCount * 3)

        // SDR still clips highlights before the curve, exactly as it did.
        // HDR must not: the values above white ARE the headroom, and
        // clipping them here is what left nothing for the tone map to do.
        // Same chain either way — only what it is fed differs.
        for i in 0..<pixelCount {
            let ceiling = allowHDR ? Double.infinity : 1.0
            let r = min(ceiling, linearOut[i].r * autoBrightScale)
            let g = min(ceiling, linearOut[i].g * autoBrightScale)
            let b = min(ceiling, linearOut[i].b * autoBrightScale)

            // The recovered Kodak transfer curve, for vintage and enhanced
            // alike — which is what keeps midtone contrast identical between
            // the two.
            rgb[i*3]     = Float(QTKDecoder.kodakGammaEncodeExtended(max(0.0, r)))
            rgb[i*3 + 1] = Float(QTKDecoder.kodakGammaEncodeExtended(max(0.0, g)))
            rgb[i*3 + 2] = Float(QTKDecoder.kodakGammaEncodeExtended(max(0.0, b)))
        }

        // 7b. Both looks remove demosaic chroma residue. NewTake then applies
        // the current recipe, evolved from SwiftTake's early Python prototype.
        rgb = chromaMedian3x3(rgb, width: width, height: height)

        if enhanced {
            rgb = QTKDecoder.applyEnhancement(rgb, width: width, height: height, recipe: recipe)
        }

        // 7c. A recipe can request a second median pass to reduce chroma noise
        // amplified by enhancement. Vintage skips this additional pass.
        if enhanced && recipe.secondChromaMedian {
            rgb = chromaMedian3x3(rgb, width: width, height: height)
        }

        // 8. Select the output representation after the shared post-processing.
        if allowHDR {
            return renderHDRImage(encoded: rgb, width: width, height: height,
                                  headroom: max(1.0, hdrHeadroom))
        }

        // 9. Quantise to 8-bit RGBA — the single clamp in the chain — and
        //    hand off as a CGImage. Clamping in Float before the integer
        //    conversion also keeps a stray NaN or overflow from trapping.
        var rgbaData = [UInt8](repeating: 255, count: pixelCount * 4)
        for i in 0..<pixelCount {
            rgbaData[i*4]     = UInt8(max(0, min(255, rgb[i*3]     * 255)))
            rgbaData[i*4 + 1] = UInt8(max(0, min(255, rgb[i*3 + 1] * 255)))
            rgbaData[i*4 + 2] = UInt8(max(0, min(255, rgb[i*3 + 2] * 255)))
        }
        return renderToImage(rgbaData: rgbaData, width: width, height: height)
    }

    // MARK: - Enhanced post-process

    /// `full_pop` chain: shadows lift → clarity → sharpen → saturation.
    /// Operates on gamma-encoded float RGB, 3 components per pixel.
    ///
    /// Static and shared, because the QT200 family needs exactly this and a
    /// second copy of these four steps is how Enhanced came to be silently
    /// skipped in HDR. Nothing here is Kodak-specific — the steps are
    /// perceptual-domain and scale-invariant, so they work on any
    /// gamma-encoded RGB. Only the TRANSFER CURVE differs between families:
    /// Kodak's for the QTK Bayer decode, sRGB for the QT200's finished
    /// JPEGs.
    ///
    /// Float rather than 8-bit because this chain also feeds the HDR
    /// output. Nothing here clamps at the top — the SDR quantise does that
    /// once, at the end — so a highlight pushed above white survives to
    /// become headroom instead of being flattened to white here.
    static func applyEnhancement(
        _ rgb: [Float], width: Int, height: Int,
        recipe: EnhancementRecipe = .bayer
    ) -> [Float] {
        var img = rgb
        if recipe.shadowGamma != 1.0 {
            img = enhancementShadowGamma(img, gamma: recipe.shadowGamma,
                                         blackAnchor: recipe.blackAnchor)
        }
        if recipe.shadowLift != 0 {
            img = enhancementShadowsLift(img, lift: recipe.shadowLift, knee: recipe.shadowKnee,
                                         preserve: recipe.shadowChromaPreserve)
        }
        // Skipped, not multiplied by zero: the radius-20 pass is the most
        // expensive step in the chain, and the finished-image recipe sets
        // it to zero.
        if recipe.clarityAmount != 0 {
            img = enhancementUnsharp(img, width: width, height: height,
                                     radius: recipe.clarityRadius, amount: recipe.clarityAmount)
        }
        if recipe.sharpenAmount != 0 {
            img = enhancementUnsharp(img, width: width, height: height,
                                     radius: recipe.sharpenRadius, amount: recipe.sharpenAmount)
        }
        img = enhancementSaturation(img, factor: recipe.saturation)
        return img
    }

    /// Brightens by bending the tone curve rather than adding to it.
    ///
    /// The whole picture passes through `L^(1/gamma)`, which lifts the dark
    /// end hardest and the highlights barely at all — no knee needed, and
    /// no discontinuity to tune. Crucially it EXPANDS the shadows rather
    /// than compressing them: a lift squashes everything toward its
    /// ceiling, a gamma stretches the dark end apart.
    ///
    /// Operates on luminance with RGB scaled by the ratio, so R:G:B is
    /// untouched and the colour is exactly as accurate as the reference.
    private static func enhancementShadowGamma(_ rgb: [Float], gamma: Float,
                                               blackAnchor: Float) -> [Float] {
        var out = rgb
        let inv = 1.0 / gamma
        let a = max(0, min(0.5, blackAnchor))
        let n = rgb.count / 3
        for i in 0..<n {
            let R = rgb[i*3], G = rgb[i*3 + 1], B = rgb[i*3 + 2]
            let L = 0.299*R + 0.587*G + 0.114*B
            guard L > 1e-4 else { continue }
            var target = powf(L, inv)
            if a > 0 { target = max(0, (target - a) / (1 - a)) }
            let scale = target / L
            out[i*3]     = R * scale
            out[i*3 + 1] = G * scale
            out[i*3 + 2] = B * scale
        }
        return out
    }

    /// Lifts darker pixels WITHOUT washing the colour out of them.
    /// Strongest at L=0, fading to nothing at `knee`, so highlights are
    /// untouched.
    ///
    /// This used to move each channel toward white independently:
    ///
    ///     out = C + lift * factor * (1 - C)
    ///
    /// which desaturates by construction. A channel already near white has
    /// less distance left to travel, so the three converge and a dark
    /// saturated colour loses its colour as it brightens. Measured on a real
    /// frame: shadow saturation fell 49%, while midtones and highlights —
    /// which the lift never touches — gained the intended 15% from the
    /// saturation step. All the wash-out was here.
    ///
    /// Instead, compute the target LUMINANCE and scale RGB by the ratio. A
    /// common multiplier leaves R:G:B untouched, so chromaticity is exactly
    /// preserved: the same brightening now costs no colour at all (100%
    /// retention measured), at the same shadow grain as the untouched
    /// PerfectColor render.
    private static func enhancementShadowsLift(
        _ rgb: [Float], lift: Float, knee: Float, preserve: Float
    ) -> [Float] {
        var out = rgb
        let n = rgb.count / 3
        for i in 0..<n {
            let R = rgb[i*3], G = rgb[i*3 + 1], B = rgb[i*3 + 2]
            let L = 0.299*R + 0.587*G + 0.114*B
            let factor = max(0, min(1, (knee - L) / knee))
            // Near-black has no colour to preserve and an unstable ratio.
            guard factor > 0 else { continue }
            guard L > 1e-3 else {
                // No colour to preserve and an unstable ratio — the
                // toward-white term is all that is meaningful here.
                out[i*3]     = R + lift * factor * (1 - R)
                out[i*3 + 1] = G + lift * factor * (1 - G)
                out[i*3 + 2] = B + lift * factor * (1 - B)
                continue
            }
            let target = L + lift * factor * (1 - L)
            // The cap stops the ratio running away as L approaches zero. 3
            // barely binds on real frames; a TIGHTER cap measured as MORE
            // shadow grain, not less, because clamping draws a visible
            // boundary between scaled and clamped pixels.
            let scale = min(3.0, target / L)
            let k = preserve
            // Blend the two lifts per channel: the gain keeps the colour,
            // the toward-white term damps the noise the gain would raise.
            out[i*3]     = k * (R * scale) + (1 - k) * (R + lift * factor * (1 - R))
            out[i*3 + 1] = k * (G * scale) + (1 - k) * (G + lift * factor * (1 - G))
            out[i*3 + 2] = k * (B * scale) + (1 - k) * (B + lift * factor * (1 - B))
        }
        return out
    }

    /// Unsharp mask: subtract blurred from original, scale, add back.
    /// `radius` is the box-blur radius (large = clarity / local contrast,
    /// small = edge sharpness). `amount` controls the strength.
    ///
    /// Blurs in Double to match `boxBlur2D`, which the 8-bit version also
    /// did — the running-sum blur wants the wider mantissa.
    private static func enhancementUnsharp(
        _ rgb: [Float], width: Int, height: Int, radius: Int, amount: Double
    ) -> [Float] {
        let n = width * height
        var R = [Double](repeating: 0, count: n)
        var G = [Double](repeating: 0, count: n)
        var B = [Double](repeating: 0, count: n)
        for i in 0..<n {
            R[i] = Double(rgb[i*3])
            G[i] = Double(rgb[i*3 + 1])
            B[i] = Double(rgb[i*3 + 2])
        }
        let Rb = boxBlur2D(R, width: width, height: height, radiusH: radius, radiusV: radius)
        let Gb = boxBlur2D(G, width: width, height: height, radiusH: radius, radiusV: radius)
        let Bb = boxBlur2D(B, width: width, height: height, radiusH: radius, radiusV: radius)
        var out = rgb
        for i in 0..<n {
            out[i*3]     = Float(R[i] + amount * (R[i] - Rb[i]))
            out[i*3 + 1] = Float(G[i] + amount * (G[i] - Gb[i]))
            out[i*3 + 2] = Float(B[i] + amount * (B[i] - Bb[i]))
        }
        return out
    }

    /// Saturation = Y + factor × (channel − Y). 1.0 = no change,
    /// 1.15 = +15% colour boost.
    private static func enhancementSaturation(
        _ rgb: [Float], factor: Float
    ) -> [Float] {
        var out = rgb
        let n = rgb.count / 3
        for i in 0..<n {
            let R = rgb[i*3], G = rgb[i*3 + 1], B = rgb[i*3 + 2]
            let Y = 0.299*R + 0.587*G + 0.114*B
            out[i*3]     = Y + factor * (R - Y)
            out[i*3 + 1] = Y + factor * (G - Y)
            out[i*3 + 2] = Y + factor * (B - Y)
        }
        return out
    }

    // MARK: - Chroma median post-process

    /// 3×3 median filter on the (R−G) and (B−G) chroma deltas. Operates
    /// on gamma-encoded float RGB (nominally 0...1, may exceed it).
    /// Median (vs box blur) preserves real chroma edges while killing
    /// isolated demosaic-residue outliers — the same trick consumer-camera
    /// ISPs from the late '90s onwards used to clean up cyan fringes.
    private func chromaMedian3x3(
        _ rgb: [Float], width: Int, height: Int
    ) -> [Float] {
        let n = width * height
        var dR = [Float](repeating: 0, count: n)
        var dB = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let R = rgb[i*3], G = rgb[i*3 + 1], B = rgb[i*3 + 2]
            dR[i] = R - G
            dB[i] = B - G
        }
        var out = rgb
        var window = [Float](); window.reserveCapacity(9)
        for y in 0..<height {
            let yLo = max(0, y - 1)
            let yHi = min(height - 1, y + 1)
            for x in 0..<width {
                let xLo = max(0, x - 1)
                let xHi = min(width - 1, x + 1)
                let G = rgb[(y * width + x) * 3 + 1]

                // Median of dR
                window.removeAll(keepingCapacity: true)
                for yy in yLo...yHi {
                    for xx in xLo...xHi {
                        window.append(dR[yy * width + xx])
                    }
                }
                window.sort()
                let dRm = window[window.count / 2]

                // Median of dB
                window.removeAll(keepingCapacity: true)
                for yy in yLo...yHi {
                    for xx in xLo...xHi {
                        window.append(dB[yy * width + xx])
                    }
                }
                window.sort()
                let dBm = window[window.count / 2]

                // Low clamp only. The old 8-bit version also clipped at
                // white here; that ceiling is what the HDR path must not
                // have, and the SDR quantise applies it anyway.
                let i = y * width + x
                out[i*3]     = max(0, G + dRm)
                out[i*3 + 2] = max(0, G + dBm)
            }
        }
        return out
    }

    // MARK: - PerfectColor Helpers

    /// Gray-world auto white balance, following dcraw's `-a` algorithm.
    /// Processes the raw Bayer data in 8×8 blocks, skipping any block that
    /// contains a near-saturated pixel (which would skew the average).
    /// Returns multipliers normalized so green = 1.0.
    private func grayWorldWB(raw: [UInt16], width: Int, height: Int, maxValue: UInt16) -> (r: Double, g: Double, b: Double) {
        let satThreshold = Int(maxValue) - 25  // dcraw's saturation margin

        // Accumulate per-channel sums across the whole image
        var channelSum  = [0.0, 0.0, 0.0, 0.0]  // R, G_in_GR_row, G_in_BG_row, B
        var channelCount = [0.0, 0.0, 0.0, 0.0]

        for blockY in stride(from: 0, to: height, by: 8) {
            for blockX in stride(from: 0, to: width, by: 8) {
                var blockSum   = [0.0, 0.0, 0.0, 0.0]
                var blockCount = [0.0, 0.0, 0.0, 0.0]
                var saturated = false

                blockLoop: for y in blockY..<min(blockY + 8, height) {
                    for x in blockX..<min(blockX + 8, width) {
                        let val = Int(raw[y * width + x])
                        if val > satThreshold { saturated = true; break blockLoop }

                        // GRBG: row0=[G,R,G,R...], row1=[B,G,B,G...]
                        let ch: Int
                        if y % 2 == 0 {
                            ch = (x % 2 == 0) ? 1 : 0   // G1 or R
                        } else {
                            ch = (x % 2 == 0) ? 3 : 2    // B or G2
                        }
                        blockSum[ch] += Double(val)
                        blockCount[ch] += 1
                    }
                }

                if !saturated {
                    for c in 0..<4 {
                        channelSum[c]  += blockSum[c]
                        channelCount[c] += blockCount[c]
                    }
                }
            }
        }

        // Average each channel (combine both green sub-channels)
        let avgR = channelCount[0] > 0 ? channelSum[0] / channelCount[0] : 1.0
        let avgG = (channelCount[1] + channelCount[2]) > 0
            ? (channelSum[1] + channelSum[2]) / (channelCount[1] + channelCount[2]) : 1.0
        let avgB = channelCount[3] > 0 ? channelSum[3] / channelCount[3] : 1.0

        guard avgR > 0, avgG > 0, avgB > 0 else { return (1.0, 1.0, 1.0) }

        // Normalize so green multiplier = 1.0
        return (avgG / avgR, 1.0, avgG / avgB)
    }

    // MARK: - Native QuickTake Decoders

    private func decodeQT100(data: Data, offset: Int, width: Int, height: Int) -> [UInt16]? {
        var reader = BitReader(data: data, offset: offset)

        let gstep: [Int] = [-89,-60,-44,-32,-22,-15,-8,-2,2,8,15,22,32,44,60,89]
        let rstep: [[Int]] = [
            [  -3,-1,1,3  ], [  -5,-1,1,5  ], [  -8,-2,2,8  ],
            [ -13,-3,3,13 ], [ -19,-4,4,19 ], [ -28,-6,6,28 ]
        ]
        let curve: [UInt16] = [
            0,1,2,3,4,5,6,7,8,9,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,
            28,29,30,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,53,
            54,55,56,57,58,59,60,61,62,63,64,65,66,67,68,69,70,71,72,74,75,76,77,78,
            79,80,81,82,83,84,86,88,90,92,94,97,99,101,103,105,107,110,112,114,116,
            118,120,123,125,127,129,131,134,136,138,140,142,144,147,149,151,153,155,
            158,160,162,164,166,168,171,173,175,177,179,181,184,186,188,190,192,195,
            197,199,201,203,205,208,210,212,214,216,218,221,223,226,230,235,239,244,
            248,252,257,261,265,270,274,278,283,287,291,296,300,305,309,313,318,322,
            326,331,335,339,344,348,352,357,361,365,370,374,379,383,387,392,396,400,
            405,409,413,418,422,426,431,435,440,444,448,453,457,461,466,470,474,479,
            483,487,492,496,500,508,519,531,542,553,564,575,587,598,609,620,631,643,
            654,665,676,687,698,710,721,732,743,754,766,777,788,799,810,822,833,844,
            855,866,878,889,900,911,922,933,945,956,967,978,989,1001,1012,1023
        ]

        let pHeight = height + 4
        let pWidth = width + 4
        // FLAT 1-D grid (row * pWidth + col). The nested [[Int]] version paid
        // double indirection + retain/release on every access in the hottest
        // loops. Indexing is mechanical; the arithmetic is untouched and the
        // output is hash-verified bit-identical to the nested version.
        var pixel = [Int](repeating: 0x80, count: pHeight * pWidth)

        _ = reader.getBits(-1)

        for row in 2..<(height+2) {
            let startCol = 2 + (row & 1)
            var lastVal = 0
            var finalCol = startCol
            for col in stride(from: startCol, to: width+2, by: 2) {
                var val = ((pixel[(row-1) * pWidth + (col-1)] + 2*pixel[(row-1) * pWidth + (col+1)] + pixel[(row) * pWidth + (col-2)]) >> 2) + gstep[reader.getBits(4)]
                val = Swift.max(0, Swift.min(255, val))
                pixel[(row) * pWidth + (col)] = val
                if col < 4 {
                    pixel[(row) * pWidth + (col-2)] = val
                    pixel[(row+1) * pWidth + ((~row) & 1)] = val
                }
                if row == 2 {
                    pixel[(row-1) * pWidth + (col+1)] = val
                    pixel[(row-1) * pWidth + (col+3)] = val
                }
                lastVal = val
                finalCol = col
            }
            finalCol += 2
            if finalCol < pWidth {
                pixel[(row) * pWidth + (finalCol)] = lastVal
            }
        }

        for rb in 0..<2 {
            for row in stride(from: 2+rb, to: height+2, by: 2) {
                for col in stride(from: 3-(row & 1), to: width+2, by: 2) {
                    var sharp = 2
                    if row < 4 || col < 4 {
                        sharp = 2
                    } else {
                        let valDiff = abs(pixel[(row-2) * pWidth + (col)] - pixel[(row) * pWidth + (col-2)]) + abs(pixel[(row-2) * pWidth + (col)] - pixel[(row-2) * pWidth + (col-2)]) + abs(pixel[(row) * pWidth + (col-2)] - pixel[(row-2) * pWidth + (col-2)])
                        if valDiff < 4 { sharp = 0 }
                        else if valDiff < 8 { sharp = 1 }
                        else if valDiff < 16 { sharp = 2 }
                        else if valDiff < 32 { sharp = 3 }
                        else if valDiff < 48 { sharp = 4 }
                        else { sharp = 5 }
                    }
                    var val = ((pixel[(row-2) * pWidth + (col)] + pixel[(row) * pWidth + (col-2)]) >> 1) + rstep[sharp][reader.getBits(2)]
                    val = Swift.max(0, Swift.min(255, val))
                    pixel[(row) * pWidth + (col)] = val
                    if row < 4 { pixel[(row-2) * pWidth + (col+2)] = val }
                    if col < 4 { pixel[(row+2) * pWidth + (col-2)] = val }
                }
            }
        }

        for row in 2..<(height+2) {
            for col in stride(from: 3-(row & 1), to: width+2, by: 2) {
                var val = ((pixel[(row) * pWidth + (col-1)] + (pixel[(row) * pWidth + (col)] << 2) + pixel[(row) * pWidth + (col+1)]) >> 1) - 0x100
                val = Swift.max(0, Swift.min(255, val))
                pixel[(row) * pWidth + (col)] = val
            }
        }

        var rawImage = [UInt16](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                rawImage[row * width + col] = curve[pixel[(row+2) * pWidth + (col+2)]]
            }
        }
        guard !reader.isExhausted else { return nil }
        return rawImage
    }

    private func decodeQT150(data: Data, offset: Int, width: Int, height: Int, allowLegacyExhaustion: Bool = false) -> [UInt16]? {
        // Preserve the historical pixels of dimensionless archives, including
        // their old EOF lookup behavior. Normal images use exact code lengths.
        var reader = BitReader(data: data, offset: offset, allowsPaddedLookahead: !allowLegacyExhaustion)

        let src: [Int8] = [
            1,1, 2,3, 3,4, 4,2, 5,7, 6,5, 7,6, 7,8,
            1,0, 2,1, 3,3, 4,4, 5,2, 6,7, 7,6, 8,5, 8,8,
            2,1, 2,3, 3,0, 3,2, 3,4, 4,6, 5,5, 6,7, 6,8,
            2,0, 2,1, 2,3, 3,2, 4,4, 5,6, 6,7, 7,5, 7,8,
            2,1, 2,4, 3,0, 3,2, 3,3, 4,7, 5,5, 6,6, 6,8,
            2,3, 3,1, 3,2, 3,4, 3,5, 3,6, 4,7, 5,0, 5,8,
            2,3, 2,6, 3,0, 3,1, 4,4, 4,5, 4,7, 5,2, 5,8,
            2,4, 2,7, 3,3, 3,6, 4,1, 4,2, 4,5, 5,0, 5,8,
            2,6, 3,1, 3,3, 3,5, 3,7, 3,8, 4,0, 5,2, 5,4,
            2,0, 2,1, 3,2, 3,3, 4,4, 4,5, 5,6, 5,7, 4,8,
            1,0, 2,2, 2,-2,
            1,-3, 1,3,
            2,-17, 2,-5, 2,5, 2,17,
            2,-7, 2,2, 2,9, 2,18,
            2,-18, 2,-9, 2,-2, 2,7,
            2,-28, 2,28, 3,-49, 3,-9, 3,9, 4,49, 5,-79, 5,79,
            2,-1, 2,13, 2,26, 3,39, 4,-16, 5,55, 6,-37, 6,76,
            2,-26, 2,-13, 2,1, 3,-39, 4,16, 5,-55, 6,-76, 6,37
        ]

        var huff = [[UInt16]](repeating: [UInt16](repeating: 0, count: 256), count: 19)
        var s = 0
        var i = 0
        while i < src.count {
            let bits = Int(src[i])
            let val = src[i+1]
            let count = 256 >> bits
            for _ in 0..<count {
                huff[s / 256][s % 256] = UInt16(bits) << 8 | UInt16(UInt8(bitPattern: val))
                s += 1
            }
            i += 2
        }

        let s_val = 3
        for c in 0..<256 {
            huff[18][c] = UInt16((8 - s_val) << 8 | ((c >> s_val) << s_val) | (1 << (s_val - 1)))
        }

        let pt: [UInt16] = [0,0, 1280,1344, 2320,3616, 3328,8000, 4095,16383, 65535,16383]
        var curve = [UInt16](repeating: 0, count: 65536)

        var ptIdx = 2
        while ptIdx < 12 {
            let start = Int(pt[ptIdx-2])
            let end = Int(pt[ptIdx])
            for c in start...end {
                let rangeX = Double(pt[ptIdx] - pt[ptIdx-2])
                let rangeY = Double(pt[ptIdx+1] - pt[ptIdx-1])
                let v = Double(c - start) / rangeX * rangeY + Double(pt[ptIdx-1]) + 0.5
                curve[c] = UInt16(v)
            }
            ptIdx += 2
        }

        _ = reader.getBits(-1)

        // FLAT 1-D stripe buffer, index ((c * 3 + y) * 386 + x) — dcraw's
        // short buf[((3) * 3 + (3)) * 386 + (386)] laid out row-major. Same flattening as the
        // Kodak RADC copy; hash-verified bit-identical to the nested form.
        var buf = [Int](repeating: 2048, count: 3 * 3 * 386)
        var last = [16, 16, 16]
        var mul = [0, 0, 0]
        var rawImage = [UInt16](repeating: 0, count: width * height)

        for row in stride(from: 0, to: height, by: 4) {
            for c in 0..<3 { mul[c] = reader.getBits(6) }
            for c in 0..<3 {
                // max(1, ...): a corrupt/crafted stream can deliver mul[c] == 0,
                // making last[c] zero on the NEXT stripe and this line a
                // divide-by-zero CRASH (found by the decoder fuzz harness).
                // Real camera streams never emit mul == 0, so this changes
                // nothing for genuine photos (hash-verified).
                var val = ((0x1000000 / max(1, last[c]) + 0x7ff) >> 12) * mul[c]
                let ss = val > 65564 ? 10 : 12
                let x = ~(-1 << (ss - 1))
                val <<= (12 - ss)
                for bufIdx in 0..<3 {
                    for j in 0..<386 {
                        buf[((c) * 3 + (bufIdx)) * 386 + (j)] = QTKDecoder.toInt16((buf[((c) * 3 + (bufIdx)) * 386 + (j)] * val + x) >> ss)
                    }
                }
                last[c] = mul[c]

                let limitR = (c == 0) ? 1 : 0
                for r in 0...limitR {
                    buf[((c) * 3 + (1)) * 386 + (width/2)] = mul[c] << 7
                    buf[((c) * 3 + (2)) * 386 + (width/2)] = mul[c] << 7

                    var tree = 1
                    var col = width / 2
                    while col > 0 {
                        tree = Int(Int8(bitPattern: UInt8(reader.getBitHuff(nbits: 8, huff: huff[tree]))))
                        if tree != 0 {
                            col -= 2
                            if tree == 8 {
                                // dcraw: `(uchar) radc_token(18) * mul[c]` — the (uchar) cast
                                // re-widens the signed-char token back to its 0..255 unsigned
                                // byte value before multiplying by mul[c]. Treating it as signed
                                // (Int8) here produced negative buf entries that turned into
                                // black/saturated patches in highly compressed regions.
                                for y in 1..<3 {
                                    for x in (col...col+1).reversed() {
                                        let token = reader.getBitHuff(nbits: 8, huff: huff[18]) & 0xFF
                                        buf[((c) * 3 + (y)) * 386 + (x)] = QTKDecoder.toInt16(token * mul[c])
                                    }
                                }
                            } else {
                                for y in 1..<3 {
                                    for x in (col...col+1).reversed() {
                                        let predictor = c != 0 ? (buf[((c) * 3 + (y-1)) * 386 + (x)] + buf[((c) * 3 + (y)) * 386 + (x+1)]) / 2 : (buf[((c) * 3 + (y-1)) * 386 + (x+1)] + 2 * buf[((c) * 3 + (y-1)) * 386 + (x)] + buf[((c) * 3 + (y)) * 386 + (x+1)]) / 4
                                        let token = Int(Int8(bitPattern: UInt8(reader.getBitHuff(nbits: 8, huff: huff[tree+10]))))
                                        buf[((c) * 3 + (y)) * 386 + (x)] = QTKDecoder.toInt16(token * 16 + predictor)
                                    }
                                }
                            }
                        } else {
                            var nreps = 1
                            repeat {
                                nreps = (col > 2) ? Int(Int8(bitPattern: UInt8(reader.getBitHuff(nbits: 8, huff: huff[9])))) + 1 : 1
                                var rep = 0
                                while rep < 8 && rep < nreps && col > 0 {
                                    col -= 2
                                    for y in 1..<3 {
                                        for x in (col...col+1).reversed() {
                                            let predictor = c != 0 ? (buf[((c) * 3 + (y-1)) * 386 + (x)] + buf[((c) * 3 + (y)) * 386 + (x+1)]) / 2 : (buf[((c) * 3 + (y-1)) * 386 + (x+1)] + 2 * buf[((c) * 3 + (y-1)) * 386 + (x)] + buf[((c) * 3 + (y)) * 386 + (x+1)]) / 4
                                            buf[((c) * 3 + (y)) * 386 + (x)] = predictor
                                        }
                                    }
                                    if rep % 2 == 1 {
                                        let step = Int(Int8(bitPattern: UInt8(reader.getBitHuff(nbits: 8, huff: huff[10])))) << 4
                                        for y in 1..<3 {
                                            for x in (col...col+1).reversed() {
                                                buf[((c) * 3 + (y)) * 386 + (x)] = QTKDecoder.toInt16(buf[((c) * 3 + (y)) * 386 + (x)] + step)
                                            }
                                        }
                                    }
                                    rep += 1
                                }
                            } while nreps == 9
                        }
                    }

                    for y in 0..<2 {
                        for x in 0..<width/2 {
                            var bVal = (buf[((c) * 3 + (y+1)) * 386 + (x)] << 4)
                            if mul[c] != 0 {
                                bVal /= mul[c]
                            }
                            if bVal < 0 { bVal = 0 }

                            if c != 0 {
                                let yy = row + y*2 + c - 1
                                let xx = x*2 + 2 - c
                                if yy < height && xx < width {
                                    rawImage[yy * width + xx] = QTKDecoder.toUInt16Sat(bVal)
                                }
                            } else {
                                let yy = row + r*2 + y
                                let xx = x*2 + y
                                if yy < height && xx < width {
                                    rawImage[yy * width + xx] = QTKDecoder.toUInt16Sat(bVal)
                                }
                            }
                        }
                    }

                    if c == 0 {
                        // dcraw: memcpy(buf[c][0]+1, buf[c][2], sizeof(buf[c][0])-2)
                        // Copy row 2 into row 0 starting at index 1 (385 elements)
                        for idx in 0..<385 {
                            buf[((0) * 3 + (0)) * 386 + (idx + 1)] = buf[((0) * 3 + (2)) * 386 + (idx)]
                        }
                    } else {
                        for j in 0..<386 {
                            buf[(c * 3 + 0) * 386 + j] = buf[(c * 3 + 2) * 386 + j]
                        }
                    }
                }
            }

            for y in row..<row+4 {
                if y >= height { continue }
                for x in 0..<width {
                    if (x + y) % 2 == 1 {
                        let rr = x != 0 ? x - 1 : x + 1
                        let s = x + 1 < width ? x + 1 : x - 1
                        let rVal = rawImage[y * width + rr]
                        let sVal = rawImage[y * width + s]
                        let bVal = (Int(rawImage[y * width + x]) - 2048) * 2 + (Int(rVal) + Int(sVal)) / 2
                        rawImage[y * width + x] = QTKDecoder.toUInt16Sat(bVal)
                    }
                }
            }

            if reader.isExhausted && !allowLegacyExhaustion { return nil }
        }

        for i in 0..<(height * width) {
            rawImage[i] = curve[Int(rawImage[i])]
        }

        return rawImage
    }


    // MARK: - Demosaic (AHDLite — adaptive horizontal/vertical green)

    /// AHDlite demosaic — at each R/B site, the green channel is
    /// reconstructed by picking *between* a horizontal and a vertical
    /// gradient-corrected estimate based on which axis has lower local
    /// variance. R/B at G sites use bilinear axis averages, R/B at the
    /// opposite-channel site uses a 4-corner diagonal average.
    ///
    /// Ported from SwiftTake's Python `demosaic_ahd_lite` prototype. The
    /// rendering pipeline follows this stage with a 3×3 chroma median.
    ///
    /// GRBG layout:
    ///   row 0 (R-row): G R G R …
    ///   row 1 (B-row): B G B G …
    private func demosaicAHDLite(
        raw: [UInt16], width: Int, height: Int, fMaxValue: Double
    ) -> (R: [Double], G: [Double], B: [Double]) {
        return _demosaicShared(raw: raw, width: width, height: height, fMaxValue: fMaxValue, useAdaptiveG: true)
    }

    /// Shared demosaic body that's bilinear when `useAdaptiveG == false`
    /// and AHDlite when `true`. Same axis/cross/diagonal helper layout
    /// either way; the only difference is how `G` is reconstructed at
    /// R/B sites.
    private func _demosaicShared(
        raw: [UInt16], width: Int, height: Int, fMaxValue: Double, useAdaptiveG: Bool
    ) -> (R: [Double], G: [Double], B: [Double]) {
        let n = width * height
        var rOut = [Double](repeating: 0, count: n)
        var gOut = [Double](repeating: 0, count: n)
        var bOut = [Double](repeating: 0, count: n)

        @inline(__always) func at(_ x: Int, _ y: Int) -> Double {
            let cx = max(0, min(width - 1, x))
            let cy = max(0, min(height - 1, y))
            return Double(raw[cy * width + cx])
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let centre = Double(raw[idx])

                let isGreenInRRow = (y & 1) == 0 && (x & 1) == 0
                let isRed         = (y & 1) == 0 && (x & 1) == 1
                let isBlue        = (y & 1) == 1 && (x & 1) == 0

                if isGreenInRRow {
                    // G@R-row: horizontal R neighbours, vertical B neighbours.
                    rOut[idx] = ((at(x-1, y) + at(x+1, y)) * 0.5) / fMaxValue
                    gOut[idx] = centre / fMaxValue
                    bOut[idx] = ((at(x, y-1) + at(x, y+1)) * 0.5) / fMaxValue
                } else if isRed {
                    // R sampled. G adaptive (AHD) or 4-cross bilinear. B = 4-corner.
                    let L = at(x-1, y); let Rr = at(x+1, y)
                    let U = at(x, y-1); let D = at(x, y+1)
                    let G_centre: Double
                    if useAdaptiveG {
                        let LL = at(x-2, y); let RR = at(x+2, y)
                        let UU = at(x, y-2); let DD = at(x, y+2)
                        let g_h = (L + Rr) * 0.5 + (2*centre - LL - RR) * 0.25
                        let g_v = (U + D) * 0.5 + (2*centre - UU - DD) * 0.25
                        let h_score = abs(g_h - centre) + abs(L - Rr)
                        let v_score = abs(g_v - centre) + abs(U - D)
                        G_centre = (h_score <= v_score) ? g_h : g_v
                    } else {
                        G_centre = (L + Rr + U + D) * 0.25
                    }
                    let B_diag = (at(x-1, y-1) + at(x+1, y-1) + at(x-1, y+1) + at(x+1, y+1)) * 0.25
                    rOut[idx] = max(0, centre)    / fMaxValue
                    gOut[idx] = max(0, G_centre)  / fMaxValue
                    bOut[idx] = max(0, B_diag)    / fMaxValue
                } else if isBlue {
                    let L = at(x-1, y); let Rr = at(x+1, y)
                    let U = at(x, y-1); let D = at(x, y+1)
                    let G_centre: Double
                    if useAdaptiveG {
                        let LL = at(x-2, y); let RR = at(x+2, y)
                        let UU = at(x, y-2); let DD = at(x, y+2)
                        let g_h = (L + Rr) * 0.5 + (2*centre - LL - RR) * 0.25
                        let g_v = (U + D) * 0.5 + (2*centre - UU - DD) * 0.25
                        let h_score = abs(g_h - centre) + abs(L - Rr)
                        let v_score = abs(g_v - centre) + abs(U - D)
                        G_centre = (h_score <= v_score) ? g_h : g_v
                    } else {
                        G_centre = (L + Rr + U + D) * 0.25
                    }
                    let R_diag = (at(x-1, y-1) + at(x+1, y-1) + at(x-1, y+1) + at(x+1, y+1)) * 0.25
                    bOut[idx] = max(0, centre)    / fMaxValue
                    gOut[idx] = max(0, G_centre)  / fMaxValue
                    rOut[idx] = max(0, R_diag)    / fMaxValue
                } else {
                    // G@B-row: vertical R neighbours, horizontal B neighbours.
                    rOut[idx] = ((at(x, y-1) + at(x, y+1)) * 0.5) / fMaxValue
                    gOut[idx] = centre / fMaxValue
                    bOut[idx] = ((at(x-1, y) + at(x+1, y)) * 0.5) / fMaxValue
                }
            }
        }
        return (rOut, gOut, bOut)
    }

    // MARK: - Demosaic (Malvar-He-Cutler)

    // MARK: - Chromatic Smoothing



    /// Separable box blur with anisotropic radii using **running-sum**
    /// O(N) per row/column — independent of radius, so a radius-20
    /// clarity blur is no slower than a radius-1 sharpen. Both passes
    /// clamp at the image border. Pass radius=0 on either axis to
    /// skip that pass.
    private static func boxBlur2D(
        _ src: [Double], width: Int, height: Int, radiusH: Int, radiusV: Int
    ) -> [Double] {
        let n = width * height
        var temp = [Double](repeating: 0, count: n)
        var out  = [Double](repeating: 0, count: n)

        // Horizontal pass — running-sum, slides one column per step.
        if radiusH > 0 {
            for y in 0..<height {
                let row = y * width
                var sum = 0.0
                var cnt = 0
                // Initialise the window centred on x=0: [0 ... min(W-1, r)].
                let initHi = min(width - 1, radiusH)
                for xx in 0...initHi { sum += src[row + xx]; cnt += 1 }
                temp[row + 0] = sum / Double(cnt)

                for x in 1..<width {
                    // Slide one step right: drop column (x-1-r) if it was inside;
                    // add column (x+r) if it's inside.
                    let dropIdx = x - 1 - radiusH
                    if dropIdx >= 0 {
                        sum -= src[row + dropIdx]
                        cnt -= 1
                    }
                    let addIdx = x + radiusH
                    if addIdx < width {
                        sum += src[row + addIdx]
                        cnt += 1
                    }
                    temp[row + x] = sum / Double(cnt)
                }
            }
        } else {
            temp = src
        }

        // Vertical pass — same algorithm column-major.
        if radiusV > 0 {
            for x in 0..<width {
                var sum = 0.0
                var cnt = 0
                let initHi = min(height - 1, radiusV)
                for yy in 0...initHi { sum += temp[yy * width + x]; cnt += 1 }
                out[0 * width + x] = sum / Double(cnt)

                for y in 1..<height {
                    let dropIdx = y - 1 - radiusV
                    if dropIdx >= 0 {
                        sum -= temp[dropIdx * width + x]
                        cnt -= 1
                    }
                    let addIdx = y + radiusV
                    if addIdx < height {
                        sum += temp[addIdx * width + x]
                        cnt += 1
                    }
                    out[y * width + x] = sum / Double(cnt)
                }
            }
        } else {
            out = temp
        }

        return out
    }

    // MARK: - Helpers

    private func sample(_ x: Int, _ y: Int, _ raw: [UInt16], _ width: Int, _ height: Int) -> Double? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        return Double(raw[y * width + x])
    }

    private func averageAxis(x: Int, y: Int, raw: [UInt16], width: Int, height: Int, dx: Int, dy: Int) -> Double {
        var sum = 0.0
        var count = 0
        if let v1 = sample(x - dx, y - dy, raw, width, height) { sum += v1; count += 1 }
        if let v2 = sample(x + dx, y + dy, raw, width, height) { sum += v2; count += 1 }
        return count > 0 ? sum / Double(count) : 0
    }

    private func averageCross(x: Int, y: Int, raw: [UInt16], width: Int, height: Int) -> Double {
        var sum = 0.0
        var count = 0
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for (dx, dy) in offsets {
            if let v = sample(x + dx, y + dy, raw, width, height) { sum += v; count += 1 }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    private func averageDiagonal(x: Int, y: Int, raw: [UInt16], width: Int, height: Int) -> Double {
        var sum = 0.0
        var count = 0
        let offsets = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        for (dx, dy) in offsets {
            if let v = sample(x + dx, y + dy, raw, width, height) { sum += v; count += 1 }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Renders to Float16 RGBA in extended-linear-sRGB so highlights map
    /// into the EDR headroom on Liquid Retina / Pro Display XDR. Color
    /// values stay in the same scene-referred space the SDR path uses;
    /// only the container changes (Float16 instead of UInt8) and we
    /// allow values above 1.0 (instead of clamping) up to `headroom`.
    ///
    /// Why this works on macOS:
    /// `extendedLinearSRGB` is a *scene-referred* color space — values
    /// in (0, 1] map to SDR brightness, values in (1, headroom] map into
    /// the display's HDR range. CoreAnimation/AppKit composite the EDR
    /// content automatically when an HDR-capable display is attached.
    private func renderHDRImage(
        encoded: [Float], width: Int, height: Int, headroom: Double
    ) -> NSImage? {
        let pixelCount = width * height
        var rgbaHalf = [UInt16](repeating: 0, count: pixelCount * 4)

        for i in 0..<pixelCount {
            // Back to linear through the same curve that encoded it, then
            // a soft-knee tone-map into HDR headroom.
            //
            // The input is the FULLY PROCESSED display value — chroma
            // median and, when on, the enhancement — so the HDR file now
            // carries the same look as its SDR twin rather than a rawer
            // render of the same frame.
            //
            // Below 0.85 linear the tone map is the identity, so shadows
            // and midtones stay identical to SDR on every display. Above
            // it a smooth knee lifts highlights into EDR range.
            let lr = QTKDecoder.kodakGammaDecodeExtended(Double(encoded[i*3]))
            let lg = QTKDecoder.kodakGammaDecodeExtended(Double(encoded[i*3 + 1]))
            let lb = QTKDecoder.kodakGammaDecodeExtended(Double(encoded[i*3 + 2]))
            let r = QTKDecoder.hdrToneMap(lr, headroom: headroom)
            let g = QTKDecoder.hdrToneMap(lg, headroom: headroom)
            let b = QTKDecoder.hdrToneMap(lb, headroom: headroom)

            // No gamma encode — extended-linear-sRGB is *linear*. The
            // display's HDR transfer is applied by the compositor.
            let dest = i * 4
            rgbaHalf[dest    ] = QTKDecoder.float16Bits(Float(r))
            rgbaHalf[dest + 1] = QTKDecoder.float16Bits(Float(g))
            rgbaHalf[dest + 2] = QTKDecoder.float16Bits(Float(b))
            rgbaHalf[dest + 3] = QTKDecoder.float16Bits(1.0)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            print("QTKDecoder: extendedLinearSRGB color space not available; falling back to SDR.")
            return nil
        }
        // `.byteOrder16Host` is a C macro that doesn't bridge into Swift —
        // every Apple platform is little-endian (x86_64, arm64), so use the
        // explicit little-endian flag directly. Same effect as the macro.
        //
        // `.noneSkipLast` (RGBX) instead of `.premultipliedLast`: the HDR
        // pipeline hardcodes alpha = 1.0 per pixel (see the producer
        // loop above), so the image is opaque. Tagging it as alpha-less
        // dodges ImageIO's "opaque image with AlphaLast" warning when
        // this CGImage is written as HEIC.
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            .floatComponents,
            .byteOrder16Little
        ]

        let bytes = rgbaHalf.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 16,
                                    bitsPerPixel: 64,
                                    bytesPerRow: width * 8,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    /// Soft-knee tone mapper for the HDR path. Below the knee, values
    /// pass through unchanged so shadows and midtones look identical to
    /// the SDR path on any display. Above the knee, an exponential roll
    /// smoothly lifts highlights into the `headroom` range — `1.0` SDR
    /// peak maps to roughly the midpoint of the headroom, and the
    /// asymptote sits just below `headroom` so we never hard-clip the
    /// hottest specular highlight.
    ///
    /// The result is what gives the image its "pop" on EDR-capable
    /// displays (Liquid Retina, Liquid Retina XDR, Pro Display XDR)
    /// without affecting how it looks on a plain SDR screen — values
    /// stay close to 1.0 except in the brightest spots.
    @inline(__always)
    static func hdrToneMap(_ x: Double, headroom: Double) -> Double {
        let kneeStart: Double = 0.85
        if x <= 0 { return 0 }
        if x <= kneeStart { return x }
        // Normalised position above the knee, capped to a reasonable
        // input ceiling so the asymptote stays well-defined.
        let inputCeiling: Double = 2.0
        let t = min(1.0, (x - kneeStart) / (inputCeiling - kneeStart))
        let knee = 1.0 - exp(-t * 2.5)            // 0..~0.92, soft S
        return kneeStart + (headroom - kneeStart) * knee
    }

    /// IEEE 754 binary16 packing for a Float32. Avoids depending on the
    /// `Float16` type (which exists on Apple Silicon but is awkward to
    /// pack into a UInt16 buffer portably).
    @inline(__always)
    static func float16Bits(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        var expn = Int((bits >> 23) & 0xFF) - 127 + 15
        var mant = bits & 0x007F_FFFF

        if expn >= 31 {
            // Inf / NaN / overflow → clamp to half-max
            return sign | 0x7BFF
        }
        if expn <= 0 {
            // Subnormal or underflow → flush to 0 (good enough for HDR pixels)
            return sign
        }
        // Round-to-nearest-even on the 13 dropped mantissa bits.
        let lsb = (mant >> 13) & 1
        mant += 0x0FFF + lsb
        if (mant & 0x0080_0000) != 0 {
            mant = 0
            expn += 1
            if expn >= 31 { return sign | 0x7BFF }
        }
        return sign | UInt16(expn << 10) | UInt16((mant >> 13) & 0x03FF)
    }

    private func renderToImage(rgbaData: [UInt8], width: Int, height: Int) -> NSImage? {
        let colorSpace = NSColorSpace.genericRGB.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        // QuickTake photos are opaque; the 4th byte per pixel is hardcoded
        // to 255 in the producer above. Tag as `.noneSkipLast` (RGBX) so
        // ImageIO doesn't complain when the resulting CGImage hits disk
        // via `writeImageAtIndex` — "trying to save an opaque image with
        // AlphaLast" would otherwise fire on every export.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

        guard let provider = CGDataProvider(data: Data(rgbaData) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo,
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            return nil
        }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }


}
