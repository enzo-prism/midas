# Midas provider marks

Bundled from the public SVGL catalog on 2026-09-04. No runtime network requests.

- https://svgl.app/library/codex_light.svg
- https://svgl.app/library/codex_dark.svg
- https://svgl.app/library/cursor_light.svg
- https://svgl.app/library/cursor_dark.svg
- https://svgl.app/library/claude-ai-icon.svg
- https://svgl.app/library/meta.svg

Source catalog: https://svgl.app/ · repository: https://github.com/pheralb/svgl
Provider marks remain the property of their respective owners. Brand references: https://openai.com/codex/, https://cursor.com/brand, https://claude.ai/, https://about.meta.com/brand/resources/.

Other providers reuse the existing bundled monochrome provider marks as adaptive template images. Menu-bar icon resources are unchanged.

Codex compatibility adjustment: the original compact elliptical-arc path syntax triggers a CoreSVG parsing error and truncates the lower outline. Both Codex variants retain the original design, with arcs converted to equivalent absolute cubic Bezier curves (fontTools svgLib, six decimal places) and numeric 24-point dimensions. Full square geometry and centered alpha bounds are regression-tested in AppKit.
