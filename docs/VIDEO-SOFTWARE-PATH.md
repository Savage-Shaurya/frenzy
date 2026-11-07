# Video without the hardware encoder (approach B)

Written 7 Nov 2026. Nothing was encoded or decoded to write this. Facts come from the macOS 27.0.1 SDK headers, the
plug-in `Info.plist` files in `/System/Library/Video/Plug-Ins`, `otool -L` / `nm -u` on those plug-ins, and read-only
`ioreg`. Every speed number below is an **estimate** until the gated throughput test runs. Read `VIDEO-SAFETY.md` first.

## 1. Does macOS ship software H.264 and HEVC encoders? Yes.

| Codec | Encoder ID | Name | Bundle | Hardware? | Links IOKit? |
|---|---|---|---|---|---|
| H.264 | `com.apple.videotoolbox.videoencoder.h264` | Apple H.264 (SW) | `AppleH264SW.bundle` (VCP AVC) | no | **no** |
| HEVC | `com.apple.videotoolbox.videoencoder.hevc.vcp` | Apple HEVC (SW) | `VCPHEVC.bundle` | no | **no** |
| AV1 | `com.apple.videotoolbox.videoencoder.av1.sw` | AOM AV1 (SW) | `AV1EncoderSW.bundle` | no | no (uses Metal, the GPU) |
| H.264 | `...videoencoder.ave.avc` | Apple H.264 (HW) | `AppleVideoEncoder.bundle` | **AVE** | yes |
| HEVC | `...videoencoder.ave.hevc`, `...hevc.ave` | Apple HEVC (HW / AVE) | `AppleVideoEncoder`, `AppleAVEEncoder` | **AVE** | yes |
| HEVC | `...videoencoder.hevc.gva` | Apple HEVC (HW) | `AppleGVAHEVCEncoder.bundle` | Intel only | |

The two software plug-ins import only `VTEncoderSession*` callbacks, CoreMedia, CoreVideo and (HEVC) IOSurface. No
`IOServiceOpen`, no `VTMotionEstimation*` (the AVE motion-estimation helper), no `VTCompressionSessionCreate`. So once
chosen, they have no route to the AVE driver of their own.

## 2. Is the choice honoured by AVAssetWriter?

| Question | Answer |
|---|---|
| Can AVAssetWriter take an encoder specification? | Yes. `AVVideoEncoderSpecificationKey` ("a dictionary containing `kVTVideoEncoderSpecification_*` keys", top level of the video settings) is in `AVVideoSettings.h`, **macOS only**. This is AVFoundation's own API, not direct VTCompressionSession use. |
| What does "hardware off" mean? | `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder = false`: "hardware encode will never be used" (`VTCompressionProperties.h`). |
| What we set | All three: `EncoderID` = the software ID above, `EnableHardware... = false`, `RequireHardware... = false`. Pinning the ID means VideoToolbox has no choice to make. |
| Proven on this Mac? | **Not yet.** Documented behaviour plus static evidence only. The proof is step 1 of the test plan below. |
| Decode side | AVAssetReader can't take a decoder specification (only `AVVideoDecompressionPropertiesKey`, properties not selection), so reading still uses the hardware decoder (AVD, its own `dart-avd`, not implicated in any panic). The synthetic tests below never decode. |
| What still uses AVE in the app | `AVAssetExportSession` presets (`video.to-mp4` when not passthrough, `video.to-hevc` in `VideoActions.swift`) take no encoder specification. They must move to the writer path to be software. Also check: ImageIO HEIC writing (`image.to-heic`, and HEIC fixtures in `ImageActionTests`, `ImagePrivacyTests`, `NewFormatTests`) is an HEVC encode and **may** use AVE. Not verified; worth one probe run. |

## 3. The code

