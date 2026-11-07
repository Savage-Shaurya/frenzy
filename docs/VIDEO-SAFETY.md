# Video safety: why Frenzy panicked the Mac, and how to encode without doing it again

Written 7 Nov 2026 from reading only: three panic logs, the three swiftpm-testing-helper crash reports, both
`AVTranscoder.swift` files, the test fixtures and public sources. Nothing was encoded, decoded, built or run to
write this. The only commands run were `ioreg` reads (no encoding).

## The evidence, in short

| Item | What it shows |
|---|---|
| All 3 panics | `dart-ave0 ... DART(CPUDART) error: SID 0 PTE invalid exception on read of DVA 0x1000...` `(CTE 0x10 ...)` `@AppleT8110DART.cpp:2386`, macOS 27.0.1 (26A434), T6050. Panicking thread is in `kernel_task`, inside `AppleT8110DART` (the DART fault interrupt). So the video encoder chip (AVE) read memory that had already been unmapped. The panic is asynchronous: no app code is on the stack. |
| Panic 1, 04:09:48 | `swiftpm-testing-helper` crashed at 04:09:05 (`CFRelease() called with NULL` in `-[AVAssetReader cancelReading]`). Panic came **43 s later**. A `VTEncoderXPCService` (pid 34327, up 135 s) was still alive with its client gone. |
| Panic 2, 04:22:08 | Same crash at 04:21:20. Panic **48 s later**. Orphaned `VTEncoderXPCService` pid 5423 (up 177 s). |
| Crash reports 1 and 2 | At the moment of the crash, **two or three encoders in the one test process were all stuck** in `xpc_connection_send_message_with_reply_sync` inside `RemoteVideoEncoder_EncodeFrame`: the direct `VTCompressionSessionEncodeFrameWithOutputHandler` in `sampleOne` (AVTranscoder.swift:474 in that build), the AVAssetWriter's own `mediaprocessor.videocompression` thread, and the test fixture writer (`AVFixtures.writeMovie`, VideoAudioFixtures.swift:168/172). Meanwhile two threads called `cancelReading` on the same reader at the same time: `halo.transcode.monitor` (`Pump.check`) and `halo.transcode` (`Pump.stopEngines`). That race is the `CFRelease(NULL)` crash. |
| Panic 3, 18:25:03 (serial run, copies on, writer stopped first) | No app crash. The helper (pid 79312) had `com.apple.videotoolbox.compressionQueue` and `videomediaconverter` alive. Its `VTEncoderXPCService` (pid 83136) had **two encoder connections and two `AVE_UCRecv` threads**, so two AVE sessions from one test process. Chrome had a third AVE session open (`VTEncoderXPCService` pid 1203). |
| Public report | Apple Developer Forums thread 831532 (June 2026, iPhone 16 Pro, iOS 26.5): byte-for-byte the same signature, `dart-ave1 ... DART(CPUDART) error: SID 0 PTE invalid exception on read of DVA 0x10001ff4080 (CTE 0x10 ...)` from `AppleT8110DART.cpp`. Trigger: **two concurrent hardware transcodes**. Serial runs were clean. An Apple engineer said they reproduced a matching panic and passed it on; FB23045975. Apple's line is that many sessions are "valid" and limits should give "error codes rather than crashes", so this is an OS bug, not a documented limit. https://developer.apple.com/forums/thread/831532 |

## 1. What in the panicking code most likely triggers it (ranked by evidence)

