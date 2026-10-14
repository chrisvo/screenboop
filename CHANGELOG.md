# Changelog

## Unreleased

- Accept `CODE_SIGN_IDENTITY` for certificate-signed local builds so a stable signing identity can be reused across rebuilds.
- Document recovery when macOS retains a recording grant for an older ad-hoc binary despite showing its permission switch enabled.

## 1.0.0 — 2026-10-14

Initial public source for screenboop, an independent, local-only native macOS screenshot utility.

- Area, window, main-display, timed, and bounded vertical scrolling capture.
- Fifteen selection, annotation, effect, privacy, and measurement tools.
- Editable annotation snapshots with undo/redo, crop, resize, and image composition.
- Gradient backdrops, flattened PNG/JPEG output, clipboard copy, and floating references.
- On-device text and QR recognition, original-capture history, and global capture shortcuts.
- Original application artwork, usage/architecture/research documentation, actual app screenshots, image-safety tests, and macOS CI.

Builds are ad-hoc signed by default; a caller-selected code-signing certificate is optional. Builds are not notarized. Scrolling compatibility is bounded and app-dependent; pixelation is not secure redaction, and capture history retains original images. See the usage guide for operational and privacy limits.
