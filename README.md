# RoloPro AR Desk Mode (iOS, ARKit + RealityKit)

Native iOS 17+ project files. Needs a real device with ARKit (not the Simulator). LiDAR is optional and only adds occlusion.

## 1. How the cards look exactly like RoloPro

RoloPro's own CSS is the spec. `CardRenderer.swift` redraws it with CoreGraphics onto a 564 x 288 pt canvas
(the size of your screenshot) at 4x, so every web value is reused unchanged:

| Web (CSS) | Card texture |
|---|---|
| `.card` background `#fbf0c4` | paper fill |
| ruling `#e6b72f`, 1 px every 26 px, first rule 25 px below the 14 px top padding | rules drawn at `14 + 25 + n * 26` |
| padding `14px 16px` | text origin x = 16, y = 14 |
| `.nm` Special Elite 25 px `#1d5fd1` | "RoloPro" header |
| body Courier Prime 16 px, label 0.8em at 55 % opacity, 8 px gap | field rows |
| `.cqr` 34 px chip, 2 px `#d9b247` border, 10 px radius, 0 2px 0 shadow | QR icon, top right |

Fields are in your order: Email, Tel, WhatsApp, Address (empty values print "—", Address wraps to 2 lines like the web card).

The back uses the same ruled paper with a white tile holding the QR (about 220 pt, 4-module quiet zone, integer pixels
per module so it stays crisp), and "name · RoloPro" at the bottom. The QR payload is the same compact vCard 3.0 that
RoloPro's QR dialog encodes, with the same fallback chain (full card at level M, then L, then name/company/phone/email).

**One thing to check:** in your screenshot the blue line is the contact's name (the sample contact is literally named
"RoloPro"), and the line under it is "company · title". Your brief asks for brand in blue and the person's name in
black below. I built the brief's layout. Set `brandHeader = false` on `ARDeskViewController` to get the web card's
layout instead.

**3D card:** a thin box (1.5 mm) for the paper edge, plus two quads with hand-written UVs just above and below it.
Front and back are separate meshes, so the back is never mirrored and flipping needs no texture tricks.
Lit `PhysicallyBasedMaterial` paper picks up room light. Shadow is a blurred texture on the surface under the card
that grows and softens as the card lifts, so it works on every iOS version without a light rig.

## 2. Architecture

```
RoloHomeView (SwiftUI)  --import .json/.vcf-->  RoloImporter -> [RoloContact] -> RoloStore (Documents)
        |
        v
ARDeskView -> ARDeskViewController
   ARView + ARWorldTrackingConfiguration (horizontal planes, environment texturing, LiDAR occlusion if present)
   Reticle: raycast from screen centre, prefers ARPlaneAnchor.classification == .table
   Desk: ONE world ARAnchor at the tap point, facing you  -> AnchorEntity
         ├─ "Later" tray (flat texture)
         └─ CardEntity x N
              ├─ body (flips about X) ── edge box, front quad, back quad
              ├─ shadow (stays on the surface below)
              └─ ring (selection outline)
   Gestures -> desk-space maths (ray vs. the Y = 0 plane), per-frame physics in tick()
   Capture: arView.snapshot -> PhotoPreviewViewController (Save to Photos / Share sheet)
```

Why a world anchor instead of anchoring to the plane: ARKit merges and refines plane anchors while you scan, which
can nudge anything attached to them. A single `ARAnchor` at the first hit stays put. The plane is only used to size
the playable area (`session(_:didUpdate:)` fits `tableRect` to its boundary).

## 3. Interactions

| Gesture | What happens |
|---|---|
| Tap card | select (gold ring on the table, action bar: Flip, Straighten, Remove) |
| Tap empty table | deselect (first tap with no desk places it) |
| Drag | picks the card up 3 cm, follows your finger on the table plane, rests on whatever is beneath |
| Release | settles with a small thud; lands on another card = stacks with a little random offset and twist |
| Double-tap | flip: lift, turn 180° about the long axis, set down (back shows the big QR) |
| Two-finger twist | rotate the card |
| Flick | slides with friction, bounces softly off the table edge; a flick toward the Later tray is aimed to land in it |

Cards that end inside the tray are stacked there and remembered (`rolopro.ar.later` in UserDefaults, plus the
`onLaterChanged` callback with the contact ids).

## 4. Getting real RoloPro data in

RoloPro's cards live in the browser's `localStorage` (`rolodexchat.v1`), which a native app cannot read directly.
Options, from least to most work:

1. **Backup file (works today, no web changes).** In RoloPro tap Backup, then "Backup file (.json)". Send it to the phone
   (AirDrop, Files, WhatsApp to yourself) and use "Import" in the app. The importer reads `{ cards: [...] }` or a bare
   array; fields: `id, name, company, title, phone, wa, email, addr, notes, cat`.
2. **vCard.** Backup > "Contacts (.vcf)" imports the same way (parsing only, no Contacts permission needed).
3. **Live bridge.** Host RoloPro in a `WKWebView` inside the app and read the data with
   `evaluateJavaScript("localStorage.getItem('rolodexchat.v1')")`, then feed it to
   `RoloImporter.contacts(fromBackupJSON:)`. Add an "AR Desk" button in the web UI that calls
   `webkit.messageHandlers.rolo.postMessage(...)`.
4. **Later pile back to the web app.** `onLaterChanged` gives contact ids. RoloPro's 2D desk already has a
   `zone: 'later'` per card, so you can write the same ids back through the bridge.

`defaultCC` should be RoloPro's "Default country code" (`localStorage` key `rc.cc`) so phone numbers in the QR get a
`+` prefix exactly like the web app's vCard export.

## 5. Xcode setup

1. New iOS App (SwiftUI), deployment target iOS 17. Add the files in `Sources/` (delete the template `@main`).
2. Add `SpecialElite-Regular.ttf` and `CourierPrime-Regular.ttf` (the same Google fonts RoloPro loads) to the target and
   list them under **Fonts provided by application** (`UIAppFonts`). Without them the code falls back to American
   Typewriter and Courier, so the look is close but not identical.
3. Info.plist keys:
   - `NSCameraUsageDescription`: "RoloPro uses the camera to place your cards on a real table."
   - `NSPhotoLibraryAddUsageDescription`: "RoloPro saves photos of your desk to your library."
   - `UIRequiredDeviceCapabilities`: `arkit`
4. Run on a device. Present with `ARDeskView(contacts:defaultCountryCode:onLaterChanged:)` from anywhere in SwiftUI.

## 6. Tuning knobs

| Where | Constant | Effect |
|---|---|---|
| `CardSpec` | `width`, `thickness` | physical size and edge visibility |
| `ARDeskViewController` | `friction` | slide distance after a flick (distance = speed / friction) |
| `ARDeskViewController` | `laterCenter`, `laterSize` | where the Later tray sits on the desk |
| `CardEntity.quad` | the two V rows | swap them if a texture ever appears upside down |

## 7. Known limits

- I wrote this without an Xcode toolchain available, so it has not been compiled or run on a device. Expect to fix a
  few API-name or concurrency warnings on first build (it targets Swift 5 language mode).
- Stack overlap uses an axis-aligned test (fast, slightly generous on rotated cards).
- Picking a card out of the middle of a pile leaves the cards above it at their old height.
- The contact menu lists the first 40 names; a searchable sheet is the natural next step for big address books.
- Instagram appears in the share sheet when installed. Posting straight to Instagram Stories needs a Facebook App ID.
