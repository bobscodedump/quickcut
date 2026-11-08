# Zest

> The app is called **Zest** (a lemon slice whose segments look like the drag wheel). Internally — the Xcode
> project, target, executable, bundle ID `local.dragwheel.DragWheel` and folders — it's still named DragWheel,
> which keeps permissions and settings intact. `scripts/install.sh` installs it as `/Applications/Zest.app`
> (and removes an old `/Applications/DragWheel.app`).

A macOS menu bar app that converts files by dragging. Start dragging file(s) from anywhere, press **Shift**,
and a radial wheel of valid target formats appears under your cursor. Drop on a slice and the converted file is
saved next to the original (`photo.png` → `photo.jpg`; if that exists, `photo 2.jpg`, `photo 3.jpg`, …).
The original is never overwritten or deleted.

Personal-use app: not sandboxed, not for the App Store.

**Requirements**: macOS 14 or later (Apple Silicon or Intel). To build: Xcode 15 or later.
Optional tools enable more formats: `brew install ffmpeg webp` (video, audio, WebP) and
`brew install --cask libreoffice` (Office and iWork files).

**Quick start**

```sh
git clone <this repo> && cd file_converter
scripts/install.sh      # build, copy to /Applications, launch
```

Then drag a file, press Shift while still dragging, and drop it on a format. See [How to use](#how-to-use).

## Features

- **Wheel**: frosted-glass radial menu, spring open/close, slice highlights (scale + accent colour), format name +
  SF Symbol per slice, file name / count in the centre. More than 8 formats → the 7 most common plus **More…**, which
  expands a second ring.
- **Only valid targets**: computed from each file's UTType (sniffed from magic bytes if there's no extension).
  Multiple files show only formats *every* file can convert to. Nothing valid → a small "No conversions available" bubble.
- **Dismissal**: release Shift before reaching the slices, press Esc, release the mouse elsewhere, or move out of
  the wheel, and it disappears and the drag behaves normally.
- **Conversions** (pluggable `Converter` protocol):

  | Input | Output | Engine |
  |---|---|---|
  | Images (PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP, RAW, …) | PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP, AVIF, ICO, ICNS, PDF | ImageIO (WebP encode: `cwebp` or `ffmpeg`) |
  | Images | TXT (text recognition / OCR) | Vision, on-device |
  | PDF | PNG / JPEG (multi-page → a folder, one image per page), TXT (text layer, or OCR for scans) | PDFKit + Vision |
  | TXT, RTF, HTML, DOCX, ODT, DOC | TXT, RTF, HTML, DOCX, ODT | `/usr/bin/textutil` |
  | TXT, RTF, HTML, DOCX, ODT, DOC, Markdown | PDF (searchable text, A4 or US Letter by region) | TextKit (or LibreOffice when installed) |
  | Markdown | HTML | built-in renderer |
  | DOCX, DOC, ODT, RTF, Pages | PDF, DOCX, ODT | LibreOffice (optional) |
  | PPTX, PPT, ODP, Keynote | PDF, PPTX, ODP | LibreOffice (optional) |
  | XLSX, XLS, ODS, Numbers | PDF, XLSX, ODS, CSV | LibreOffice (optional) |
  | CSV | XLSX, ODS | LibreOffice (optional) |
  | Folders and bundles | ZIP (`Photos` → `Photos.zip`, `Tool.app` → `Tool.app.zip`) | `ditto`, like Finder's Compress |
  | ZIP, TAR, TGZ, TBZ, TXZ, 7z | Extract (a single top-level item lands directly, no `foo/foo/` nesting) | `ditto` / `tar` |
  | Video | MP4, MOV, MKV, WebM, GIF; audio-only MP3, M4A, WAV | ffmpeg |
  | Audio | MP3, M4A, WAV, AAC, FLAC, OGG | ffmpeg |
  | MOV ↔ MP4, audio → M4A | | AVFoundation (no ffmpeg needed) |

  Without ffmpeg, ffmpeg-only formats are greyed out and the centre shows "Install ffmpeg: brew install ffmpeg"
  while hovering them. The same goes for LibreOffice ("brew install --cask libreoffice"). OGG uses Vorbis when your
  ffmpeg has `libvorbis`, otherwise Opus-in-Ogg.
