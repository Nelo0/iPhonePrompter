# iPhonePrompter

iPhonePrompter is a native macOS teleprompter and recorder. The app is named iPhonePrompter; internal build targets and the bundle directory remain LensPrompt for compatibility. It replaces a browser teleprompter plus Photo Booth in this setup: an iPhone sits landscape on a tripod in front of the Mac display, its rear camera facing you.

- **Live preview** of the iPhone camera, received through Continuity Camera (wireless or USB, whichever macOS uses).
- **Recording** of camera video plus the microphone you choose (for example a Bluetooth mic) to `.mov` files (H.264 + AAC) on your Mac.
- **A floating prompt panel** whose active line sits right next to the phone's lens, plus a **phone outline and lens target** so you can line it up with the real phone.
- **Speech following** on the Mac (Apple SpeechAnalyzer), plus **fixed-speed** and **manual** modes.

The studio uses a compact sidebar for capture and prompt controls, with advanced controls in Studio settings. Wide windows show the script and camera side by side; smaller windows stack them.

There is no iPhone app, no cloud service, no account and no analytics.

## Requirements

- macOS 26.0 or later (developed on macOS 26.3.1, Apple silicon). The deployment target is 26.0 because SpeechAnalyzer/SpeechTranscriber need it.
- Xcode 26 command-line toolchain (Swift 6.x). Built and tested with Xcode 26.4.1 / Swift 6.3.1.
- An iPhone with Continuity Camera (same Apple Account, Wi-Fi and Bluetooth on, or connected by USB).

## Build, run, install

```sh
scripts/build_app.sh          # release build -> build/LensPrompt.app (ad-hoc signed)
scripts/run_app.sh            # opens the app
scripts/run_app.sh --no-capture   # opens the UI with camera/mic/recording disabled
scripts/install.sh            # copies the app to ~/Applications
scripts/test.sh               # deterministic tests (no hardware needed)
swift build -c release --product lensprompt-speech-check && \
  "$(swift build -c release --show-bin-path)/lensprompt-speech-check" --right-channel   # offline recognizer check (~40 s)
```

The default bundle identifier is `io.github.Nelo0.iPhonePrompter`; set `BUNDLE_IDENTIFIER` when building to use an existing local app identity. With ad-hoc signing, macOS may ask for camera and microphone permission again after each rebuild. To keep those permissions across rebuilds, sign with a stable local identity: `CODESIGN_IDENTITY="My Local Cert" scripts/build_app.sh`.

