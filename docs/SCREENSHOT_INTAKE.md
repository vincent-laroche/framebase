# Screenshot intake

New screenshots go to the Screenshots library. They do not go to Personal, and they do not go to Hair Solutions. This path copies files into that library, runs the local Apple Vision OCR already used by Phase 6, and stores the recognized text so a screenshot can be found by what it says.

This repository cannot create the Shortcuts app shortcut. The steps below are the Shortcut. The receiving side is `framebase ingest-screenshots`.

## What this does not do

- It does not open, change, or delete iCloud Photos.
- It does not import the exported Apple Photos library or any other personal photo archive.
- It does not upload originals or call a cloud vision, embedding, or other model API.
- It does not start semantic search or a remote workflow.
- It does not delete the file the Shortcut saved. The same bytes can sit in the inbox after they are in the library.
- OCR does not move, tag, album, or rename the asset. The asset lands in the Screenshots catalog Inbox.

## Where files go

Run `framebase ingest-screenshots` with no paths and it chooses both locations:

| | Location |
| --- | --- |
| Library | `~/Pictures/Screenshots Library.framebase` |
| Inbox, when iCloud Drive is present | `~/Library/Mobile Documents/com~apple~CloudDocs/Framebase Screenshot Inbox` |
| Inbox, otherwise | `~/Pictures/Framebase Screenshot Inbox` |

iCloud Drive is the shared drop folder. An iPhone Shortcut and the Mac see the same files after they sync. The command creates the inbox folder and, if needed, the empty Screenshots library. It will not create or write a Personal or Hair Solutions package.

The inbox must sit outside the `.framebase` package. The job reads regular image files in the top level of that folder (`jpg`, `jpeg`, `png`, `heic`, `tif`, `tiff`, `gif`, `webp`). It skips hidden files, folders, and symlinks.

Identity is the SHA-256 of those original bytes. A second filename with the same bytes, or the same file on the next day's pass, stays one asset. If that asset does not yet have succeeded OCR, the later pass fills the text without copying again.

## Command

From the repository, after a release build:

```sh
swift build -c release --package-path Packages/FramebaseKit --product framebase
./script/ingest_screenshots.sh
```

`script/ingest_screenshots.sh` runs `ingest-screenshots` with the default library and inbox. Pass `--library` and `--inbox` only when the test or a manual drop uses another path.

An explicit run looks like this:

```sh
Packages/FramebaseKit/.build/release/framebase ingest-screenshots \
  --library "$HOME/Pictures/Screenshots Library.framebase" \
  --inbox "$HOME/Library/Mobile Documents/com~apple~CloudDocs/Framebase Screenshot Inbox"
```

The JSON result lists each filename, asset ID, `imported` or `alreadyPresent`, and the recognized text. It does not include storage keys or managed-original paths. A filename in `failureFilenames` was left in the inbox and was not turned into a second asset.

## Daily job

The launchd template is `script/com.vincentlaroche.framebase.screenshot-intake.plist`. It is not installed by the repository. On the Mac, from the repository root, after the release build:

```sh
mkdir -p "$HOME/Library/Logs/Framebase" "$HOME/Library/LaunchAgents"
sed \
  -e "s|__REPO__|$PWD|g" \
  -e "s|__HOME__|$HOME|g" \
  script/com.vincentlaroche.framebase.screenshot-intake.plist \
  > "$HOME/Library/LaunchAgents/com.vincentlaroche.framebase.screenshot-intake.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.vincentlaroche.framebase.screenshot-intake.plist"
```

That job runs at 03:15 local time. Run `./script/ingest_screenshots.sh` once by hand to confirm the inbox and library before loading the agent. To stop it later: `launchctl bootout "gui/$(id -u)/com.vincentlaroche.framebase.screenshot-intake"`.

## iPhone Shortcut

1. Open Shortcuts → Automation → the plus button → Create Personal Automation.
2. Choose Screenshot.
3. Turn Run Immediately on. Leave confirmation off if the capture should file itself.
4. Add Save File. The input is the Screenshot output from the automation.
5. Turn Ask Where to Save off.
6. Set the service to iCloud Drive and the folder to `Framebase Screenshot Inbox` at the top of iCloud Drive. Create that folder when Shortcuts asks.
7. Do not add Convert Image. A converted file is different bytes and would become a second asset.
8. Do not add Delete Photos, Remove from Album, or any action that changes iCloud Photos.

## Mac Shortcut

Use this when a Mac capture should land in the same inbox immediately. The daily job still picks up anything that only synced.

1. Open Shortcuts and create a shortcut named Save Screenshot to Framebase.
2. If the shortcut itself takes the capture, add Take Screenshot. If it should accept an existing image, set it to receive images from the Share Sheet and Quick Actions.
3. Add Save File. Turn Ask Where to Save off.
4. Set the destination to iCloud Drive → `Framebase Screenshot Inbox`.
5. Do not add Convert Image, and do not add an action that deletes the source from Photos or from the Desktop.
6. Optional: pin the shortcut to the menu bar.

System screenshot keys can keep saving onto the Desktop. Either run the shortcut instead of those keys, or copy the new screenshot files into `Framebase Screenshot Inbox`. The daily job is what puts them in the Screenshots library. The Mac does not need a second copy of the iPhone capture when both Shortcuts save into that iCloud Drive folder.
