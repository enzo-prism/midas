import AppKit
import CodexBarCore
import SwiftUI

/// Full-color provider identity for Midas surfaces, separate from menu-bar template icons.
@MainActor
struct MidasProviderLogo: View {
    let provider: UsageProvider
    var size: CGFloat = 28
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let image = MidasProviderLogoLoader.image(
                for: self.provider,
                size: self.size,
                dark: self.colorScheme == .dark)
            {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "square.stack.3d.up")
                    .resizable()
                    .scaledToFit()
                    .padding(self.size * 0.12)
            }
        }
        .foregroundStyle(.primary)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

@MainActor
enum MidasProviderLogoLoader {
    enum Role: Hashable {
        case panel, menuBar
    }

    struct CacheKey: Hashable {
        let provider: UsageProvider
        let role: Role
        let size: CGFloat
        let dark: Bool
    }

    private static var cache: [CacheKey: NSImage] = [:]

    static func resourceName(for provider: UsageProvider, dark: Bool) -> String? {
        switch provider {
        case .codex: "MidasLogo-codex_\(dark ? "dark" : "light")"
        case .cursor: "MidasLogo-cursor_\(dark ? "dark" : "light")"
        case .claude: "MidasLogo-claude-ai-icon"
        case .meta: "MidasLogo-meta"
        default: nil
        }
    }

    static func image(for provider: UsageProvider, size: CGFloat, dark: Bool, role: Role = .panel) -> NSImage? {
        let key = CacheKey(provider: provider, role: role, size: size, dark: dark)
        if let cached = self.cache[key] {
            return cached.copy() as? NSImage
        }
        let bundledName = role == .panel ? self.resourceName(for: provider, dark: dark) : nil
        let name = bundledName ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.iconResourceName
        let bundle: Bundle = {
            if let url = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
               let resourceBundle = Bundle(url: url)
            {
                return resourceBundle
            }
            return Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
        }()
        guard let url = bundle.url(forResource: name, withExtension: "svg"),
              let data = try? Data(contentsOf: url),
              let normalized = self.normalizedSVG(data),
              let source = NSImage(data: normalized),
              source.size.width > 0, source.size.height > 0
        else { return nil }
        let bounds = NSRect(x: 0, y: 0, width: size, height: size)
        let destination = self.contentRect(sourceSize: source.size, canvasSize: size)
        let image = NSImage(size: bounds.size, flipped: false) { _ in
            source.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = bundledName == nil
        self.cache[key] = image
        return image.copy() as? NSImage
    }

    /// CoreSVG treats CSS `1em` dimensions as one point. Use the SVG's actual coordinate space.
    static func normalizedSVG(_ data: Data) -> Data? {
        guard let document = try? XMLDocument(data: data), let root = document.rootElement(),
              let raw = root.attribute(forName: "viewBox")?.stringValue
        else { return data }
        let values = raw.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Double($0) }
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return nil }
        for (name, value) in [("width", values[2]), ("height", values[3])] {
            root.removeAttribute(forName: name)
            guard let attribute = XMLNode.attribute(withName: name, stringValue: String(value)) as? XMLNode else {
                return nil
            }
            root.addAttribute(attribute)
        }
        return document.xmlData
    }

    /// Insets protect antialiased boundary pixels and preserve wide/tall provider proportions.
    static func contentRect(sourceSize: NSSize, canvasSize: CGFloat) -> NSRect {
        guard sourceSize.width > 0, sourceSize.height > 0, canvasSize > 0 else { return .zero }
        let inset = canvasSize * 0.08
        let available = canvasSize - 2 * inset
        let scale = min(available / sourceSize.width, available / sourceSize.height)
        let width = sourceSize.width * scale
        let height = sourceSize.height * scale
        return NSRect(x: (canvasSize - width) / 2, y: (canvasSize - height) / 2, width: width, height: height)
    }
}
