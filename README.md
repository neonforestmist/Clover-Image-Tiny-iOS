# Clover Image Tiny for iOS

Native, private image generation on iPhone with SwiftUI, Core ML, and
[Clover Image Tiny](https://huggingface.co/neonforestmist/Clover-Image-Tiny).

![Clover Create screen](Screenshots/create.png)

## Features

- Runs image generation on the device after model installation
- Apple-style SwiftUI interface for iPhone and iPad
- Prompt and negative-prompt controls
- 4–100 inference steps and guidance from 1.0–20.0
- Reproducible seeds with seed randomization
- One to four images per generation
- PNDM and DPM-Solver++ schedulers
- NumPy and PyTorch-compatible random generators
- Neural Engine, automatic, and GPU compute modes
- Local artwork library and Photos export
- Downloadable base and style models with progress, cancellation, and removal
- Immutable model revisions with byte-count and SHA-256 verification

Output resolution is fixed at 512 × 512 by the converted Core ML models.

## Requirements

- Xcode 16 or newer
- iOS 17 or newer
- A physical iPhone or iPad is recommended
- Enough free storage for the selected Core ML model

The repository and app bundle do not contain the model weights.

## Run the app

1. Clone this repository.
2. Open `Clover.xcodeproj`.
3. Select the `Clover` scheme and your Apple development team.
4. Choose a connected device or Simulator.
5. Build and run.
6. Open **Models & Styles** in the app and download a model.

The app reads its versioned catalog from
[`neonforestmist/Clover-Image-Tiny-CoreML`](https://huggingface.co/neonforestmist/Clover-Image-Tiny-CoreML).
Shared resources are stored once, while each selected variant supplies its
chunked U-Net. Installed files are checked against the catalog before use.

Available style variants are published separately:

- [Monet](https://huggingface.co/neonforestmist/clover-image-tiny-monet-lora-coreml)
- [Pointillism](https://huggingface.co/neonforestmist/clover-image-tiny-pointillism-lora-coreml)
- [Watercolor Anime](https://huggingface.co/neonforestmist/clover-image-tiny-watercolor-anime-lora-coreml)

These current Core ML style packages are U-Nets with their LoRA weights fused
during conversion. They are complete replacement U-Nets, not small LoRA files
applied dynamically by the iOS runtime.

## On-device behavior

After installation, prompts and generated images stay on the device. Network
access is used to refresh the catalog and download model files from Hugging
Face.

A physical device can use the Apple Neural Engine. Simulator builds use
CPU/GPU execution because Simulator does not expose the Neural Engine. The
first generation may take longer while Core ML compiles and caches its graphs.

## Project structure

```text
Clover/
├── App/          App entry point and navigation
├── Features/     Create, model picker, settings, and library screens
├── Models/       Generation settings, artwork, and catalog types
├── Services/     Core ML inference, downloads, storage, and Photos export
└── Support/      Assets, colors, and app configuration
```

The app uses Apple's
[`ml-stable-diffusion`](https://github.com/apple/ml-stable-diffusion) Swift
package at a pinned revision.

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
