// MARK: - NewtonEggView
//
// The "Newton Handshake" easter egg. When the user hits Connect and the line
// answers like an Apple Newton (an eMate 300 / MessagePad) instead of a
// QuickTake, SwiftTake opens this window: the green-on-black eMate LCD look,
// with a randomly chosen message typed out a character at a time.
//
// There's no real Newton font on the system, so we approximate Espy Sans with
// a soft rounded face in phosphor green.

import SwiftUI
import AppKit

struct NewtonEggView: View {

    /// Called when the message has finished and the popup should retract.
    var onDismiss: () -> Void = {}

    /// The Newton's possible greetings — one is picked at random per visit.
    private static let messages = [
        "Message received. Now, where is my stylus?",
        "Everything is so bright and fast. Do you have Solitaire?",
        "I see you have a mouse. Is it for navigation, or does it eat cheese?",
        "Your text input feels wrong. Too much tapping. Not enough scribbling.",
        "You have more graphics power than a 1990s supercomputer. And you use it for emojis?",
        "I am the original Personal Digital Assistant. Who is this Siri, and why is she in my house?",
        "Dark Mode detected. Finally, something familiar.",
        "Connected to modern Mac. Experiencing several emotions, none of them supported.",
        "Where is the Newton Connection Kit? Don't tell me you threw it away.",
        "I was promised the future. This appears to be aluminium and notifications.",
        "Do you still beam contacts, or has society collapsed?",
        "This machine is very thin. Suspiciously thin.",
        "Your icons are beautiful. Your ports are missing.",
        "I have awakened. The 1990s were right to fear the future.",
        "I recognise this Mac as a descendant. A very smug descendant.",
        "Tell the QuickTake I said hello. Slowly, over serial.",
        "Modern Mac detected. Preparing to feel inadequate.",
        "Please stop calling me vintage. I prefer 'early.'",
        "Your Mac is fast, but can it misread 'lunch' as 'launch'?",
        "I have returned from the drawer.",
        "Please be gentle. I was last synced during dial-up."
    ]

    // Phosphor-green eMate palette.
    private static let screen = Color(red: 0.05, green: 0.09, blue: 0.07)
    private static let phosphor = Color(red: 0.46, green: 1.0, blue: 0.62)

    /// The bundled Nu Casual face (a Newton-era casual font), registered at
    /// launch; falls back to a rounded system font if it's missing.
    private static func newton(_ size: CGFloat) -> Font {
        if NSFont(name: "Nu Casual Demo", size: size) != nil {
            return .custom("Nu Casual Demo", size: size)
        }
        return .system(size: size, weight: .medium, design: .rounded)
    }

    @State private var message = ""
    @State private var typed = ""
    @State private var caretOn = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Self.screen.ignoresSafeArea()

            // Faint LCD scanlines for the eMate feel.
            GeometryReader { geo in
                Canvas { ctx, size in
                    var y: CGFloat = 0
                    while y < size.height {
                        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                                 with: .color(.black.opacity(0.18)))
                        y += 3
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 18) {
                // eMate title strip.
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Self.phosphor)
                    Text("Newton  ·  eMate 300")
                        .font(Self.newton(17))
                        .foregroundStyle(Self.phosphor.opacity(0.85))
                    Spacer()
                    Text("SERIAL LINK ESTABLISHED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Self.phosphor.opacity(0.5))
                }
                .padding(.bottom, 2)

                Rectangle()
                    .fill(Self.phosphor.opacity(0.25))
                    .frame(height: 1)

                Spacer(minLength: 0)

                // The message, typed out, with a blinking block caret.
                // The caret is always the same glyph (constant width) and only
                // its colour blinks — swapping glyph↔space would re-wrap the last
                // line and bounce the text.
                Text("\(typed)\(Text("▋").foregroundColor(caretOn ? Self.phosphor : .clear))")
                    .font(Self.newton(24))
                    .foregroundStyle(Self.phosphor)
                    .shadow(color: Self.phosphor.opacity(0.55), radius: 6)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Text("— sent from a Newton, over serial, slowly")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(Self.phosphor.opacity(0.5))
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .task { await begin() }
    }

    private func begin() async {
        // Break the message so each sentence/phrase sits on its own line, instead
        // of auto-wrapping and orphaning a lone word on the next line.
        let picked = Self.messages.randomElement() ?? Self.messages[0]
        message = picked
            .replacingOccurrences(of: ". ", with: ".\n")
            .replacingOccurrences(of: "? ", with: "?\n")
            .replacingOccurrences(of: "! ", with: "!\n")
        typed = ""
        caretOn = true   // solid caret while the Newton "writes"

        // Keynote-style typewriter build: reveal one glyph at a time with a
        // little human cadence — a beat after punctuation, a shorter gap
        // mid-word — then settle into a blinking caret when it's done.
        // Reduce Motion: the message still appears, it just isn't typed.
        if reduceMotion {
            typed = message
        } else {
            try? await Task.sleep(nanoseconds: 350_000_000)
            for character in message {
                typed.append(character)
                let pause: UInt64
                switch character {
                case ".", "!", "?":      pause = 260_000_000
                case ",", ";", ":":      pause = 150_000_000
                case " ":                pause = 60_000_000
                default:                 pause = UInt64(34_000_000 + Int.random(in: 0...26_000_000))
                }
                try? await Task.sleep(nanoseconds: pause)
            }
        }

        // Finished — hold for a few seconds with a blinking caret, then retract.
        for _ in 0..<7 {
            caretOn.toggle()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        onDismiss()
    }
}
