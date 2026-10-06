# Lazy Ask

A native Mac meeting assistant. Organize separate Lazy Meetings into folders, listen to meeting audio and your microphone, and view answers in a floating window.

## Requirements

- macOS 15 or newer.
- Apple's Command Line Tools or Xcode with Swift 6 or newer.
- An OpenAI API key with access to `gpt-live-transcribe` and the chosen answer model. API usage is billed through your OpenAI account.

No Node.js, Python, meeting bot, audio driver, or third-party Swift package is needed.

## Build and Open

Double-click **Launch Lazy Ask.command**, or run these commands from this folder:

```sh
bash scripts/build-app.sh
open "dist/Lazy Ask.app"
```

If you do not have the Apple build tools, run `xcode-select --install` once, then finish the installer. Always open the bundled `.app`; running the bare Swift binary does not give macOS the app's permission descriptions.

Every build updates the same locally signed app at `dist/Lazy Ask.app`. For each new iteration, quit Lazy Ask and double-click **Launch Lazy Ask.command** to rebuild and reopen it. The build script checks that the app is stopped before replacing its executable. Saved transcripts, preferences, and your Keychain API key stay outside the app bundle and carry across updates.

This is a local development build, not a notarized public download. The build uses SwiftPM's native engine to keep the app in one executable and avoid a test-plugin issue in the local Swift 6.4 tools.

## First Use

1. Open Lazy Ask and click the settings icon.
2. Paste your OpenAI API key and click **Save**. The app stores it in macOS Keychain.
3. Click **Allow** for Microphone and Screen & system audio. macOS calls the second permission **Screen & System Audio Recording** on newer versions and **Screen Recording** on some older versions.
4. If macOS asks you to quit and reopen Lazy Ask, do that before starting.
5. On the home screen, click **New meeting**, enter a name, and click **Create**. Join your online meeting and click **Start listening** inside that Lazy Meeting. The menu bar icon also has start and stop controls.
6. After someone asks a question, say **"I'm not sure, Lazy Ask."** To ask your own question, say **"Lazy Ask, what is a cache?"** You can also type a question in the app.

Use the Mac's default microphone. Headphones help keep meeting playback out of the microphone stream. A muted meeting microphone can still be heard by Lazy Ask if the input device is active.

## Lazy Meetings and Folders

The home screen opens first. Each Lazy Meeting has its own saved transcript and answer context. Click a meeting to open it, and use the back arrow to return home. Returning home or changing meetings stops listening first.

Use the three-dot menu on a meeting to rename it, move it into a folder, or delete it. The folder-plus icon creates a folder; a folder's menu lets you rename or delete it. Deleting a folder moves its meetings to **Unfiled**. Deleting a meeting removes its transcript after confirmation. Search filters meeting names within the selected folder.

An existing single-transcript file is imported once as **Imported meeting**. The old JSON file is removed only after its data has been committed to the meeting database.

Storage is local in SQLite. The home screen loads meeting summaries rather than every transcript; only the opened meeting's transcript is loaded. New speech turns are saved individually. This keeps storage updates small as the library grows. Cloud storage is not required for a single Mac; it would be useful later for device syncing or shared access. SQLite is designed for [local application storage](https://www.sqlite.org/whentouse.html).

Keep a backup of `~/Library/Application Support/LazyAsk/`. Copy this folder while Lazy Ask is closed so the database and its journal files are consistent, or include it in your normal Mac backup. Settings has a folder button to show the meeting library in Finder.

Use **Run demo** to test the transcript, voice-trigger path, and answer overlay without an API key, microphone access, or a network request. Demo answers are fixed sample text and are marked **SAMPLE**. To open directly in demo mode:

```sh
open "dist/Lazy Ask.app" --args --demo
```

## Data and Audio