- **Multi-file drops** also get batch slices that produce one output from everything:
  - **Merge PDF**: PDFs and images → `Merged.pdf`, in Finder name order ("page 2" before "page 10"). It's the
    first slice whenever it applies.
  - **ZIP All**: any files and folders → `Archive.zip`.
- Up to 3 conversions run concurrently. A native notification appears when a batch finishes (click → reveal in
  Finder) or fails (with the error). Jobs running longer than a second get a small floating progress panel with
  a cancel button.
- **Read-only locations** fall back to `~/Downloads`, and the notification says so. Folders can be dragged too
  (→ ZIP).
- **Settings**: output location (next to original / fixed folder), JPEG/HEIC/WebP quality, trigger key
  (Shift / Option / Control / Command), wheel size, show/hide greyed-out formats. The Tools section shows whether
  ffmpeg, cwebp and LibreOffice were found.
- **Menu**: Enabled, Launch at Login, Recent Conversions (reveal / open log), Settings…, Permissions status, Quit.
  The log is at `~/Library/Logs/DragWheel/conversions.log`.

## Build

```sh
scripts/build.sh            # Release build with xcodebuild → build/DerivedData.noindex/Build/Products/Release/DragWheel.app
scripts/test.sh             # unit tests via xcodebuild
scripts/package.sh          # Release build zipped for sharing → build/Zest.zip
```

