# YuE2Kit

YuE2Kit runs YuE2-3B in a macOS process using the audio.cpp C ABI and Metal. It accepts lyrics and a style, and gives callers interleaved 48 kHz stereo PCM for playback, export, or analysis. One engine owns one resident model session. Load it when a user enters the generation screen, and reuse it across requests.

## Runtime and weights

Use an Apple Silicon Mac and Swift 6.2 or later. The reference full-song renderer uses the arm64 Metal **library** from [audio.cpp v0.9.4](https://github.com/0xShug0/audio.cpp/releases/tag/v0.9.4) and its [YuE2 model spec](https://raw.githubusercontent.com/0xShug0/audio.cpp/v0.9.4/model_specs/yue2.json). The library archive SHA-256 is `bb1141185d15891d1c6b53f05cd55b0b93614804b340289799cff497fe87cf5b`.

For the experimental preview, use the arm64 Metal library from [audio.cpp v0.9.6](https://github.com/0xShug0/audio.cpp/releases/tag/v0.9.6) and its [YuE2 model spec](https://raw.githubusercontent.com/0xShug0/audio.cpp/v0.9.6/model_specs/yue2.json). Its library archive SHA-256 is `5ad1ee3534c4f53b43a87b9c46105224122fb435fb3abc5938f0cf4b8d6db864`. The bundled ABI header and its license come from v0.9.6.

Use the [audio.cpp GGUF weights](https://huggingface.co/audio-cpp/Yue2-3B-GGUF). Point the engine at one directory containing `yue2-3b-q4_0.gguf`, `yue2-vae-f16.gguf`, and the model's four `sidecars/` files. This package loads the runtime and weights from files provided by the host. Check the [model's CC BY-NC 4.0 license](https://huggingface.co/m-a-p/YuE2-3B) before distributing the model or using it commercially.

## Use in a Mac app

Add this directory as a local Swift package and import `YuE2Kit`.

```swift
let engine = try await YuE2Engine.load(library: libraryURL, weights: weightsURL, modelSpec: specURL)
let prompt = YuE2Prompt(lyrics: lyrics, style: style, seed: 42)
let song = try await engine.render(prompt, frames: 5000)
```

Full-song mode is the default. It uses eight acoustic synthesis steps and the runtime's original acoustic context. The frame count sets a ceiling. A model-generated ending is preserved, and a take that reaches the ceiling fades to silence.

For experimental low-latency playback, load with `mode: .streamingPreview` and call `renderProgressively`. This mode uses fixed four-second acoustic windows with 640 ms of overlap and four synthesis steps by default. Its default checkpoints are 100, 184, 352, 520, and 772 semantic frames at 25 Hz. Custom checkpoints must fall on a window boundary at 100 + 84 × n frames. A session runs one job at a time, and cancellation takes effect between native renders.

Progressive playback re-renders the prefix at each checkpoint. The default schedule is for short previews. Use measured buffer lead and a playback clock to decide when to start a rhythm game and whether to extend the schedule. This package targets macOS. The supplied dylib is a macOS binary.

## Run the benchmark

From this directory, with the verified runtime available on disk:

```bash
swift run -c release yue2-bench /path/to/libaudiocpp.dylib /path/to/weights /path/to/lyrics.txt song.wav \
  --spec /path/to/yue2.json --play
```

Pass `--full 2500` for a ceiling of 100 seconds. Pass `--preview` with the v0.9.6 library to test progressive playback. `--mute` exercises the AVAudioEngine queue silently.

On an M3 Max, a warmed four-step windowed preview queued its first three seconds in 1.85 seconds and stayed at least 0.44 seconds ahead through a 30.88-second take. Fixed windows make the first seconds more stable across continuations. They still re-synthesize previous windows and a busy GPU can run out of buffered audio.

Keep model loading and the warm-up off the click path. Start an immediate preview when the machine can keep up. For scored play, wait for enough generated audio and lookahead notes to cover the scene's measured load. The benchmark prints negative lead whenever a chunk misses its deadline on a continuous playback timeline.
