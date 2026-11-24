# Vibe Player

A native iPhone, iPad, and macOS radio and song-idea prototype built with SwiftUI and AVFoundation. Open `VibePlayer.xcodeproj` and run the VibePlayer scheme on iOS/iPadOS 18 or later, or macOS 15 or later. Choose “My Mac” for the native macOS app.

Radio contains selectable stations with genres, moods, instruments, voice, and tempo adjusted directly by sliding their pills. Press Play to prepare the first song and start filling the queue. The full-screen player shows the current song’s position, queued songs, and the next render’s stage. The mini player fills as audio plays or Radio prepares a song. Settings and bookmarks are saved locally. The animated player background responds to audio level and transient changes, with Reduce Motion support.

Create lets you describe an idea, save it to Library, or ask the writing model to draft lyrics. YuE2 receives the sound description and lyrics as separate fields. The app counts the combined prompt with YuE2’s tokenizer and asks the writing model for a shorter version if needed. Tap the Create dock to see the active render, the playable buffer, and the prompts waiting in the session’s generation queue. You can submit another prompt from the composer while a song is rendering.

The iPhone and iPad player fills the available window and uses one continuous layout at every width. iPhone and iPad use system navigation, and Mac uses a standard navigation sidebar. On Mac, the player opens in the main window, and Playback menu commands and keyboard shortcuts control playback. Sound pills support dragging, clicking, and keyboard arrows. Imported songs use embedded artwork when available. On iOS and macOS 26 and later, player controls use native Liquid Glass, with a material fallback on older systems. The iOS UI test target exercises radio, sound editors, creation, library, file picker, playback, and landscape navigation.

## Preparing music generation

Each radio station is converted into a `MusicGenerationRequest` by `MusicPromptBuilder`. The request snapshots the station name, style, voice choice, a random seed, a range of 2,000–4,200 YuE2 semantic frames at 25 frames per second, and eight synthesis steps. The app clamps that range to the installed model. For a vocal sound, the writing model drafts original lyrics before rendering. Instrumental and zeroed voice requests keep lyrics empty. If no voice control is selected, vocals are the default.

Active genre, mood, and instrument controls are ordered by their intensities and mapped to subtle, moderate, or prominent cues; zero-intensity controls are omitted. These are textual hints, not precise audio-mix or tempo controls. The voice choice is included when selected and active; if no voice control is selected, vocals are used. New selections allow one voice choice at a time; for an older saved station containing both, the higher intensity wins, with alphabetical order breaking a tie. Generation is canceled when the station, its settings, or the loaded audio changes, and a late result is discarded. Once a renderer is available, a committed slider or sound-selection change schedules a new song after a short debounce; existing audio continues until the replacement is ready.

`YuE2GenerationBackend` connects `Packages/YuE2CoreML` to the player. Create and Radio require the indexed version 3 bundle named `YuE2MetalAssets` in the app bundle or Application Support. Metal generates the song tokens. Core ML runs prompt prefill, acoustic synthesis, and waveform decoding using the CPU and GPU. Create stops when the model emits its end token or reaches its maximum length.

The Create Metal menu offers two modes. **Early playback** renders overlapping sections and builds a buffer before starting. If the buffer runs low, playback fades out and waits for more audio, then fades back in at the same position. **High quality** finishes composing, synthesizes the song with its full acoustic context, and starts playback once the waveform decoder has built a buffer. Vocal prompts default to High quality and instrumental prompts default to Early playback where available. An explicit mode selection applies to subsequent prompts. On iOS, the Create cap is 4,200 frames (2:48 of audio). Completed Create songs save to Library automatically.

The package exporter builds an asset bundle from separately obtained YuE2 weights. The weights and compiled assets are not included in this repository; use assets compiled for the device’s platform. YuE2 weights are distributed under CC BY-NC 4.0, separately from this project's MIT license. [Package instructions](Packages/YuE2CoreML/README.md)

To run the standalone prompt checks on a Mac:

```sh
xcrun swiftc -parse-as-library VibePlayer/MusicGeneration.swift Tests/MusicPromptBuilderChecks.swift -o /tmp/vibe-prompt-checks
/tmp/vibe-prompt-checks
```

Songwriting settings in Create store the user’s Gemini API key in the device Keychain after a short connection test. When a key is configured, the app normally sends writing requests to Gemini over HTTPS. If the connection fails or there’s no key, it uses Apple’s on-device Foundation Model when available. Users can supply their own lyrics for vocal songs. Create shows render progress and allows cancellation.


## Songs and radio

Radio renders one song at a time and keeps up to two ready. **Prepare songs** fills the queue while playback is paused. A ready song crossfades near the end of the current track. Committed sound changes discard the old queue and crossfade as soon as the updated song is ready. If the queue empties, the progress bar stays visible while Radio waits and playback resumes automatically. A station that requests vocals can fall back to instrumental music when its lyric request fails.

Like a generated radio song to copy its audio into the persistent Songs library. Created songs are saved there automatically. Radio renders that are not saved are temporary and are removed after playback or on the next app launch. The library supports playback and explicit deletion. Song ideas and station bookmarks remain separate.

## License

The project is available under the [MIT License](LICENSE). Third-party models and dependencies are subject to their own licenses; in particular, the separately obtained [YuE2 weights](https://huggingface.co/m-a-p/YuE2-3B) are licensed under CC BY-NC 4.0.