| Rank | Cause | Evidence | Lines |
|---|---|---|---|
| 1 | **More than one AVE encode session alive at once** (direct `VTCompressionSession` next to the `AVAssetWriter` session, plus other sessions in the same process and other apps). | Panic 3 snapshot: 2 AVE sessions from the test process + 1 from Chrome. Crashes 1 and 2: 2 to 3 encoders from one process all blocked on the encoder service at once. Apple's forum case has the identical panic string with exactly this trigger and Apple reproduced it. | Now file: `sampleOne` creates its own hardware session, 461-466 (`encoderSpecification: nil` = hardware by default), up to 3 of them per job (`sampleRanges`, 406-416), on `AVSupport.blockingQueue`, not tied to the writer's lifetime. `probeQualityMode` 373-381 creates yet another hardware session (`RequireHardwareAcceleratedVideoEncoder`) lazily from whatever thread first asks. Tests: `@Suite("Video compression")`, `("Video actions")`, `("Video HDR")`, `("Video hardening")` are not `.serialized`, and fixtures encode with AVAssetWriter on their own queue in parallel with transcodes. Old file: one AVAssetWriter session per job, no direct VT at all (Sources/HaloConverters/AVTranscoder.swift 40-110). |
| 2 | **Short-lived sessions created and torn down fast, sometimes with frames still in flight.** | Each compress job now makes about 5 AVE sessions (probe + up to 3 samples + writer) and kills 4 of them within seconds. The panic is a late read of unmapped memory, which is what a teardown racing the chip looks like. Not separable from rank 1 with the data we have. | `defer { VTCompressionSessionInvalidate(session) }` 464. Early exits skip `VTCompressionSessionCompleteFrames` (482): `try cancel.check()` 471 throws and `guard status == noErr else { return nil }` 480 returns, both with frames still queued, then invalidate runs. Old file has nothing like this. |
| 3 | **The test process dying while AVE still had work** (the `cancelReading` race). | Panics 1 and 2 came 43 s and 48 s after the helper crashed, with an orphaned `VTEncoderXPCService` still running. When a client dies, its buffers are unmapped from the IOMMU; if the encoder was wedged, its late read faults. This explains panics 1 and 2, not 3. | Now file: `Pump.check` calls `reader.cancelReading()` from `monitorQueue` (750) while `stopEngines` calls it on `queue` (848). Old file only ever calls `cancelReading` on its one serial queue (335). |
| 4 | Constant-quality mode (`kVTCompressionPropertyKey_Quality`). | No evidence either way. It is a supported, documented property; the forum case did not use it. It only matters because it is what made the direct-VT sampling necessary. | 286-300, 515 |
| 5 | IOSurface lifetime from the decoder pool (`alwaysCopiesSampleData = false`). | Weak. The old file ran for days with copies **off**, including cancel-at-many-moments tests, real 4K and 10-minute clips, and never panicked. Panic 3 happened with copies **on** (now file 311, 448). Copies are still sensible, they just are not the cause. | Old 59, now 311/448 |

**Bottom line:** the panic is an Apple bug in the macOS 27 / T8110-DART AVE path, and the new code walked straight into
it by running several hardware encode sessions at once and churning them. The old path never did that.

## 2. Is this a known issue?

| Source | Finding |
|---|---|
| https://developer.apple.com/forums/thread/831532 | Same panic text, same DART driver, iOS 26.5 on A18 Pro. Concurrent hardware transcodes. Apple reproduced it. FB23045975. No fix announced as of what is public. |
| https://forums.macrumors.com/threads/new-16-macbook-pro-m1-max-panic-crash-related-to-t6000-dart-is-it-hardware.2340871 | Older `dart-ave1` panic on an M1 Max. Shows AVE DART faults are not new, but no root cause given. |
| https://developer.apple.com/forums/thread/821372?page=2 | M5-only kernel panics with DART errors, but on `dart-apcie0` (network extension). Different device; shows M5 + macOS 26/27 has had other DART-related panics. |
| https://trac.ffmpeg.org/ticket/10771 | `hevc_videotoolbox` failing with error -12908 on Sonoma; not a panic. Workaround `-allow_sw 1`. |
| HandBrake / OBS | No public `dart-ave0` panic report found. |

Not found: any public macOS 27 or M5 Pro report of `dart-ave0` specifically. Treat it as the same bug as FB23045975
until shown otherwise. Worth filing our own Feedback with the three `.panic` files and a description (not a repro run).

## 3. Safest encoding approaches on this Mac (ranked by kernel-panic risk)

