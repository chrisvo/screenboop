# Architecture

Screenboop is a macOS 14+ executable built with Swift Package Manager (Swift tools 6.0, Swift language mode 5). It uses Apple frameworks and no third-party packages. `scripts/build.sh` wraps the executable in an app bundle and ad-hoc signs it; `make run` also launches that bundle. No external investigation tooling is required to build or use it.

## Source ownership

All app code lives in `Sources/Screenboop`:

| File | Responsibility |
| --- | --- |
| `ScreenboopApp.swift` | AppKit entry point, application activation, and delegate lifetime. |
| `AppDelegate.swift` | Main/editor window, app and status-bar menus, file-open handling, and command routing. Native text responders retain normal text copy/paste/undo behavior. |
| `Models.swift` | Tool definitions and shortcuts, annotation geometry, image document, backdrop, capture modes, history metadata, and recognition results. |
| `AppStore.swift` | Main-actor observable state and document actions: render/update, undo/redo, capture orchestration, import/paste, crop/resize/combine, OCR, output, history, and pin ownership. |
| `EditorView.swift` | SwiftUI sidebar, toolbar, inspector, welcome screen, recognition/resize sheets, and status/error UI. |
| `EditorCanvas.swift` | AppKit scroll-view bridge and canvas: drawing, event-to-image coordinates, drafts, selection/movement, keyboard tools, panning, pixel hover, and file drops. |
| `CaptureService.swift` | Permission checks, owned `screencapture` process lifecycle, scrolling region/progress UI, target-window checks, injected scroll events, and independent `ScrollStitcher` pixel matching/composition. |
| `Renderer.swift` | Core Graphics/Core Text rendering, privacy masks, pixelation and lenses, crop/resize/combine, sRGB sampling, PNG encoding, and image/geometry limits. |
| `ImageFiles.swift` | ImageIO import/orientation, thumbnails, JPEG encoding, and local original-capture history. |
| `NativeServices.swift` | Apple Vision OCR/QR, Carbon global hotkeys, and floating pin windows. |
| `ExampleImage.swift` | Generated, explicitly labeled example artwork. |

`Resources/Info.plist` describes the app bundle. `tools/GenerateIcon.swift` generates the original app icon used by the build script.

## Document and rendering flow

`ImageDocument` contains a source `CGImage`, editable `Markup` values, backdrop settings, and a title. `AppStore.updateDocument` renders a candidate before committing it, then publishes the document and flattened preview. Changes retain prior document snapshots for bounded undo; loading another image resets undo/redo. There is no persistent editable-document format.

Crop and resize render annotations without the backdrop and replace the source image with the flattened result. Combination does the same for the current image, joins it with imported images, and creates a new document without a backdrop. Undo retains the prior editable state. Copy, PNG/JPEG export, and pins use the renderer with the backdrop included. OCR uses rendered annotations without the backdrop, optionally cropped to the selection.

The application/store, UI, and renderer are main-actor owned. File import, Vision recognition, and scrolling pixel computations use detached work; screenshot process lifetime work is serialized on its own queue. Capture cancellation is forwarded to owned tasks/processes, dismisses capture UI, and cleans temporary capture files. These ownership choices do not imply any performance comparison with another app.

## Pixel-coordinate invariant

**Every document size, annotation point, crop region, and measurement uses physical image pixels with a top-left origin.** Screen points are confined to capture/UI boundaries.

- Import uses ImageIO's orientation transform before an image becomes a document.
- The canvas is flipped. It centers the rendered preview and computes the source-image origin by adding scaled backdrop padding. Pointer conversion is `(canvasPoint − imageOrigin) / zoom`; document coordinates never absorb zoom or padding.
- Core Graphics bitmap rendering establishes a top-left drawing transform. Image and Core Text drawing apply their own upright transforms at those boundaries rather than changing stored geometry.
- Cropping uses integral image-pixel bounds. Output dimensions come from decoded raster dimensions, not an assumed display scale.
- Scrolling selection translates AppKit global screen coordinates to Quartz coordinates for acquisition; alignment then works on the acquired frame pixels.

Keep this invariant when changing tools or rendering: view-space points, Retina scale, backdrop offsets, and document pixels are not interchangeable.

## Privacy and storage boundaries

Redaction is a renderer rule, not just annotation ordering. An effect source first bakes opaque redaction masks into image pixels; magnification and pixelation sample that source. Masks render again after other annotations, with forced opacity and copy blending. This prevents those output effects from sampling covered original pixels.

That rule does **not** erase the original document image. The color inspector deliberately samples that image, undo retains earlier documents, and `CaptureHistory` saves the original capture as PNG under `~/Library/Application Support/Screenboop/Captures`. History clearing removes listed capture PNGs after confirmation, not exports or the current document. PNG/JPEG and clipboard output are flattened; pins keep independent rendered snapshots.

Screenboop has no application networking, accounts, telemetry, or cloud integration. Apple Vision receives local image bytes. QR results are strings, not navigation requests. Export-folder preference and window geometry use local system preferences.

## Capture boundary and limits

Capture uses an owned `/usr/sbin/screencapture` subprocess—not ScreenCaptureKit. Standard area/window picking delegates to macOS. Main-display and delayed capture use the same subprocess without an interactive picker. Screen Recording is checked before acquisition; Accessibility is checked only before scrolling input.

Scrolling capture owns one rectangle and checks the window under its center before/after scrolling. It acquires at most 20 frames. `ScrollStitcher` detects stationary frames, matches vertical overlap, handles candidate static top/bottom bands, and rejects ambiguous or unmatched content. This is not a browser DOM/full-page capture API, and it cannot guarantee arbitrary app compatibility.

Image boundaries enforce 32,768 pixels per side and 100 million total pixels, including rendered padding and composition. Allocation or decoding can still fail below those limits; errors are surfaced rather than replaced with a fabricated result.

For user-facing privacy and operational limits, see [Usage](usage.md). The separate [research report](shottr-findings.md) distinguishes observed inspiration-app behavior from Screenboop's independent implementation.
