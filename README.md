# Clover Image Tiny for iOS

Native, private image generation on iPhone with SwiftUI, Core ML, and
[Clover Image Tiny](https://huggingface.co/neonforestmist/Clover-Image-Tiny).

## Screenshots

| Create | Models & Styles | Library |
|:---:|:---:|:---:|
| ![Create screen with a generated image](Screenshots/create-output.png) | ![Model picker: Clover downloadable, styles locked until it is installed](Screenshots/models.png) | ![Library grid of generated images](Screenshots/library.png) |
| On-device generation | Base first, styles opt-in | Saved artwork |

## Features

- Runs image generation on the device after model installation
- Apple-style SwiftUI interface for iPhone and iPad
- Prompt and negative-prompt controls
- 4–100 inference steps with both a slider and precise stepper
- Saved generation timelines with previews every 1–10 steps
- Guidance from 1.0–20.0
- Reproducible seeds with seed randomization
- One to four images per generation
- Native 512 × 512 output without post-generation cropping
- PNDM and DPM-Solver++ schedulers
- NumPy and PyTorch-compatible random generators
- Neural Engine, automatic, and GPU compute preferences
- Local artwork library and Photos export
- Dedicated **Inpainting** tab between Create and Library for image selection,
  mask painting, and local edits
- Base-first downloads: install Clover, then add only the styles you want
- Mix up to three downloaded or imported LoRAs with independent strengths
- Import a Clover-compatible `.safetensors` style from **On My iPhone → Clover → Imported Styles**
- Visible downloads in **On My iPhone → Clover → Models**
- Immutable model revisions with byte-count and SHA-256 verification

Output resolution is fixed at 512 × 512 by the converted Core ML models.

## Requirements

- Xcode 16 or newer
- iOS 18 or newer
- A physical iPhone or iPad for Core ML image generation
- Enough free storage for the selected Core ML model

The repository and app bundle do not contain the model weights.

## Run the app

1. Clone this repository.
2. Open `Clover.xcodeproj`.
3. Select the `Clover` scheme and your Apple development team.
4. Choose a connected iPhone or iPad. Simulator is suitable for UI work.
5. Build and run.
6. Open **Models & Styles** in the app and download a model, or open
   **Inpainting** to paint a mask over a source image.

The app reads its versioned catalog from
[`neonforestmist/Clover-Image-Tiny-CoreML`](https://huggingface.co/neonforestmist/Clover-Image-Tiny-CoreML).
Installed files are checked against the catalog before use.
Downloaded files are visible in the Files app under
**On My iPhone → Clover → Models**. Existing downloads from earlier builds are
migrated into that folder when possible.

Clover installs first: its shared components (text encoder, VAE, safety
checker, tokenizer) plus one stateful base U-Net, about 1.5 GB total. Monet,
Pointillism, and Watercolor Anime are then **optional 6,927,128-byte LoRA
style downloads**: `Monet.safetensors`, `Pointillism.safetensors`, and
`Watercolor-Anime.safetensors`. The Swift pipeline converts up to three selected
styles to FP16 and places them into separate rank-16 blocks in the U-Net's
mutable Core ML state; it never downloads another ~648 MB U-Net. Each style comes from its compact
`-lora-coreml` Hugging Face repo, which contains only the named style weights,
state mapping, model card, and license. Styles stay locked until Clover is
installed. You can also side-load a Clover-compatible LoRA by placing its
`.safetensors` file directly in **On My iPhone → Clover → Imported Styles**.
The app detects the filename and loads its tensors into the installed Clover
U-Net. Older full Core ML model folders remain supported.

## Inpainting resources

Inpainting is a separate, standalone Core ML pipeline because its U-Net has a
9-channel input and needs a VAE encoder. It is an optional **1,672 MB** download;
installing the app or Regular Clover does not download it. Download the companion resource
bundle from
[`neonforestmist/Clover-Image-Tiny-Inpaint-CoreML`](https://huggingface.co/neonforestmist/Clover-Image-Tiny-Inpaint-CoreML),
or open the **Inpainting** tab and tap **Download 1,672 MB**. Clover fetches the
repository manifest, verifies every resource by size and SHA-256, and stores
the bundle at **On My iPhone → Clover → Models → Inpainting**. The
runtime entry point is `CoreMLInpaintingService`:

The v2 manifest is pinned to an immutable Hugging Face revision. Existing v1
installations are detected by their missing/old revision marker and the app
offers the v2 download instead of silently continuing to use stale weights.
Generation defaults to DPM-Solver++, 20 steps, CFG 6.0, live previews every
five steps, and a focused crop with a 96-pixel context margin. Final output is
composited through the exact mask so unpainted pixels stay unchanged.
Live Step Previews and their interval can be changed in Inpainting Settings;
turning them off skips latent preview rendering and does not store timeline
frames, reducing generation overhead and storage use.

The native editor includes Paint and Erase tools, adjustable brush size,
Undo/Redo, and Clear Mask. Imported images open in a square crop editor with
drag-to-position, 1×–4× zoom, rule-of-thirds grid, reset, and a precise
512×512 preview. Cropping is non-destructive until **Use Crop** is tapped.
When a pinned model revision changes, verified files that are unchanged are
reused locally and only changed resources are downloaded.

```swift
let service = CoreMLInpaintingService()
var settings = GenerationSettings()
settings.prompt = "replace the masked area with a tiny glass greenhouse"
let result = try await service.generate(
    resourcesURL: modelFolder,
    request: InpaintingRequest(image: sourceImage, mask: whiteMeansRegenerateMask),
    settings: settings,
    cancellation: GenerationCancellationToken(),
    progress: { _ in }
)
```

The service encodes the masked image locally, sends
`[noisy latent, mask, masked-image latent]` to the batch-one U-Net, and
composites untouched pixels from the original image. Small masks are cropped
with surrounding context for 512×512 inference and then mapped back through
the exact mask, so object edits receive useful latent resolution without
changing unpainted pixels. Inpainting uses DPM-Solver++ by default; 20 steps is
recommended and 50 is the on-device maximum. The bundle is converted
for the SD 1.4-class 512×512 architecture on iOS 18; validate final latency
and memory on a physical device rather than Simulator.

The current Inpainting U-Net does not expose Clover's dynamic LoRA state.
Regular Clover LoRA files target its 4-channel U-Net and are not interchangeable
with this 9-channel model. An inpainting-specific LoRA can be fused before a
separate Core ML conversion, but dynamic Inpainting LoRA selection is not
included in this release.

## On-device behavior

After installation, prompts and generated images stay on the device. Network
access is used to refresh the catalog and download model files from Hugging
Face.

Live Step Previews render a lightweight RGB approximation directly from the
current denoising latent every 1–10 steps. This keeps the VAE decoder out of the
denoising loop, avoiding repeated Core ML memory spikes on iPhone; the finished
image still uses the full VAE decoder. Preview frames are
stored as compressed JPEGs inside the finished artwork's folder. The Library
still shows one tile per final image; opening that image—or using the controls
below the newest Create output—reveals a slider for scrubbing through the saved
steps. Share and Save operate on the currently selected frame. The Library
detail screen can also download the complete timeline as a ZIP containing each
saved preview and the full-resolution final step. More frequent previews still
increase generation time, storage use, and battery use.

The stateful U-Net uses a batch-one input and runs classifier-free guidance in
two serial passes, cutting the largest activation peak roughly in half. It runs
with CPU and GPU compute because its mutable style buffers are not
execution-planned reliably on the Neural Engine. Other pipeline components
still honor the selected compute preference. Validate real generation on an
iPhone or iPad; the Simulator is suitable for UI testing. The first generation
may take longer while Core ML compiles and caches its graphs.

The current Core ML U-Net exposes three rank-16 blocks inside each mutable LoRA
state. Clover concatenates the down matrices and weighted up matrices, which
produces the exact sum of up to three independently selected styles without
cross terms. Empty blocks stay zero, so the same U-Net also runs base Clover.

## Project structure

```text
Clover/
├── App/          App entry point and navigation
├── Features/     Create, inpainting, model picker, settings, and library screens
├── Models/       Generation settings, artwork, and catalog types
├── Services/     Core ML inference, downloads, storage, and Photos export
└── Support/      Assets, colors, and app configuration
```

The app vendors the small Swift runtime from Apple's
[`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion) project.
Its model loader is adapted to create an iOS 18 `MLState`, populate 144 mutable
LoRA tensors from a standard Diffusers safetensors file, and keep that state for
every denoising step. Apple's license is retained in the vendored package.

The model-picker artwork comes from the MIT-licensed Phosphor collection via
Iconify. See [THIRD_PARTY_ASSETS.md](THIRD_PARTY_ASSETS.md) for attribution.

### Safety-checker behavior

Regular Create and Inpainting do not construct or run a safety checker. This
is a fixed runtime policy rather than a UI or scheme setting, so a valid image
cannot be discarded after live previews finish.

Generation progress reserves its final portion for work after denoising. The
bottom status now reports **Decoding final image**, **Checking final image**,
**Applying the exact mask** (Inpainting), and **Saving to Library** instead of
showing 100% while Core ML and local persistence are still working.

If an inpainting seed produces a collapsed black/invalid edit, Clover retries
up to two more times with deterministic follow-up seeds. The seed that actually
succeeds is shown in the editor and saved with the finished Library artwork.

## Regenerate the Xcode project

The checked-in project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
```

## License

The iOS source code in this repository is licensed under the
[Apache License 2.0](LICENSE).

Downloadable Clover Image Tiny model weights and derivative style models are
licensed separately under
[CreativeML Open RAIL-M](https://huggingface.co/neonforestmist/Clover-Image-Tiny/blob/main/LICENSE).
The Apache-2.0 license for this application does not relicense those model
weights. Third-party dependencies retain their respective licenses.