| File | What |
|---|---|
| `Sources/HaloConverters/SoftwareVideoEncoding.swift` | `encoderSpecification(_:)`, `writerSettings(_:)`, `forcingSoftware(_:)` (pins settings built elsewhere), `violations(in:)` / `isSoftwareOnly(_:)` (catches every way back to hardware), `bitRate(...)`, `installedEncoders()` (reads plug-in plists only, never VideoToolbox), `route(aveUserClients:forceSoftware:)` + `settings(_:for:)` (approach A's fallback: busy or unknown AVE count means software), `AVEStatus.userClientCount()` (read-only IORegistry count, nil when unreadable). |
| `Tests/HaloConvertersTests/SoftwareVideoTests.swift` | "Software video settings": 12 tests (14 cases, all green 7 Nov), no encoding. "Software video encoding": gated by `HardwareVideoTests.allowed`, serialized, draws frames in memory, samples the AVE count every 20 ms, holds the session open 0.5 s at both ends so a short-lived AVE session can't slip between samples, checks the output by its container only. |
| `scripts/video-safety-probe.sh` | `check` (count now, who holds AVE) and `watch -- <cmd>` (refuses to start unless the count is 0, samples `AppleAVE2UserClient` every 0.1 s, streams VideoToolbox / AVE logs, verdict + exit 3 if the count ever rose). Tried only with `true` and `false`. |

Approach A (`AVTranscoder.swift`, `HardwareEncodeGate.swift`) already calls `forcingSoftware` and
`softwareEncoderInstalled`. Its own counter returns 0 when the registry can't be read; `AVEStatus` returns nil and
`route` treats nil as busy. Pick one rule; failing safe (software) is the better one.

## 4. First real runs (founder's yes first, work saved, Chrome / FaceTime / OBS quit, one at a time)

```
cd apps/halo
scripts/video-safety-probe.sh check        # must say AppleAVE2UserClient = 0
FRENZY_VIDEO_TESTS=1 scripts/video-safety-probe.sh watch -- \
  swift test -j 2 --scratch-path .build/video-b --no-parallel \
  --filter 'SoftwareVideoEncodingTests/tinyH264'
```
Then `tinyHEVC`, then `tinyHEVCMain10`, then `throughput1080p`, each only after the previous verdict was "AVE stayed at 0".
If the count ever rises: don't kill anything, let it finish, stop.

## 5. Speed and quality (ESTIMATES for an M5 Pro, 15 cores)

| Path | 1080p30 speed | Size for the same look | Notes |
|---|---|---|---|
| AVE HEVC (today) | 300+ fps | 1x | The thing that panics. |
| Apple SW H.264 | ~100-150 fps (est.) | ~1.5-1.7x HEVC | Plays everywhere. Supports multipass (imports `VTMultiPassStorage`). |
| Apple SW HEVC | ~20-40 fps (est.) | ~1x, maybe better than AVE | A 10 min 1080p clip: ~8-15 min. 4K: ~4x slower. Main10 / HDR unproven. |
| SVT-AV1 preset 8-10 | ~30-80 fps (est.) | ~0.7-0.8x HEVC | Needs engine work (below). |
| kvazaar ultrafast / fast | ~30-80 fps (est.) | ~1.1-1.3x HEVC | Needs engine work. |
| openh264 | ~150+ fps (est.) | ~2x HEVC (Constrained Baseline mostly) | Licence problem, below. |

Default plan: SW HEVC for "Compress", with H.264 SW for speed on long clips or when HEVC is refused; the bitrate rule
is in `bitsPerPixel` (0.055 HEVC, 0.085 H.264, both estimates to tune on real footage).

## 6. Fallback: the LGPL media engine with a CPU encoder

Add one encoder to `scripts/build-media-engine.sh` (`--enable-libsvtav1` / `libkvazaar` / `libopenh264`, the
`verify` step's `video_encoders` allowlist, the licence copy). All three are BSD, so the engine stays LGPL. Never x264
or x265 (GPL). It runs in its own sandboxed child process, so a crash kills the helper, never the kernel.

| Encoder | Licence | Patents | Plays on Macs | iPhones | Browsers |
|---|---|---|---|---|---|
| SVT-AV1 (AV1) | BSD-3-Clause-Clear | AOMedia Patent Licence 1.0, royalty free | Hardware decode on M3 and later; macOS 27 also ships `AV1DecoderSW.bundle`, so older Macs may play it (unverified) | iPhone 15 Pro and later (hardware) | Chrome, Firefox, Edge everywhere; Safari only with hardware decode |
| kvazaar (HEVC) | BSD-3-Clause | HEVC patent pools (Access Advance, Via LA): **our** exposure, which Apple's own encoder covers | Yes | Yes | Safari yes; Chrome/Edge where the OS has a decoder; Firefox partial |
| openh264 (H.264) | BSD-2-Clause source | Cisco pays the H.264 royalties **only** for its own prebuilt binary that the user downloads from Cisco. A copy we build or bundle is not covered. Downloading it at run time breaks Frenzy's offline rule. **Out.** | Yes | Yes | Yes |

Recommendation order: (1) Apple SW HEVC / H.264 through AVAssetWriter, once the probe proves AVE stays at 0;
(2) SVT-AV1 in the engine if (1) fails the probe or is too slow, with H.264 SW kept for "plays everywhere";
(3) kvazaar only after a patent decision.

## 7. Result (7 Nov 2026): x264 in the engine is the video path

Founder: open source is fine, no compromise on quality. Measured on this Mac, all CPU, the hardware encoder count stayed 0:

| Path | 60 s real 1080p clip | VMAF mean | Worst 1% | Worst frame |
|---|---|---|---|---|
| Apple SW HEVC | about 12 fps; a 5 min clip did not finish in 24 min (stopped) | - | - | - |
| Apple SW H.264, same size | 10.6 s | 77.8 | 34.4 | 25.1 |
| x264 slow 2-pass, same size | 10.2 s | 94.0 | 86.3 | 81.7 |
| x264 slow CRF 20, no cap | 10.0 s | 97.1 | 94.4 | 92.0 |

Apple's path also showed brief hardware encoder blips (count 1 for a moment) during "software" encodes; an idle Mac showed none.

Shipped: `X264Compress` (Compress CRF 20, Smaller CRF 22 + 1080p, preset slow, no bitrate cap; result not 5% smaller = "already small").
HDR stays on Apple HEVC Main10 (x264 is 8-bit). MP3 inside MP4 is invisible to macOS, so only AAC/ALAC are copied.

Long runs through the app's own Compress action (phone-like stand-in: Big Buck Bunny re-saved at 26-28 Mbps, 2 sound tracks):

| Clip | Size | Time | Quality |
|---|---|---|---|
| 5 min | 946 MB to 171 MB (82% smaller) | 63 s | all 8,998 frames, both sound tracks |
| 10 min 34 s | 2.1 GB to 407 MB (81% smaller) | 155 s | VMAF 97.2, worst 1% 93.6, worst 86.4 |

Still on the hardware chip (gated, one at a time): the MP4 and HEVC buttons (AVAssetExportSession presets). Next: move them to x264 / software.

## 8. All video buttons on x264 / x265 (7 Nov 2026, late)

Engine now also has x265 4.1 (8-bit + 10-bit, CPU, NEON, no SVE). Every button checked on real clips, hardware encoder 0 each time:

| Button | Encoder | Test | Time | Quality |
|---|---|---|---|---|
| HEVC | x265 medium CRF 20 | 60 s 1080p H.264 | 15.9 s | VMAF 96.6, worst 91.0 |
| MP4 | x264 slow CRF 18 | 20 s HEVC MOV | 4.1 s | VMAF 97.7, worst 95.2 |
| Compress, HDR | x265 Main10 CRF 22 | 20 s HLG 10-bit, 29.6 MB | 7.2 s, 4.0 MB | HLG + BT.2020 + 10-bit kept |
| WebM to MP4 | x264 | 10 s VP9 | 3.6 s | - (no VP9 decoder in the lab) |
| WebM to HEVC | x265 | 10 s VP9 | 4.3 s | - |

Still on Apple's encoder (gated, one at a time): HDR to MP4 only (it needs Apple's HDR to SDR tone mapping).
Not run: the old gated suites (VideoCompression, VideoHDR, EngineVideoOut) make their fixtures with AVAssetWriter, which uses
the hardware encoder; their fixtures must move to the engine before they are safe to run.

## 9. Last chip path gone, full test pass (8 Nov 2026)

HDR to MP4 now also skips Apple's encoder: Apple's decoder tone-maps through an AVVideoComposition and frames go through a FIFO to x264 (`ToneMappedMP4.swift`). Without the engine, video encoding throws `MediaEngine.missing`; there is no Apple fallback.

Bugs found and fixed:

| Bug | Fix |
|---|---|
| B-frame delay made every frame 50 ms late in Apple's readers | `negative_cts_offsets` |
| Creation date and camera model lost (FFmpeg box placement) | `QuickTimeTags.swift` moves mdta to moov/meta |
| Colour labels missing | `write_colr` + `setparams` (untagged SDR labelled BT.709) |
| AAC timing shift from `-avoid_negative_ts` | Flag removed |
| MP3-in-MP4 invisible to macOS | Only AAC/ALAC copied |
| Compress subtitle "Same resolution" too long for the ring | Now "Same size" |

Test fixtures now come from the developer FFmpeg CPU encoders, never AVAssetWriter, so the old gated suites run safely.

| Run (probe watching) | Result | Hardware encoder peak |
|---|---|---|
| Full unit run, `FRENZY_VIDEO_TESTS=1` | 711/711 | 0 (1,936 samples) |
| `scripts/e2e-actions.sh`, real app, video included | 413 PASS, 0 FAIL, 0 SKIP | 0 |

`apps/halo/LICENSE` added (GPL v2 or later + bundled component notes). App DMG 12 MB. Open: HEIC/AVIF output still uses the chip; source must be published before the app is given out.