The app is not sandboxed (it's a personal build), so any folder you pick for recordings works without security-scoped bookmarks.

## Using it

1. **Permissions.** On first launch, allow Camera and Microphone. If you deny either one, a banner links to System Settings.
2. **Devices.** In the sidebar, pick the iPhone under **Camera** and your external mic under **Microphone**. Each shows its connection state, the actual video format (1920×1080 at 30 fps when the camera offers it, otherwise the closest format, clearly labelled), the mic's input format, and a level meter with clipping and silence warnings.
   - If a saved device goes missing, it shows as "not connected". LensPrompt never switches to a different microphone or camera on its own.
3. **Framing.** Use the preview to frame yourself. Turn on **Grid** in the camera preview for rule-of-thirds lines. The grid follows the fitted video area, stays visible against light and dark backgrounds, and never appears in recordings. Its setting is remembered after relaunch. **Mirror** only mirrors the preview; the recording is never mirrored. The studio options menu next to Record contains **Show camera preview**; hiding the preview does not stop capture or recording.
4. **Script.** Paste into the editor, or use File › Open Script… (⌘O) for UTF-8 text or Markdown. Markdown is shown as plain text. The script autosaves.
5. **Placement.** Open **Phone placement** in the sidebar, or **Studio settings › Phone placement**, then turn on **Placement mode** (⇧⌘P):
   - Size the outline to the real phone. Either click **Draw phone outline…** and drag a box on the screen exactly where the iPhone covers it (Esc cancels), or drag any of the four orange corners. The sidebar also has Width/Height controls in points and a reset to the iPhone 15 Pro Max estimate. Drag the middle of the outline to move it.
   - Match the camera position. The default is the camera cluster at the top right. **Rotate 180°** (on the outline or in the sidebar) moves the camera to the opposite corner for a phone mounted the other way up. **Flip sides** moves it to the other end. Then drag the green target onto the real lens.
   - Set the text box size with the Width/Height controls under **Text box size**, or drag the prompt panel's edges. Resizing keeps the edge nearest the phone fixed.
   - Choose a layout: *Phone below text* (default), *Phone above text*, or *Free*. Then use **Place text beside lens** to put the active line right next to the lens. The outline, lens target and prompt can each be adjusted on their own.
   - Use **Lock layout** to prevent accidental moves. Hide or fade the outline without moving the text.
   - Save named **presets**. They store the display, outline, lens position, prompt frame, typography and layout choice.
   - Press Esc to leave placement mode.
6. **Prompt modes.** Use **Voice**, **Fixed**, or **Manual** in the sidebar. Voice follows speech; Fixed uses a constant visual speed in screen points per second:
   - The first time you use speech following, click **Enable English speech model** so macOS can install or reserve its on-device model.
   - Voice following shows the current line at the top and upcoming text below it. Completed lines are hidden.
   - Fixed speed scrolls at a constant visual rate in screen points per second, including across paragraph gaps and lines of different lengths.
   - The status dot shows Following, Listening, Not matching (holding), or Lost (click a phrase to resync). The Speech following section shows the latest recognized words under Heard while following is active; they are not saved. Both channels of a stereo wireless receiver feed recognition.
7. **Test recording.** Make a short take, then use Play or Reveal in Finder. To check sync, do a clap test and adjust **Audio sync offset** under **Studio settings › Recording**. Positive values delay the audio relative to the video; the range is ±1000 ms in 10 ms steps, with Reset to 0.
8. **Record.** Press **Record** (⇧⌘R):
   - With the optional **3-second countdown** enabled in the studio options menu next to Record, the countdown starts only after the camera, mic, folder and disk space have been checked and the writer is ready.
   - "Recording" appears only once the movie file has actually started. Script tracking starts with the take.
9. **Stop.** The file is finalized with a unique name (`LensPrompt 2026-11-04 at 10.15.30.mov`, then ` 2`, ` 3`…). Existing files are never overwritten. Use Preview, the folder button, or Another Take. Resetting or editing the script never deletes takes, and missing library entries can be removed without touching files.

Recordings go to `~/Movies/LensPrompt` by default (change it under Recording › Choose Folder…). Settings, the current script, presets and the take list are stored in `~/Library/Application Support/LensPrompt`; no audio or transcripts are stored.

Open **Studio settings** in the sidebar or press Command-comma for text appearance, voice details, phone calibration, output location and audio synchronization. The main sidebar keeps camera, microphone and prompt controls close at hand.

### Keyboard shortcuts (only while iPhonePrompter is active; not system-wide)

| Key | Action |
| --- | --- |
| Space | Start or pause the prompt (ignored while typing in the script editor) |
| ⇧⌘R | Start recording (with countdown) / stop recording |
| Esc | Cancel the countdown; otherwise leave placement mode or reading mode. Never stops a take. |
| ↑ / ↓ | Previous / next line (in speech mode this also resyncs from the new position) |
| ← / → | Back / forward one word |
| + / − | Fixed scroll speed ±10 pt/s |
| ⌘O | Open script |
| ⌘0 | Open or focus the recording studio |
| ⌘, | Studio settings |
| ⇧⌘P / ⇧⌘E / ⇧⌘T | Placement mode / reading mode / show or hide the prompt panel |
| ⌘1 / ⌘2 / ⌘3 | Follow my voice / fixed speed / manual |
| ⌘Home | Back to script start |

Click any phrase in the prompt to resume from there. The scroll wheel over the prompt moves line by line. Prompt shortcuts don't work while the script editor, recordings browser, or settings sheet has focus; click the preview or the prompt first.

Pausing the prompt never pauses the recording. Recording is a continuous start/stop.

## Browse and manage recordings

Click **Recordings…** at the bottom of the main window, or use **Recording › Recordings…** with Shift-Command-L. Select a take to preview it immediately, scrub through the video, or change playback volume. The browser includes thumbnails, file names, dates, durations, sizes, search, and an oldest-first toggle.

Use **Rename…** to rename a video without changing its extension or overwriting another file. **Reveal in Finder** opens its location. **Move to Trash…** asks for confirmation, moves the video to the Mac's Trash, and removes its library entry. You can restore the file from Trash and use **Refresh** to rediscover it. Missing files have a **Remove Missing Entry** action that only removes stale metadata.

Opening the browser or pressing Refresh discovers video files already in the current recordings folder, including previous takes that are not in the saved list. Existing interruption details are retained. Files from previously selected folders stay in the library. The active recording is excluded from discovery, and renaming and Trash actions are disabled until the current take finishes.

## How it works

| Component | File |
| --- | --- |
| Capture: one `AVCaptureSession` with the camera, the selected mic, and video/audio data outputs on one serial queue | `Sources/LensPrompt/Capture/CaptureService.swift` |
| Writer: `AVAssetWriter` with H.264 + AAC, 4 s movie fragments for crash recovery, audio-offset retiming, never overwrites | `Sources/LensPromptCore/Recording/MovieWriter.swift` |
| Take state machine: idle, preparing, countdown, recording, stopping, saved/failed | `Sources/LensPromptCore/Recording/TakeController.swift` |
| Speech adapter: SpeechAnalyzer + SpeechTranscriber (progressive preset, en-US) behind the `SpeechRecognizing` protocol; format conversion off the capture queue, bounded buffers | `Sources/LensPrompt/Speech/SpeechRecognizerAdapter.swift` |
| Alignment: normalized tokens mapped back to original text, local alignment over a bounded window, new-evidence rule, guarded backward moves, lost/reacquire | `Sources/LensPromptCore/Alignment/` |
| Prompt control, layout geometry, storage | `Sources/LensPromptCore/{Prompt,Layout,Storage}` |
| UI | `Sources/LensPrompt/{Views,Panels,App}` |

- **Timing.** Every buffer, including audio, uses the capture session's synchronization clock. The movie starts at the first video frame. The audio offset is applied to buffer timestamps, never to UI callback times.
- **Shared mic stream.** The same audio callback feeds the writer, the meter and the speech recognizer, so there are never two competing microphone sessions.
- **Alignment rules.** Case, punctuation, contractions, digits and fillers are normalized. Each window is ~10 recent spoken tokens against 30 tokens behind and 60 ahead. Only words not yet used may move the position. Backward moves need at least 4 matched words and are capped at 25 tokens.

## Debug aids

- `--no-capture` (or `LENSPROMPT_NO_CAPTURE=1`): opens the UI without requesting permissions or starting capture.
- `LENSPROMPT_SUPPORT_DIR=/path`: uses a separate settings/script directory.
- `LENSPROMPT_SNAPSHOT_DIR=/path` (with `--no-capture`): renders LensPrompt's own windows to PNG files and quits. This uses view caching, not screen capture.
