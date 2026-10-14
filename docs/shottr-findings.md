# Shottr findings and independent design choices

screenboop takes inspiration from screenshot-editing workflows, not Shottr's proprietary source or artwork. This report records a bounded study of one shipped Shottr build and explains which observations informed an **independent** implementation. It does not establish source equivalence, matching algorithms, pixel-identical appearance, or performance parity.

The study used artifact metadata/import inspection, compiled interface-resource decoding, and a controlled editor/copy observation. No deep-analysis provider (Hopper, Ghidra, or IDA) was configured; no decompiled source or native runtime API-call trace was obtained. The full raw evidence bundle and decoded proprietary resources are retained privately outside this repository and are not redistributed here. The screenshots in screenboop's public guides show screenboop, not decoded Shottr resources.

## Artifact identity

| Field | Observed value |
| --- | --- |
| Product | Shottr |
| Version / build | 1.9.3 / 137 |
| Architectures | Universal `x86_64` and `arm64` |
| Main executable SHA-256 | `4a1ea879e1079b81b1c501e7ef0c399cf7d0890c2b33fc79f97c4124620360a3` |

The digest identifies the inspected **main executable**, not a hash of the entire app bundle. Findings apply to this artifact and observation scope, not automatically to other releases.

### Evidence index

These complete evidence identifiers refer to records in the private study bundle. They are provenance identifiers, not public download links or independently sufficient proof without the underlying records.

| Record | Evidence ID |
| --- | --- |
| Parsed app plist | `ev_66cec56a31359f4b9fd4f1f2ae69ae7c9c00704a532800f76e9195852b723d8f` |
| Mach-O inspection parent | `ev_2efbe18438aab3a55ba8ef42aa1a9bce1083a2e354560704862ddf32d38dc0a8` |
| Mach-O dependency view | `ev_44e9d2506c3227b65c0941362afcbba032d2ef791287ebc3418b254f29f9c618` |
| Decoded Interface Builder graph parent | `ev_2ab09d511c3f413c64fef84b0b06c79da7f6a3cbe85ec9121a688d323f4d4468` |
| Runtime editor screenshot | `ev_8c69b001465429b2d9108e8b66bdfab84840f26107fae843509597b119d96c9c` |
| Runtime editor accessibility tree | `ev_e308fc3145da66a0927ae8a240f8e8df2f3c99ca2bc4cd8f48757b2e3192f870` |
| Copy-button accessibility press scenario | `ev_daf4da8c89f6803e86ee737a76739dede9cb5e53ba3f671b5f7955dc5dde9fef` |

## What the imports establish

The inspected artifact referenced AppKit, SwiftUI, Vision, Core Graphics, Core Image, Carbon, and weak-linked ScreenCaptureKit. Relevant imported symbols included:

| Area | Observed symbols |
| --- | --- |
| Screen acquisition / permission | `_CGWindowListCreateImage`, `_CGDisplayStreamCreateWithDispatchQueue`, `_CGPreflightScreenCaptureAccess`, `_CGRequestScreenCaptureAccess`, `_OBJC_CLASS_$_SCShareableContent`, `_OBJC_CLASS_$_SCScreenshotManager` |
| Global shortcuts | `_RegisterEventHotKey`, `_UnregisterEventHotKey`, `_CopySymbolicHotKeys` |
| Scrolling input | `_CGEventCreateScrollWheelEvent2`, `_CGEventPost` |
| Text recognition | `_OBJC_CLASS_$_VNRecognizeTextRequest`, `_OBJC_CLASS_$_VNRecognizedText`, `_OBJC_CLASS_$_VNRecognizedTextObservation` |
| Image effects | `_OBJC_CLASS_$_CIFilter` |
| Clipboard types | `_NSPasteboardTypePNG`, `_NSPasteboardTypeString`, `_NSPasteboardTypeURL` |

These are **API references**, not proof that any specific symbol ran during the observed workflow, nor proof of an exact capture, stitching, effect, or OCR algorithm. Weak linking also does not establish which acquisition path was selected at runtime.

## What the compiled UI establishes

The decoded graph contained **17 compiled nib scenes, 3,431 nodes, and 1,617 edges**. Coverage was **partial**, with **11 partial-coverage facets**. It was not an exhaustive recovered application specification. The Swift-mangled class name `_TtC6Shottr11AppDelegate` appeared in the resources.

Observed tool labels included Arrow, Text, Rectangle, Freehand Drawing, Magnifier, Highlighter, Blur, Spotlight, and Counter. Menu/control selectors exposed several workflow surfaces:

| Surface | Observed selectors |
| --- | --- |
| Editing / crop / resize | `menuText:`, `menuBlur:`, `menuAddCapture:`, `menuUncrop:`, `clickBtnCrop:`, `clickResize:`, `clickAutocrop:`, `slideBlur:` |
| Output / pins | `menuCopy:`, `menuSave:`, `menuSaveAs:`, `menuUpload:`, `menuPin:`, `changeSaveFormat:`, `clickSaveFolder:`, `btnPin:` |
| OCR | `updatePrimaryOCR:`, `updateRemoveBreaksOCR:`, `clickOCR:` |
| Scrolling preferences | `updateReverseScroll:`, `updateReverseAutoscroll:`, `updateScrollingMax:`, `updateScrollingSpeed:` |

