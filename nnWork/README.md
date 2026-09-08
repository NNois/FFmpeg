# FFmpeg (HAP fork)

## Docs par sujet
- [HAP.md](HAP.md) — Hap 1/Alpha/Q/M/A/R/HDR (usage encodeur + options)
- [BASIS_UNIVERSAL.md](BASIS_UNIVERSAL.md) — backend BC7/BC6H de Hap R/HDR
- [H265-ALPHA.md](H265-ALPHA.md) — HEVC alpha (encode OK, decode KO) → détails [README_HEVC-Alpha.md](README_HEVC-Alpha.md)
- [BINK2.md](BINK2.md) — décodeur Bink Video 2 (SDK RAD)
- [NDI.md](NDI.md) — device NDI (libndi_newtek) entrée/sortie
- [DECKLINK.md](DECKLINK.md) — cartes Blackmagic (device decklink)
- [SUPER-RESOLUTION.md](SUPER-RESOLUTION.md) — upscale IA avec alpha : libplacebo + shaders CNN, filtre `sr_rtx` (NVIDIA RTX VSR)
- [LIBVPXENC.md](LIBVPXENC.md) — VP9 alpha : auto-sélection du pixel format (formats expérimentaux masqués), erreur ABI libvpx

## Build quick start
- Fresh PC only: from an Administrator PowerShell, `./build-msys-install-msys2.ps1` (installs MSYS2 itself via Chocolatey to `C:\tools\msys64`).
- Terminal: MSYS2 MINGW64.
- Install deps: `./build-msys-install-dependencies.sh`.
- Build portable tools: `./build-mysys-shared.sh` (bundles DLLs).
- Copy with DLLs: `./ build-msys-copy-with-dlls.sh /c/path/to/app`.

## What changed
- HAP: fixed HapQ YCoCg transform, added HapA (alpha-only), added HapR (BC7 modes 1/5/6/7), added HapH (BC6H HDR encode), and rebuilt HapM (Hap Q Alpha) multi-texture/chunk headers to match the spec. Quality via `-bc7_quality` (HapR) / `-bc6_quality` (HapH), both 0..4. BC7/BC6H now encoded through basis_universal. See [HAP.md](HAP.md).
- libvpx-vp9: upstream 8.1 advertises experimental alpha formats (yuva422p, yuva444p, gbrap, 10/12-bit alpha) that the encoder then refuses without `-strict experimental`; the automatic pixel format selection picked them for RGBA / 4:4:4 alpha sources (e.g. after `sr_rtx`) and failed. `vp9_get_supported_config` in `libavcodec/libvpxenc.c` now hides them unless strict experimental, so auto-selection falls back to `yuva420p`.
- Toolchain: Snappy/HAP enabled plus libvfw32 and build utilities wired into the latest build scripts.
- Codecs kept: x264, x265, libvpx, vorbis/opus/lame, plus the usual FFmpeg stack.

## HAP formats (quick map)
| HAP format     | Texture compression                                     | FourCC | Bits                     |
|----------------|---------------------------------------------------------|--------|--------------------------|
| HAP            | BC1 (DXT1)                                              | Hap1   | 8-bit RGB                |
| HAP Alpha      | BC3 (DXT5)                                              | Hap5   | 8-bit RGBA               |
| HAP Q          | Scaled YCoCg DXT5 (BC3 with color transform)            | HapY   | 8-bit RGB                |
| HAP Q Alpha    | Scaled YCoCg DXT5 (BC3) + BC4 (separate alpha)          | HapM   | 8-bit RGBA               |
| HAP Alpha-Only | BC4 (alpha only)                                        | HapA   | 8-bit A                  |
| HAP R          | BC7 (BPTC)                                              | Hap7   | 8-bit RGBA               |
| HAP HDR        | BC6U/BC6S (BPTC float, unsigned/signed)                 | HapH   | 16-bit half-float RGB    |

## HAP checklist
- [x] Working formats: Hap1 (DXT1), Hap5 (DXT5), HapY (DXT5-YCoCg scaled), HapA (RGTC1 alpha-only), HapM (DXT5-YCoCg + RGTC1 alpha), HapR (Hap7, BC7 modes 1/5/6/7 only).
- [x] HapA alpha-only support (details: `libavcodec/hapenc.c`, `libavcodec/hapdec.c`, `libavformat/isom_tags.c`).
- [x] HapQ YCoCg transform fix (details: `libavcodec/texturedsp.c` and HAP decode path).
- [x] HapM multi-texture headers and chunk layout (details: `libavcodec/hapenc.c`, `libavcodec/hapdec.c`, `libavcodec/bsf/hapqa_extract.c`).
- [x] HapR (Hap7) encode/decode with BC7 modes 1/5/6/7 only (details: `libavcodec/hapenc.c`, `libavcodec/hapdec.c`, `libavcodec/bc7dec.c`).
- [x] Quick checks: `./ffmpeg.exe -encoders | grep hap` and `./ffmpeg.exe -decoders | grep hap`.
- [x] Encode examples: `-c:v hap -format hap|hap_alpha|hap_q|hap_a|hap_m|hap_r` (optionally add `-chunks N`; HapR quality: `-bc7_uber N`).
- [x] HapR `-bc7_uber` range: `0..4` (0 = fastest/default, higher = slower with better quality).
- [x] MOV tags added for Hap HDR (`HapH`) (tag only, no codec support).
- [x] HAP R (FFmpeg): BC7 decode is limited to modes 1/5/6/7 (bc7enc output). Add modes 0/2/3/4 for full BC7 compatibility.
- [ ] HAP R (FFmpeg): evaluate `bc7e` or `bc7enc_rdo`  for better quality (RDO, broader mode use) vs `bc7enc16`.


## TODO: BC7 (HapR) status and work
- Decoder status: current FFmpeg BC7 decode is limited to modes 1/5/6/7 (matches `bc7enc` output). Full compatibility needs modes 0/2/3/4.
- Encoder status: FFmpeg uses `bc7enc` with modes 1/5/6/7. Consider `bc7e` or `bc7enc_rdo` if we want more modes and/or RDO.
- Source refs: `C:\ff\bc7enc16` (original, fast single-file encoder, modes 1 and 6 only, strong on opaque + simple alpha, perceptual YCbCr metric, simple codebase); `C:\ff\bc7e` (Binomial, SIMD ISPC encoder, very fast vs ispc_texcomp, perceptual metrics, full modes, archived with latest in `bc7enc_rdo`); `C:\ff\bc7enc_rdo` (BC1-7 encoders with RDO + entropy reduction, ships latest `bc7e.ispc` optional and `bc7enc.cpp` fallback, includes `bc7decomp.cpp/.h`).
- BC7 modes quick notes: Mode 0 = 3 subsets, RGB, 4-bit endpoints + pbits, 3-bit indices (no alpha). Mode 1 = 2 subsets, RGB, 6-bit endpoints + shared pbits, 3-bit indices (no alpha). Mode 2 = 3 subsets, RGB, 5-bit endpoints, 2-bit indices (no alpha). Mode 3 = 2 subsets, RGB, 7-bit endpoints + pbits, 2-bit indices (no alpha). Mode 4 = 1 subset, RGBA, RGB 5-bit + A 6-bit endpoints, dual index sets, component rotation (alpha). Mode 5 = 1 subset, RGBA, RGB 7-bit + A 8-bit endpoints, 2-bit indices, component rotation (alpha). Mode 6 = 1 subset, RGBA, 7-bit endpoints + pbit (8-bit effective), 4-bit indices (alpha). Mode 7 = 2 subsets, RGBA, 5-bit endpoints + pbits, 2-bit indices (alpha).