| Rank | Approach | Touches AVE? | Notes |
|---|---|---|---|
| 1 | **CPU library in its own process**: SVT-AV1 (BSD-3-Clause-Clear + AOMedia patent licence), kvazaar (HEVC, BSD-3-Clause since 2.0) | No. Plain CPU code, no kernel driver | Worst case the helper crashes, never the kernel. Costs: slower; AV1 plays in hardware only on M3 and later (software dav1d elsewhere); kvazaar's HEVC carries HEVC patent pool exposure (Access Advance, Via LA) that Apple's own encoder covers for us; openh264 source is BSD but Cisco's patent cover applies **only** to Cisco's prebuilt binary downloaded separately by the user, not one we build or bundle (https://scancode-licensedb.aboutcode.org/cisco-avch264-patent.LICENSE, https://lwn.net/Articles/572205/). |
| 2 | **AVAssetWriter with Apple's software encoder**: `AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]` | Should not. "false" means hardware encode is never used (Apple docs, https://developer.apple.com/tutorials/data/documentation/videotoolbox/kvtvideoencoderspecification_enablehardwareacceleratedvideoencoder.md) | Must be **proven** on this Mac with the protocol below (AVE user-client count stays 0). Keeps Apple's codec licensing. Slow for 4K HEVC. The decoder (AVD, `dart-avd`) is a different chip and IOMMU and has not faulted. |
| 3 | **AVAssetWriter, average bitrate, the old proven path** | Yes | Days of real use with no panic. Safe enough to ship **only** with: one encode at a time across the whole app (a process-wide gate, also around test fixtures), no direct `VTCompressionSession` anywhere, all reader/writer calls on one serial queue, never kill the process mid-encode. Still exposed to the OS bug if another app (Chrome, FaceTime, OBS) encodes at the same time. |
| 4 | **AVAssetExportSession presets** | Yes | Apple manages the session lifecycle, one session per export. Same AVE exposure as rank 3, less control over size, and not tested on this Mac. |
| Never | Direct `VTCompressionSession` next to an AVAssetWriter, sample-encode passes, quality probes that open hardware sessions, parallel video test suites. | Yes, several at once | This is what panicked. |

**Recommendation:** ship rank 3 now (old file, already in `Sources/`), with the gate and with `.serialized` on every
video test suite. Prototype rank 2 next as the default if the AVE count proof passes and speed is acceptable. Keep
rank 1 as the long-term fully safe option (SVT-AV1 first: cleanest licence).

## 4. Safe test protocol

Do these in order. Stop at the first surprise.

| Step | How | Pass |
|---|---|---|
| 0. Static check | `grep -rn "VTCompressionSession" Sources/` and `nm -u` on the built binary for `_VTCompressionSession*` | No direct VT encode calls in the path under test |
| 1. Quiet machine | Quit Chrome, FaceTime, Zoom, OBS, screen recording, Photos. Save all work. Then `ioreg -l -w0 -d2 \| grep -o '"AppleAVE2UserClient"=[0-9]*'` | Count is 0 (verified readable on this Mac, 7 Nov: `"AppleAVE2UserClient"=0`) |
| 2. Watch in a second terminal | `while true; do date +%T; ioreg -l -w0 -d2 \| grep -o '"AppleAVE2UserClient"=[0-9]*'; pgrep -l VTEncoderXPCService; sleep 0.2; done` and `log stream --level debug --predicate 'process == "VTEncoderXPCService" OR subsystem == "com.apple.videotoolbox" OR eventMessage CONTAINS[c] "AVE"'` | For a software path: count stays 0 the whole time |
| 3. Session-level check before any frame | For a VT software session: read `kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder` right after creating it, and `VTCopyVideoEncoderList` to see which encoder ID matches the spec. Encoder IDs containing `ave` are hardware | Property is false, encoder ID is not an AVE one, count still 0 |
| 4. Smallest first encode | One process, no parallel tests (`swift test --no-parallel --filter <one test>`), synthetic 320x240, 10 frames, H.264, software spec, no cancel | Finishes, count stayed 0 |
| 5. Grow slowly | 1 s 1080p, then 10 s 1080p, then 10 s 4K, then a real clip. Each run alone | Same |
| 6. Cancel tests last | Only after 5 clean runs. Cancel on the pump queue only | Same |

Notes:
- `powermetrics` has no documented AVE counter, so it is not a reliable check. Use the `ioreg` count.
- If the count goes above 0 during a software-path test, the path is wrong. Do **not** `kill -9` the process: tearing
  a client down mid-encode is what preceded panics 1 and 2. Let it finish or quit normally, then fix the code.
- For a hardware path (rank 3), the count should never go above 1 while Frenzy encodes alone.

## 8 Nov 2026: no hardware encoder in video

Every video path now encodes on the CPU inside the sandboxed media engine: GPL FFmpeg 9.0.2 + x264 b35605ac + x265 4.1, no VideoToolbox.

| Job | Uses | Hardware encoder? |
|---|---|---|
| H.264 out (Compress, MP4 button) | x264 (`Sources/HaloConverters/X264Compress.swift`) | No |
| HEVC out, incl. 10-bit HDR | x265 | No |
| HDR to MP4 | Apple's decoder tone-maps through an AVVideoComposition, frames go through a FIFO to x264 (`ToneMappedMP4.swift`). Decoding never touches the encoder | No |
| Metadata fix | `QuickTimeTags.swift` moves FFmpeg's mdta box from moov/udta/meta to moov/meta so macOS reads creation date and camera model | No |
| No engine present | Video encoding throws `MediaEngine.missing`. Apple's encoder is never a fallback. AVTranscoder's encode path is unreachable | No |
| HEIC / AVIF image writing | macOS ImageIO, which can only write them with the hardware encoder. Behind `HardwareEncodeGate` (one at a time, busy check) | **Yes** (still open) |

Engine flags added: `-movflags +use_metadata_tags+negative_cts_offsets+write_colr` (no faststart, so the tag move never shifts media), a `setparams` filter that labels untagged SDR as BT.709, the rawvideo demuxer (only for the FIFO), `-stats_period 0.2`.

Test switches:

| Switch | Turns on | Uses the chip? |
|---|---|---|
| `FRENZY_VIDEO_TESTS=1` | Video tests. Fixtures (AVFixtures.movie, the variable-frame-rate clip) are made by the developer FFmpeg (`~/.local/bin/ffmpeg`) CPU encoders, never AVAssetWriter | No |
| `FRENZY_HEIC_TESTS=1` | Any HEIC/AVIF write in a test process (guard in `ImageSupport.swift` and the test fixture writers). Without it the write throws. HEIC input tests read the macOS wallpaper thumbnail `/System/Library/Desktop Pictures/.thumbnails/Big Sur Aerial.heic` | Yes |
| `FRENZY_APPLE_ENCODER_TESTS=1` (on top of `FRENZY_VIDEO_TESTS=1`) | The "Software video encoding" suite (Apple software encoder, retired path) | Apple encoder |

Removed or rewritten because they drove Apple's encoder: busy-encoder fallback test, two "transcoder settings" canApply HDR tests (measured: they opened the hardware encoder), export-cancel tests (now passthrough), disk-full test (now the engine with a freeSpace hook). Before the HEIC guard, one HEIC test ran ungated in every normal run (it opened the hardware encoder once per run; no crash).

Measured proof, with `scripts/video-safety-probe.sh` watching:

| Run | Result | AppleAVE2UserClient peak |
|---|---|---|
| Full unit run, `FRENZY_VIDEO_TESTS=1` | 711/711 pass | 0 over 1,936 samples |
| `scripts/e2e-actions.sh` against the real app (sandboxed worker, video, OGG/Opus inputs, read-only volume to Downloads) | 413 PASS, 0 FAIL, 0 SKIP | 0 |

Worker self-test now checks the engine is GPL and has no VideoToolbox encoder.

Still open: HEIC/AVIF output uses the chip (founder to choose: keep gated, hide, or build CPU HEIC with libheif + x265). Live drag e2e rerun: result not recorded here yet.
