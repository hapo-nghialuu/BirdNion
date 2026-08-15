import AppKit
import CoreText

/// Registers the bundled IBM Plex Sans / IBM Plex Mono font files with the
/// process-local Core Text font manager so `Font.custom("IBM Plex Sans", …)`
/// and `Font.custom("IBM Plex Mono", …)` resolve correctly across every
/// weight used by the Instrument redesign (Views/Theme.swift).
///
/// Files live in `BirdNion/Resources/Fonts/` and are copied into the app
/// bundle by the "Resources" build phase — no `Info.plist` entry needed
/// (that's only required for `ATSApplicationFontsPath`-style folder
/// registration; this uses explicit per-file `CTFontManagerRegisterFontsForURL`
/// instead, which is robust to Xcode flattening bundle resources).
///
/// Call once, as early as possible (`BirdNionApp.init`) — before any SwiftUI
/// view that references `VocabbyFont.sans` / `VocabbyFont.mono` is built.
/// Registration is idempotent: re-registering an already-registered font URL
/// is a harmless no-op (Core Text reports `.duplicatedName`, ignored below),
/// so calling this more than once is safe.
enum AppFonts {
    /// Bundle resource names (without extension) for every weight the
    /// redesign uses. Keep in sync with `BirdNion/Resources/Fonts/*.ttf`.
    private static let fontFileNames = [
        "IBMPlexSans-Regular",
        "IBMPlexSans-Medium",
        "IBMPlexSans-SemiBold",
        "IBMPlexSans-Bold",
        "IBMPlexMono-Regular",
        "IBMPlexMono-Medium",
        "IBMPlexMono-SemiBold",
    ]

    static func registerBundledFonts() {
        for name in fontFileNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                // Missing in this build (e.g. resource not copied yet) — the
                // Font.custom() call sites all fall back to the system font,
                // so this is a silent visual regression, never a crash.
                continue
            }
            var unmanagedError: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        }
    }
}