- Lazy Ask captures Mac playback audio, including other apps' audio, and the default microphone as separate sources. It does not use a Zoom, Meet, Teams, or Discord integration.
- While listening is on, speech audio is sent to OpenAI for transcription. A question sends the recent transcript to OpenAI for an answer.
- The transcript window is **Until cleared**. Text has no automatic time, character, or segment limit and is kept when you stop/start listening or reopen the app. The trash button clears only the currently opened meeting's transcript and answer.
- Final transcript text, meeting names, and folder membership are saved locally at `~/Library/Application Support/LazyAsk/meetings.sqlite3`. Audio is not saved. Demo text is temporary and is not saved to any meeting. The latest answer is temporary and is cleared when you change meetings or quit.
- Each answer uses up to the latest 600 eligible transcript segments and 60,000 characters from the currently opened meeting only. This request limit does not delete older text from saved history.
- The answer request sets `store: false`. This does not mean the provider has no retention; see [OpenAI data controls](https://developers.openai.com/api/docs/guides/your-data).
- Only final microphone transcripts can activate the wake phrase. Meeting transcripts provide context. No answer is played through your microphone or speakers.
- The overlay uses macOS window sharing protection as a best effort. Screen-sharing apps and macOS versions may handle it differently. Share the meeting or document window, not the whole display, when the answer needs to stay private.
- Get participants' consent before transcribing their meeting.

## How It Works

```text
ScreenCaptureKit
  |-- meeting audio ------> 24 kHz mono PCM16 --> live transcription --|
  |-- default microphone -> 24 kHz mono PCM16 --> live transcription --|
                                                                    |
                                                     saved transcript
                                                                    |
                                               final mic wake phrase
                                                                    |
                                            question + meeting context
                                                                    |
                                               streamed text answer
                                                                    |
                                                    floating overlay
```

ScreenCaptureKit captures system and microphone audio in one stream, with separate output callbacks. `AVAudioConverter` converts each source to little-endian, mono PCM16 at 24 kHz. The screen callback is discarded; no screenshot or video is sent to the model.

Each audio source has its own WebSocket transcription session with `gpt-live-transcribe`. A local energy gate keeps a short audio lead-in, streams speech, and commits a turn after a pause. It also ends long turns every 15 seconds. Increasing **Speech sensitivity** helps with quiet voices; lowering it helps with background noise. This simple gate can mistake steady noise for speech.

Transcript items are matched by `item_id` and ordered by capture time rather than response arrival time. Wake phrase detection accepts punctuation, capitalization, `Lazyask`, and a phrase split across nearby final transcript turns. Saying just "Lazy Ask" waits for your next speech turn for up to 6 seconds.

The latest-question selector checks question marks and common English question openings. It uses recent partial meeting transcripts too, so a late final result is less likely to hide the question. This is a heuristic: unclear wording, overlapping voices, or another language may need a direct question. Meeting participants are labeled **Meeting**, not individually named.

Answers use the Responses API with `gpt-4.1-mini` by default. The answer model can be changed in settings. Answers use the transcript and model knowledge; this MVP does not search the web or your files. If the network, account, model, or audio capture fails, the app shows an error and lets you restart. It does not silently reconnect and keep recording.

## Development and Tests

```sh
bash scripts/test.sh
```

Tests cover meeting/folder creation, rename, move, deletion, migration from the old transcript file, transcript isolation across meetings, unlimited retention, demo isolation, wake phrases, answer context limits, local speech turns, out-of-order transcription results, native audio conversion, and mocked streaming answer responses and errors. The test script also finds the test framework in Apple Command Line Tools when full Xcode is not installed.

Project layout:

```text
Sources/LazyAsk/          Mac UI, permissions, audio capture, Keychain, WebSocket client
Sources/LazyAskCore/      Audio/transcript types, speech turns, triggers, answers
Tests/LazyAskCoreTests/   Tests that do not use real devices or paid API calls
Tests/LazyAskNativeTests/ Synthetic audio tests for Apple's PCM converter
Resources/Info.plist      Bundle identity and permission descriptions
scripts/                 Build and test commands
```

For a full live check, play a question in a meeting, confirm that the **Meeting** transcript appears, then say the wake phrase and check the overlay. Also test a direct question, stop/start, a denied permission, and a disconnected network. Automated tests and demo mode do not prove real meeting capture or account access.

## References

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple screen and audio capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [OpenAI Realtime transcription](https://developers.openai.com/api/docs/guides/realtime-transcription)
- [OpenAI streaming responses](https://developers.openai.com/api/docs/guides/streaming-responses)
