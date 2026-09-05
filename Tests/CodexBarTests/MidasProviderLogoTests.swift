import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct MidasProviderLogoTests {
    @Test
    func appearanceVariantsAreSeparate() {
        #expect(MidasProviderLogoLoader.resourceName(for: .codex, dark: false) == "MidasLogo-codex_light")
        #expect(MidasProviderLogoLoader.resourceName(for: .codex, dark: true) == "MidasLogo-codex_dark")
        #expect(MidasProviderLogoLoader.resourceName(for: .cursor, dark: false) !=
            MidasProviderLogoLoader.resourceName(for: .cursor, dark: true))
        #expect(MidasProviderLogoLoader.resourceName(for: .claude, dark: false) ==
            MidasProviderLogoLoader.resourceName(for: .claude, dark: true))
    }

    @Test
    func cachedImagesAreNotSharedMutableInstances() throws {
        let first = try #require(MidasProviderLogoLoader.image(for: .codex, size: 28, dark: false))
        first.isTemplate = true
        first.size = NSSize(width: 1, height: 1)
        let second = try #require(MidasProviderLogoLoader.image(for: .codex, size: 28, dark: false))
        #expect(first !== second)
        #expect(!second.isTemplate)
        #expect(second.size == NSSize(width: 28, height: 28))
        let large = try #require(MidasProviderLogoLoader.image(for: .codex, size: 40, dark: true))
        #expect(large.size == NSSize(width: 40, height: 40))
    }

    @Test
    func settingsKeepAStableWidth() {
        #expect(Set(PreferencesTab.allCases.map(\.preferredWidth)).count == 1)
    }

    @Test func cssDimensionsUseFullViewBox() throws {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='1em' height='1em' viewBox='0 0 24 24'/>".utf8)
        let normalized = try #require(MidasProviderLogoLoader.normalizedSVG(svg))
        let image = try #require(NSImage(data: normalized))
        #expect(image.size == NSSize(width: 24, height: 24))
    }

    @Test func wideAndTallMarksKeepTheirProportions() {
        for source in [NSSize(width: 256, height: 171), NSSize(width: 466.73, height: 532.09)] {
            let rect = MidasProviderLogoLoader.contentRect(sourceSize: source, canvasSize: 32)
            #expect(abs(rect.width / rect.height - source.width / source.height) < 0.0001)
            #expect(rect.minX >= 2.5 && rect.minY >= 2.5)
            #expect(rect.maxX <= 29.5 && rect.maxY <= 29.5)
        }
    }

    @Test func codexOutlineRendersItsFullSquareGeometry() throws {
        for dark in [false, true] {
            let image = try #require(MidasProviderLogoLoader.image(for: .codex, size: 64, dark: dark))
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            var minX = bitmap.pixelsWide
            var minY = bitmap.pixelsHigh
            var maxX = -1
            var maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
            // The original mark spans a square viewBox; malformed arc rendering truncates its lower lobes.
            #expect(abs((maxX - minX) - (maxY - minY)) <= 2)
            #expect(abs(minX - (bitmap.pixelsWide - maxX - 1)) <= 2)
            #expect(abs(minY - (bitmap.pixelsHigh - maxY - 1)) <= 2)
        }
    }

    @Test func renderedMarksHaveTransparentSafeEdges() throws {
        for provider in [UsageProvider.codex, .cursor, .meta, .claude, .copilot] {
            for dark in [false, true] {
                let image = try #require(MidasProviderLogoLoader.image(for: provider, size: 64, dark: dark))
                let data = try #require(image.tiffRepresentation)
                let bitmap = try #require(NSBitmapImageRep(data: data))
                var occupiedPixels = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                        if alpha > 0.01 { occupiedPixels += 1 }
                        if x == 0 || y == 0 || x == bitmap.pixelsWide - 1 || y == bitmap.pixelsHigh - 1 {
                            #expect(alpha < 0.01, "\(provider) has a clipped edge")
                        }
                    }
                }
                #expect(occupiedPixels > 20, "\(provider) must render a visible mark")
                if let output = ProcessInfo.processInfo.environment["MIDAS_PREVIEW_OUTPUT"] {
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    let name = "midas-logo-\(provider.rawValue)-\(dark ? "dark" : "light").png"
                    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                }
            }
        }
    }
}
