# e2e-actions: every non-video action, end to end

`scripts/e2e-actions.sh` runs every registered non-video action of the built `dist/Frenzy.app` on every input it
accepts, through the real sandboxed worker (`Frenzy --convert <action-id> FILE...`), then checks each result for real.
No mouse, no UI, no defaults changed.

## Run
| Command | Does |
|---|---|
| `scripts/e2e-actions.sh` | everything (builds the helpers first, about a minute) |
| `scripts/e2e-actions.sh --plan` | builds helpers and fixtures, lists every planned (action, input) pair, converts nothing |
| `--only '^pdf\.'` | only action ids matching the regex |
| `--no-big` | skip the 300-page PDF and the 60-file batch |
| `--app PATH` / `--keep` | another build / keep the temp folder |
| `FRENZY_E2E_DOWNLOADS=1` | also convert from the read-only disk image (Frenzy saves that to ~/Downloads; the test moves its own file back out) |

Exit 0 = all PASS (SKIPs allowed), 1 = a FAIL, 3 = setup problem, 4 = refused for Mac safety.
The table is also saved to `$TMPDIR/frenzy-e2e-actions-build/last-report.md`, with time per action.

## Mac safety (7 Nov 2026 kernel panics, hardware video encoder)
| Rule | How |
|---|---|
| No video in, no video out | no movie fixtures; any `video.*` action or video-named file reaching `--convert` stops the run (exit 4) |
| HEIC and AVIF are video-encoder formats too | `image.to-heic`, `image.to-avif`, and image jobs that would write HEIC (Compress with transparency, a HEIC/AVIF input kept in its format) are SKIPPED. The HEIC fixture is a copied macOS wallpaper thumbnail, decoded only |
| Optional video section | only with `FRENZY_VIDEO_TESTS=1`, one job at a time, after the founder says yes and has saved their work. It runs the skipped HEIC/AVIF jobs and every video action on a 1 s test movie (or `FRENZY_VIDEO_INPUT=/path`) |

## What each case checks
| Check | How |
|---|---|
| Right type | magic bytes, then a real decode: ImageIO, PDFKit (renders page 1), AVAudioFile (every frame), textutil, `unzip -t`, `tar -t`, `ffprobe` if installed |
| Did what it promised | same pixel size, half size, no GPS / no EXIF, page counts (images, split, merge, combine), +90 rotation, audio length, zip/tar round-trip identical, unzip/unpack identical to what was packed, the word "Frenzy" survives into text, Word, RTF and PDF outputs (OCR too) |
| Originals safe | SHA-256 of every file in the folder before and after, plus all fixtures at the end |
| Nothing stray | only the reported outputs are new, nothing removed, no `.halo-*`, worker staging empty, nothing new in ~/Downloads |
| Names | 255-byte limit, keeps the input's stem, never overwrites, second run gives "name 2.ext" |
| Nasty inputs | Hindi and emoji, double spaces, names starting with `-`, a 243-byte name, 0-byte files, corrupt PNG/PDF/DOCX/ZIP, wrong extensions, encrypted PDF, PDF with JavaScript, zip with `../`, SVG with outside links or entities, read-only disk image, 60-file batch, 300-page PDF, a batch with one broken file (partial result) |
| Worker | self-test and network probes at start, after the crash test and at the end; `--worker-crash-test pdf.to-images` on the big PDF |
| Engine | not linking VideoToolbox, no video encoder in `-encoders`, `video.foreign-to-mp4/hevc` not registered, no `video.*` offered for any non-video file |

## Files
| File | What |
|---|---|
| `tool.swift` | fixtures and independent verifiers, Apple frameworks only |
| `registry.swift` | asks Frenzy's own registry (built from `Sources/` with `-enable-testing`) which actions take a file; converts nothing |

## Not covered
- OGG and Opus inputs: nothing on the Mac can write them. Drop real files into the fixtures to cover them.
- The "nothing new in ~/Downloads" check can flag a file you download yourself during the run if its name starts like a fixture's (`photo`, `report`, `notes`...).
