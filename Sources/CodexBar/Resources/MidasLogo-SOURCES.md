# Midas provider marks

Bundled from the public SVGL catalog on 2026-09-04. No runtime network requests.

- https://svgl.app/library/codex_light.svg
- https://svgl.app/library/codex_dark.svg
- https://svgl.app/library/cursor_light.svg
- https://svgl.app/library/cursor_dark.svg
- https://svgl.app/library/claude-ai-icon.svg
- https://svgl.app/library/meta.svg

Added 2026-09-27:

- https://svgl.app/library/grok-light.svg → `MidasLogo-grok.svg` (fill set to black; geometry unchanged and matching the official https://grok.com/images/favicon.svg mark). Rendered as a monochrome template image beside Cursor's Grok Bot allowance to identify that service. Grok is a trademark of xAI; brand reference: https://x.ai/legal/brand-guidelines.

Added 2026-10-17:

- https://svgl.app/library/nvidia-icon-light.svg and https://svgl.app/library/nvidia-icon-dark.svg → `MidasLogo-nvidia_light.svg`, `MidasLogo-nvidia_dark.svg`, and `ProviderIcon-nvidia.svg`. NVIDIA eye and wordmark geometry and viewBox are unchanged. Both paths use black or white for the monochrome appearance variants; the menu-bar mark is a template image. The local inference card uses a separate NVIDIA green accent. NVIDIA is a trademark of NVIDIA Corporation; brand reference: https://www.nvidia.com/en-us/about-nvidia/legal-info/logo-brand-usage/.

Source catalog: https://svgl.app/ · repository: https://github.com/pheralb/svgl
Provider marks remain the property of their respective owners. Brand references: https://openai.com/codex/, https://cursor.com/brand, https://claude.ai/, https://about.meta.com/brand/resources/.

Other providers reuse the existing bundled monochrome provider marks as adaptive template images.

Codex compatibility adjustment: the original compact elliptical-arc path syntax triggers a CoreSVG parsing error and truncates the lower outline. Both Codex variants retain the original design, with arcs converted to equivalent absolute cubic Bezier curves (fontTools svgLib, six decimal places) and numeric 24-point dimensions. Full square geometry and centered alpha bounds are regression-tested in AppKit.