A selector or label establishes a declared UI connection/name, not successful execution, the implementation behind it, or present-day product availability. In particular, upload and automatic object-removal internals were not recovered or exercised.

## What the controlled runtime establishes

After the host permissions were granted, an original study image was opened in Shottr through LaunchServices. The image was **840 × 520 screen points**, rasterized as **1,680 × 1,040 physical pixels**.

The editor screenshot and accessibility tree showed a **1,680 × 1,040 px** indicator, **50% zoom**, a checkerboard canvas, and a pixel-color display with **Tab to copy** guidance. This supported separating image pixels from display points and making color inspection a visible workflow; it did not reveal Shottr's internal coordinate model.

An accessibility press on the actual **Copy** button completed. A separate local Swift `NSPasteboard` probe then observed:

- PNG raster dimensions of **1,680 × 1,040**.
- **71,559 bytes** of PNG data.
- PNG and TIFF pasteboard types.

This demonstrates a raster clipboard result for that controlled image and action. It is not a timing measurement, an encoding-equivalence test, or evidence for every annotation tool. The accessibility tree was unavailable after copying, so the study does **not** establish exact editor-close semantics.

Pin scenarios failed twice with an element-missing result despite a pin path appearing in the observation tree. **Shottr pin behavior was not runtime-verified.** The first window also displayed a standard purchase prompt; it was neither bypassed nor modified.

## Independent screenboop choices

The following links are design decisions based on the workflow surfaces above, not claims of recovered internals:

| Observed surface | screenboop's independent choice |
| --- | --- |
| Capture/permission API references | Use an owned macOS `screencapture` subprocess and explicit Screen Recording checks. screenboop does not use ScreenCaptureKit. |
| Carbon hotkey references | Register fixed Control–Option–1 through 5 shortcuts with Carbon; preserve menu-bar capture when registration conflicts. |
| Annotation labels and controls | Implement original pixel-based mark values and a Core Graphics/Core Text renderer behind a deliberately light SwiftUI/AppKit editor. No proprietary nibs, artwork, or implementation are copied. |
| Pixel size, zoom, and Tab color-copy UI | Keep physical image pixels as the document unit; convert view coordinates at the canvas boundary and expose original sRGB color sampling. |
| Vision text-recognition references and OCR controls | Use Apple Vision on local rendered image bytes, allow selection-scoped recognition and review, and add QR payload recognition without automatic navigation. |
| Blur/effect workflow | Separate visual pixelation from opaque Redact masks; require masking before magnifier/pixelation sampling and flatten masks into exported pixels. |
| Scrolling symbols and preference controls | Implement a bounded 20-frame vertical overlap matcher with stationary-frame detection, candidate fixed-band handling, and explicit rejection of ambiguous matches. Shottr's stitching algorithm remains unknown. |
| Copy/save/add-capture surfaces | Provide flattened PNG clipboard output, PNG/JPEG export, and explicit vertical/horizontal combination. Add local original-capture history with clear privacy warnings. |
| Pin control declarations | Implement independent floating snapshot windows. Their behavior comes from screenboop code and testing, not a successful Shottr pin scenario. |
| Upload/purchase surfaces | Omit uploads, accounts, payment/license flows, and cloud integration. |

Crop, undo snapshots, rounded gradient backdrops, and image limits are documented from screenboop's actual implementation in [Architecture](architecture.md) and [Usage](usage.md), not attributed to recovered Shottr source.

## Validation boundary and remaining unknowns

screenboop's own exercised checks include pixel-coordinate/crop rendering, export and clipboard pixels, local history round-trips, OCR and QR fixtures, opaque redaction and masked magnification, editable undo/redo restoration, real area/window/main-display acquisition, picker cancellation, and a visible closable pin. Synthetic scrolling fixtures exercise overlap composition and stationary duplicate handling. A separate controlled native scrolling window also produced a real **1,280 × 10,758** acquisition/composition result at the **20-frame** bound.

Those checks are screenboop-specific. The controlled scrolling run does not establish arbitrary app/browser compatibility, sticky-UI behavior, secondary-display scrolling coverage, or exact real-world seam/bottom behavior; precise overlap and stationary-bottom evidence comes from the synthetic fixtures. It is not a comparative benchmark.

Shottr's precise stitching, object removal/inpainting, upload, signing, and other internal algorithms remain unknown. No source-equivalence or matching performance claim follows from imported symbols, UI selectors, or one copy action. [Shottr's official website](https://shottr.cc/) describes the commercial product, but its advertised features or timings were not independently measured by this study and are not screenboop acceptance criteria.
