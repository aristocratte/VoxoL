# Third-party notices

No third-party model weights are bundled in this repository or application. VoxoL downloads the
following weights only after an explicit user action. Inference remains local after installation:

- NVIDIA Parakeet TDT 0.6B v3 — `CC BY 4.0` —
  <https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>
  - Core ML conversion provider: `mweinbach1/parakeet-tdt-0.6b-v3-coreml` — `CC BY 4.0` —
    <https://huggingface.co/mweinbach1/parakeet-tdt-0.6b-v3-coreml>
- Qwen3.5-0.8B — `Apache-2.0` — <https://huggingface.co/Qwen/Qwen3.5-0.8B>
  - Experimental MLX 4-bit conversion provider: `mlx-community/Qwen3.5-0.8B-4bit` —
    `Apache-2.0` — <https://huggingface.co/mlx-community/Qwen3.5-0.8B-4bit>
- MLX Swift LM `2.31.3` — `MIT` — <https://github.com/ml-explore/mlx-swift-lm>
- MLX Swift `0.31.6` (resolved transitively) — `MIT` —
  <https://github.com/ml-explore/mlx-swift>
- Core ML Tools, used only from `Tools/` when introduced —
  <https://github.com/apple/coremltools>

VoxoL's `ParakeetCore` source is adapted from `parakeet-coreml-swift`, copyright 2026 Max
Weinbach, revision `75aec2a1c991319657ff4dec5f602c12da6c5012`, under Apache License 2.0:
<https://github.com/mweinbach/parakeet-coreml-swift>. The license and modification notice are in
`Packages/ParakeetCore/`.

The pinned upstream and conversion-provider revisions, exact sizes, download URLs and SHA-256
checksums are recorded in `Models/manifests/runtime-models.json`.

Development benchmarks can download a deterministic subset of FLEURS — `CC BY 4.0` —
<https://huggingface.co/datasets/google/fleurs>. This corpus is never bundled with VoxoL.
The optional Parakeet training pipeline uses only the pinned FLEURS `train` and `dev` splits and
preserves the same attribution; FLEURS `test` remains evaluation-only.
The optional MediaSpeech French benchmark is also `CC BY 4.0` and is downloaded from OpenSLR
SLR108: <https://www.openslr.org/108/>. Its audio copyright remains with the original owners.

Optional development-only model training and conversion tools:

- NVIDIA NeMo, pinned to revision `2381f42f6979449b5b99538f8f80135831009b51` —
  `Apache-2.0` — <https://github.com/NVIDIA-NeMo/NeMo>
- FluidInference Mobius, whose direct-NeMo encoder wrapper and component-export approach are
  adapted by the development-only Core ML exporter, pinned to revision
  `d2398af6042684a1b06dbc6951bdb50e1cf0366a` —
  `Apache-2.0` — <https://github.com/FluidInference/mobius>