> **If `xcodebuild` prints "A required plugin failed to load … run xcodebuild -runFirstLaunch"**, run
> `sudo xcodebuild -runFirstLaunch` once (Xcode's system components are out of date). This needs an admin password.
> Until then, use the SwiftPM fallback, which compiles the exact same sources:
> `swift test` and `SWIFTPM=1 scripts/install.sh`.

**Signing**: `scripts/build.sh` uses your *Apple Development* certificate if one is in the keychain, otherwise it
signs ad-hoc. With ad-hoc signing every rebuild changes the code signature, so macOS may drop the Accessibility
grant — remove and re-add Zest in System Settings → Privacy & Security → Accessibility after rebuilding.
A stable Apple Development signature avoids this. (Create one free in Xcode → Settings → Accounts → Manage Certificates.)

The Xcode project is generated by `scripts/generate_project.py` (no xcodegen needed). Re-run it after adding or
removing Swift files.

## Install and try it

```sh
scripts/install.sh          # builds Release, copies to /Applications, launches
```

Manual equivalent:

1. `scripts/build.sh`
2. `ditto build/DerivedData.noindex/Build/Products/Release/DragWheel.app /Applications/Zest.app`
3. `xattr -dr com.apple.quarantine /Applications/Zest.app` (only needed if it came from elsewhere)
4. `open /Applications/Zest.app` → a lemon icon appears in the menu bar.
5. Optional: menu → **Launch at Login** (works best from /Applications).
6. Try it: drag a PNG from Finder, and **while still holding the mouse button** press Shift. Move onto *JPEG*
   and release. `photo.jpg` appears next to the original and a notification pops up.

First launch asks for:
- **Notifications** — allow, so you see results.
- **Accessibility** (optional, see below).
- Per-folder prompts ("Zest would like to access files in your Desktop/Documents/Downloads folder") the first
  time it touches those places. Allow them. Or grant **Full Disk Access** to skip them all.

## How to use

1. Launch Zest. The lemon icon in the menu bar means it's running (no Dock icon).
2. **Start dragging** one or more files or folders from Finder, the Desktop, etc.
3. **While holding the mouse button, press Shift** (configurable in Settings). The wheel appears under the cursor.
4. **Drag onto a slice and release.** The converted file is saved next to the original, with " 2", " 3", … added if the name exists.
   For a multi-page PDF → image, a folder is created.
5. A notification confirms the result. Click it to reveal the file in Finder.

To cancel: release Shift before reaching the slices, press Esc, move out of the wheel, or release the mouse elsewhere.
The drag then behaves normally.

Tips:
- Several files at once show only formats all of them can convert to, plus **Merge PDF** (for PDFs and images)
  and **ZIP All**.
- Drag a folder to zip it; drag a `.zip` / `.tar.gz` / `.7z` to extract it.
- Drag a screenshot or scanned PDF onto **TXT** to pull the text out of it (OCR).
- Greyed-out slices need a tool (hover one while dragging to see which). Install with `brew install ffmpeg webp`
  and, for Office/iWork files, `brew install --cask libreoffice`.
- Hover **More…** to open a second ring of formats.
- Menu bar icon: toggle **Enabled**, **Launch at Login**, open **Recent Conversions** or the log, or **Settings…**.
- Long conversions show a small progress panel in the bottom-right corner, with a cancel button.

## Permissions

Zest is built to need as little as possible:

| What | Needs permission? |
|---|---|
| Global mouse down/drag/up monitors, drag pasteboard | No |
| Reading Shift/Option/Control/Command (`NSEvent.modifierFlags`, polled at 30 Hz) | No |
| Esc detection (`CGEventSource.keyState`, polled) | No (best effort, see limitations) |
| Instant key-event monitors (`flagsChanged`/`keyDown`) | **Accessibility** (optional) — only enabled if already granted |
| Notifications | Yes, a normal prompt |
| Reading/writing your files | Per-folder prompts, or Full Disk Access |

At launch, if Accessibility isn't granted, an alert explains this and has an **Open System Settings** button
(it opens Privacy & Security → Accessibility; "Don't remind me again" is available). The menu always shows the
current status. After granting it, relaunch the app.

## Architecture

```
DragWheel/
  main.swift, AppDelegate.swift      app entry, AppController (wiring + menu bar item)
  Core/
    DragMonitor.swift                global mouse monitors + 30 Hz poll → "file drag in progress"
    WheelVisibilityPolicy.swift      pure state machine: when to show/hide the wheel (unit tested)
    ConversionManager.swift          job queue, 3-way concurrency, progress, batch summaries
    NotificationService.swift        UNUserNotificationCenter, click → reveal in Finder
    SettingsStore.swift              UserDefaults-backed settings
    OutputReservation.swift          atomic unique naming ("x 2.jpg"), rollback of failed outputs
    OutputLocationResolver.swift     next to original / fixed folder / ~/Downloads fallback
    FileTypeResolver.swift           UTType lookup (symlinks resolved) + magic-byte sniffing
    ProcessRunner.swift, ToolLocator.swift   async Process wrapper; finds ffmpeg/cwebp in Homebrew dirs + PATH
    RecentConversions.swift, PermissionService.swift
  Formats/
    OutputFormat.swift               the catalogue of target formats (name, extension, SF Symbol, commonness)
    FormatRegistry.swift             UTType → valid targets, multi-file intersection, converter resolution
  Converters/
    Converter.swift                  the Converter (one file → one output) and BatchConverter (many → one) protocols
    ImageConverter / ImageCodec, TextRecognizer (OCR), PDFConverter, DocumentConverter, MarkdownConverter,
    DocumentPDFConverter (+ PDFPaginator), LibreOfficeConverter, ArchiveConverter,
    BatchConverters (MergePDFConverter, ZipAllConverter), AVFoundationConverter, FFmpegConverter
  UI/
    WheelPanelController.swift       borderless non-activating NSPanel (.popUpMenu, all Spaces, full-screen) + drop view
    WheelView.swift, WheelModel.swift, WheelGeometry.swift   SwiftUI wheel; pure geometry/hit-testing
    ProgressPanel.swift, SettingsView.swift
DragWheelTests/                      129 tests; fixtures (PNG, text images, PDFs, WAV, H.264 MOV/MP4, archives) are generated
                                     at runtime. LibreOffice plumbing is tested with a fake `soffice` script.
```

## Adding a converter

1. Create `DragWheel/Converters/MyConverter.swift` implementing `Converter`:

   ```swift
   struct MyConverter: Converter {
       let id = "my-converter"
       var inputTypes: [UTType] { [UTType("com.example.thing")!] }   // matched by conformance

       func outputFormats(for input: UTType) -> [OutputFormat] { [.txt] }   // never include the input's own format

       // Optional: report missing dependencies (greys out the slice with this tooltip)
       func availability(of format: OutputFormat) -> Availability { .available }

       func convert(input: URL, to format: OutputFormat, output: OutputReservation,
                    options: ConversionOptions, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
           let out = try output.reserveFile(ext: format.fileExtension)   // unique name, never overwrites
           // ... write to `out`, call progress(0...1), check Task.isCancelled / try Task.checkCancellation() ...
           return out
       }
   }
   ```
2. If it produces a new format, add an `OutputFormat` to `OutputFormat.swift` (and to `OutputFormat.all`), with a unique `commonness`.
3. Register it in `FormatRegistry.makeDefault` (order matters: for a format offered by several converters, the first *available* one wins).
4. Add tests next to the existing converter tests (use the helpers in `TestSupport.swift`).
5. `python3 scripts/generate_project.py` to add the files to the Xcode project.

**Several inputs → one output?** Implement `BatchConverter` instead (`accepts`, `outputBaseName`,
`convert(inputs:…)`) and add it to `batchConverters` in `FormatRegistry.makeDefault`. It is offered only when 2 or
more items are dropped and every item is accepted. See `MergePDFConverter` and `ZipAllConverter`.

Rules: write only through `OutputReservation` (that's what guarantees no overwrites and clean rollback on failure);
throw on failure (the manager rolls back reserved files); honour cancellation.

## Development

- **Icon**: a lemon slice whose 8 segments mirror the wheel, with one segment popped out like a highlighted slice.
  It's drawn in code: `swift scripts/make_icon.swift [preview.png]` regenerates `DragWheel/Resources/AppIcon.icns`.
  The monochrome menu bar version is `DragWheel/UI/LemonGlyph.swift`.
- **Product video**: `scripts/make_video.swift` renders a 26-second 1080p walkthrough (every frame drawn in code with the
  app's real wheel geometry and icon, encoded with ffmpeg):
  ```sh
  swiftc -O -parse-as-library -o build/make_video scripts/make_video.swift \
    DragWheel/UI/WheelGeometry.swift DragWheel/Core/WheelVisibilityPolicy.swift DragWheel/UI/LemonGlyph.swift
  build/make_video build/video/Zest-demo.mp4     # also writes Zest-demo-poster.png
  ```
- `swift test` runs everything without Xcode project machinery; `scripts/test.sh` does the same through xcodebuild.
- `Zest.app/Contents/MacOS/DragWheel --demo` / `--demo-many` show a sample wheel (the latter exercises "More…" and a greyed slice);
  `--demo-snapshot=/path/out.png` writes the wheel to a PNG and quits; `--no-permission-prompt` skips the alert.

## Sharing the app

```sh
scripts/package.sh      # → build/Zest.zip (universal: Apple Silicon + Intel)
```

Send the zip. The app is ad-hoc signed and not notarized, so on another Mac:

1. Unzip and move `Zest.app` to `/Applications`.
2. The first launch is blocked by Gatekeeper ("can't be opened"). Open System Settings → Privacy & Security and
   click **Open Anyway**, or run `xattr -dr com.apple.quarantine /Applications/Zest.app` in Terminal.
3. Allow Notifications and the folder-access prompts. Accessibility is optional.
4. For video, audio and Office formats they also need `brew install ffmpeg webp` and `brew install --cask libreoffice`.

To make it open with a plain double-click everywhere, sign it with a *Developer ID Application* certificate
(paid Apple Developer Program), turn on the hardened runtime (`ENABLE_HARDENED_RUNTIME = YES` in
`scripts/generate_project.py`), and notarize it with `xcrun notarytool submit … --wait` and
`xcrun stapler staple Zest.app`.

## Troubleshooting

**Lots of "Zest" / "DragWheel" copies in Launchpad / Spotlight / Open With.** Every built copy counts as an app, including
the ones in the project's `build/` folder. Only `/Applications/Zest.app` is needed. Build products now go into `build/*.noindex`
folders, which Spotlight and Launchpad skip, but older copies may linger:

```sh
# list every copy macOS knows about
mdfind "kMDItemCFBundleIdentifier == 'local.dragwheel.DragWheel'"
# unregister and delete a stray copy (repeat per path; never needed for /Applications)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u <path>/<copy>.app
rm -rf <path>/<copy>.app
# optional: rebuild Launchpad (also resets its layout)
defaults write com.apple.dock ResetLaunchPad -bool true; killall Dock
```

**Duplicate entries in Accessibility or Login Items, or Accessibility "on" but not working.** Ad-hoc signed
rebuilds look like new apps to macOS. Remove every Zest entry in System Settings → Privacy & Security →
Accessibility (and General → Login Items), then add `/Applications/Zest.app` again. To reset in one go:
`tccutil reset Accessibility local.dragwheel.DragWheel`.

**The wheel doesn't appear.** Check the menu bar icon → **Enabled** is ticked, and that you press the trigger key
*while* the mouse button is still held mid-drag. Promised files (e.g. dragged straight out of Mail or Photos) aren't
real files yet and are ignored.

**A slice is greyed out.** Hover it during the drag. The centre of the wheel says which tool to install. Settings →
Tools shows what was found.

**`xcodebuild` says "A required plugin failed to load".** Run `sudo xcodebuild -runFirstLaunch` once.

**Where did my file go?** Menu bar icon → Recent Conversions, or the log at `~/Library/Logs/DragWheel/conversions.log`.
If the original's folder is read-only, the output goes to `~/Downloads` (the notification says so).

## Known limitations

Things I could **not** verify automatically (they need a real mouse drag, which can't be scripted here), so give
them a first real try:

- The end-to-end gesture (drag from Finder → Shift → wheel under the cursor → drop on a slice). The pieces are
  tested (visibility policy, geometry/hit-testing, layout, conversion pipeline) and the wheel rendering was checked
  by snapshotting it, but the live AppKit drag-destination behaviour is unproven. In particular:
  - Each slice is a *logical* drop target, but the wheel registers one `NSView` for `.fileURL` and routes
    enter/exit/drop to the slice under the cursor by geometry. This avoids depending on how AppKit hit-tests overlapping
    registered views.
  - Releasing the mouse over a fully transparent corner of the wheel's panel should fall through to the window beneath
    (the panel is transparent and sized tightly to the wheel); if it doesn't on your macOS version, the drop is simply refused.
- Esc detection uses `CGEventSource.keyState` polling; if your macOS version needs Input Monitoring for that,
  Esc will still cancel the drag itself and the wheel closes when the mouse is released.
- The Xcode project is generated by `scripts/generate_project.py`. `xcodebuild build` and `xcodebuild test` both pass (129 tests, 0 warnings).

Other limitations:

- LibreOffice conversions were only tested with a stand-in `soffice` script (LibreOffice isn't installed on the
  build machine). The real-LibreOffice test runs automatically once it's installed. The first conversion after
  launch takes a few seconds while LibreOffice starts.
- OCR quality depends on the image: printed text works well, handwriting and tiny text less so. OCR is not
  added to PDF → image or to "searchable PDF" output.
- The built-in Documents → PDF converter keeps text, fonts, colours and basic layout, but simple TextKit layout
  drops headers/footers, complex tables and some images. Install LibreOffice for high-fidelity DOCX/ODT → PDF; it
  takes over automatically.
- HTML → PDF doesn't load remote images or run scripts.
- Single-file ZIP is only offered for folders and bundles. To zip loose files, select two or more and use ZIP All.
  Plain `.gz` / `.bz2` files that aren't tarballs can't be extracted.
- "Merge PDF" orders by file name, not by the order you selected the files in.

- Files must exist on disk. Promised files (e.g. dragged out of Mail or Photos before export) aren't converted.
- The second ring may be clipped when the wheel is opened right at a screen edge.
- Image → anything uses the first frame only (animated GIF → PNG keeps frame 0). Colour management is normalised to 8-bit.
- PDF → image renders at 144 dpi. PDF → TXT needs a text layer (no OCR).
- Markdown → HTML is a compact renderer (headings, emphasis, code, links, images, lists, quotes, rules); it doesn't do tables.
- Video → MP4/MOV re-encodes with H.264/AAC through ffmpeg; MOV ↔ MP4 through AVFoundation tries passthrough first.
- Multi-page PDF → image output is a folder named after the PDF.
- Launch at Login uses `SMAppService`, which is most reliable when the app lives in /Applications.
