# YuE2Kit

YuE2Kit runs YuE2-3B in a macOS or iOS process using the audio.cpp C ABI and Metal. It accepts lyrics and a style, and gives callers interleaved 48 kHz stereo PCM for playback, export, or analysis. One engine owns one resident model session.

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

## Full-context playback in infetit radio

On Apple silicon, Create's **High quality** mode can compose with infetit radio's Metal shaders and pass the complete token sequence to audio.cpp for a single eight-step acoustic pass. An optional PCM callback hands off each finalized waveform tile as it decodes. The player queues those same samples into the saved WAV.

Build the experimental PCM runtime from the pinned audio.cpp release using CMake and the Xcode Metal toolchain. Run these commands from `Packages/YuE2Kit`:

```bash
work=$(mktemp -d)
git clone --depth 1 --branch v0.9.6 https://github.com/0xShug0/audio.cpp.git "$work/audio.cpp"
git -C "$work/audio.cpp" apply "$PWD/Patches/audio-cpp-v0.9.6-waveform.patch"
cmake -S "$work/audio.cpp" -B "$work/build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 -DCMAKE_INSTALL_RPATH='@loader_path' \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DENGINE_ENABLE_OPENMP=OFF -DGGML_OPENMP=OFF -DAUDIOCPP_BUILD_C_API=ON \
  -DAUDIOCPP_MODEL_SET=custom -DAUDIOCPP_MODELS=yue2 -DAUDIOCPP_VERSION=0.9.6
cmake --build "$work/build" --parallel 8 --target audiocpp
```

Copy the compiled library (following the symlink from `$work/build/bin/libaudiocpp.dylib`) to `~/Library/Application Support/YuE2NativeAssets/libaudiocpp-pcm.dylib`. infetit radio also needs its indexed `YuE2MetalAssets` bundle for composing. The optional library enables the hybrid route for High quality and long Radio songs when it exports the waveform callback. The current patch also exports `audiocpp_yue2_session_run_observed` for live synthesis step counts and cancellation between steps. Rebuild older PCM runtimes to enable those updates. Audio begins after composition and full-song acoustic synthesis, during waveform decoding.

To enable the faster **High Quality** and Radio runtime on Mac, build a second copy of the PCM runtime with `Patches/audio-cpp-v0.9.6-wide-attention.patch` also applied. Copy the fast build to `~/Library/Application Support/YuE2NativeAssets/libaudiocpp-pcm-fast.dylib`, set its install name to `@rpath/libaudiocpp-pcm-fast.dylib` with `install_name_tool -id`, and re-sign it with `codesign --force --sign -`. It uses the same eight midpoint steps and full song context. Keep the standard PCM library available for fallback.

On M3 Max, the fast runtime selects a 32-query attention tile at 5,000 or more acoustic query rows. The wider tile reuses key and value loads across more queries while preserving the order of each query's operations. Shorter contexts use the 16-query tile where supported.

### iPhone and iPad

From the repository root, build the arm64 iOS 18+ framework with Xcode's device SDK and CMake. The script uses the same pinned audio.cpp release and waveform and attention patches as the optimized Mac runtime. Pass an existing audio.cpp checkout or `file://` clone URL as the first argument to build from a local mirror.

```bash
bash Packages/YuE2Kit/Scripts/build-ios-runtime.sh
```

infetit radio embeds and signs the generated `Packages/YuE2Kit/.build/apple-mobile/YuE2Audio.framework` when building for `iphoneos`. Provision both `YuE2MetalAssets` and `YuE2NativeAssets` in the app's Application Support directory or app resources. The native directory contains `yue2.json` from audio.cpp v0.9.6 and the `weights` subdirectory described above. The indexed bundle supplies token composition, and the native bundle supplies acoustic synthesis and waveform decoding.

High Quality and Radio select the embedded renderer when both bundles are available. After composition, the renderer loads the native session, runs eight midpoint steps with the whole song in context and emits PCM while decoding the waveform. The app releases that session before composing the next song. The current iOS song cap still applies, and an explicit Early Playback choice continues to use the windowed pipeline. Simulator builds and installations without the framework or native weights use the indexed renderer.

### Reference recordings on Mac

Build the [`yue-tokenize` target](https://github.com/hangry-labs/yue2) for Apple silicon with `-DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON`. With upstream revision `bb064cf`, rename its top-level `VERSION` file and update the `file(STRINGS …)` path in `CMakeLists.txt` when building on a case-insensitive volume. The original filename can shadow the C++ `<version>` header. Under `~/Library/Application Support/YuE2NativeAssets/Reference`, place the executable beside `MERT-v2-FullSong-Q8_0.gguf` and `yue2-mothersuperior-realaudio-tokenizer-v4-Q8_0.gguf` from the [GGUF publisher](https://huggingface.co/botp/YuE2-GGUF). The app invokes Metal locally when a recording is selected. The extracted codes provide musical context for a new take. Exact opening audio is preserved when remixing a generated Library song.

## Run the benchmark

From this directory, with the verified runtime available on disk:

```bash
swift run -c release yue2-bench /path/to/libaudiocpp.dylib /path/to/weights /path/to/lyrics.txt song.wav \
  --spec /path/to/yue2.json --play
```

Pass `--full 2500` for a ceiling of 100 seconds. Pass `--preview` with the v0.9.6 library to test progressive playback. `--mute` exercises the AVAudioEngine queue silently.

On an M3 Max, a warmed four-step windowed preview queued its first three seconds in 1.85 seconds and stayed at least 0.44 seconds ahead through a 30.88-second take. Fixed windows make the first seconds more stable across continuations. They still re-synthesize previous windows and a busy GPU can run out of buffered audio.

Keep model loading and the warm-up off the click path. Start an immediate preview when the machine can keep up. For scored play, wait for enough generated audio and lookahead notes to cover the scene's measured load. The benchmark prints negative lead whenever a chunk misses its deadline on a continuous playback timeline.
