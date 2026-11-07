#!/usr/bin/env bash
# Every registered NON-VIDEO action of the built Frenzy.app, on every input it accepts, through the real sandboxed
# worker (`Frenzy --convert <action-id> FILE...`), with each output checked for real. See scripts/e2e-actions/README.md.
#
#   scripts/e2e-actions.sh                 run everything (default app: dist/Frenzy.app)
#   scripts/e2e-actions.sh --app PATH      test another build
#   scripts/e2e-actions.sh --only REGEX    only action ids matching REGEX (grep -E), e.g. '^pdf\.'
#   scripts/e2e-actions.sh --no-big        skip the 300-page PDF and the 60-file batch
#   scripts/e2e-actions.sh --plan          build helpers + fixtures, print every planned (action, input) pair, convert nothing
#   scripts/e2e-actions.sh --keep          keep the temp folder for inspection
#
# MAC SAFETY (7 Nov 2026: three kernel panics from the hardware video encoder, dart-ave0):
# - No video is generated, used as input, or converted. Any video action id or video file reaching a conversion makes the
#   script stop at once (exit 4) unless FRENZY_VIDEO_TESTS=1.
# - HEIC and AVIF are written by the hardware video encoder too, so image.to-heic, image.to-avif, and any image action
#   that would write HEIC (Compress on an image with transparency, anything that keeps a HEIC/AVIF input's format) are
#   SKIPPED unless FRENZY_VIDEO_TESTS=1. HEIC is only decoded (from a small macOS wallpaper thumbnail).
# - The separate section at the end runs only with FRENZY_VIDEO_TESTS=1, one job at a time. Set that only after the
#   founder says yes in the current chat and has saved their work.
#
# Touches nothing outside $TMPDIR: fixtures, runs and outputs live in $TMPDIR/frenzy-e2e-actions.XXXXXX (removed at the
# end unless --keep), helpers build into $TMPDIR/frenzy-e2e-actions-build. Reads (never writes) ~/Downloads, the worker's
# staging folder and DiagnosticReports to prove nothing leaked there. The read-only disk image is mounted inside the
# temp folder. Converting FROM that image makes Frenzy save to ~/Downloads, so that one case runs only with
# FRENZY_E2E_DOWNLOADS=1 (and then the test moves its own new file out of Downloads into the temp folder).
#
# Exit: 0 all PASS (SKIPs allowed), 1 any FAIL, 3 setup problem, 4 refused for safety.
set -uo pipefail
export LC_ALL=C COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="$ROOT/scripts/e2e-actions"
APP="$ROOT/dist/Frenzy.app"
KEEP=0; ONLY=""; BIG=1; PLAN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --no-big) BIG=0; shift;;
    --plan) PLAN=1; shift;;
    --keep) KEEP=1; shift;;
    *) echo "unknown option $1 (see the header of $0)"; exit 3;;
  esac
done
VIDEO=0; [[ "${FRENZY_VIDEO_TESTS:-}" == "1" ]] && VIDEO=1
DOWNLOADS_OK=0; [[ "${FRENZY_E2E_DOWNLOADS:-}" == "1" ]] && DOWNLOADS_OK=1
TIMEOUT="${FRENZY_E2E_TIMEOUT:-300}"
BIG_TIMEOUT="${FRENZY_E2E_BIG_TIMEOUT:-900}"

APP="$(cd "$APP" 2>/dev/null && pwd -P)" || { echo "missing app bundle (run scripts/build-app.sh)"; exit 3; }
BIN="$APP/Contents/MacOS/Frenzy"
[[ -x "$BIN" ]] || { echo "missing $BIN"; exit 3; }
WORKER_XPC="$APP/Contents/XPCServices/com.snappycrew.frenzy.worker.xpc"
APP_ENGINE="$WORKER_XPC/Contents/Helpers/frenzy-media-engine"
STAGING="$HOME/Library/Containers/com.snappycrew.frenzy.worker/Data/tmp/HaloStaging"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASH_TEXT="converter stopped while reading"
SMALL_TEXT="is already as small as Frenzy can make it."

TMPROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
BUILD="$TMPROOT/frenzy-e2e-actions-build"
WORK="$(mktemp -d "$TMPROOT/frenzy-e2e-actions.XXXXXX")" || exit 3
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in "$TMPROOT"/frenzy-e2e-actions.*) ;; *) echo "refusing: work dir $WORK is not inside $TMPROOT"; exit 3;; esac
FIX="$WORK/fixtures"; SRC="$WORK/src"; LOGS="$WORK/logs"
MANIFEST="$WORK/manifest.tsv"; TIMINGS="$WORK/timings.tsv"; GATED="$WORK/gated.tsv"
mkdir -p "$FIX" "$SRC" "$LOGS" "$WORK/runs" "$WORK/x" "$BUILD"
: > "$MANIFEST"; : > "$TIMINGS"; : > "$GATED"

# ---------------------------------------------------------------- safety, cleanup
MOUNTED=""
safe_rm() { case "$1" in "$TMPROOT"/frenzy-e2e-actions.*) rm -rf "$1";; *) echo "not removing $1 (outside the test's temp folder)";; esac; }
cleanup() {
  if [[ -n "$MOUNTED" ]]; then hdiutil detach "$MOUNTED" -quiet 2>/dev/null || hdiutil detach "$MOUNTED" -force -quiet 2>/dev/null; MOUNTED=""; fi
  chmod -R u+w "$WORK" 2>/dev/null
  if [[ $KEEP == 1 ]]; then echo "kept $WORK"; else safe_rm "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
refuse() { echo; echo "REFUSED (Mac safety): $*"; echo "Video work runs only with FRENZY_VIDEO_TESTS=1, set after the founder says yes."; exit 4; }

VIDEO_EXT=" mp4 m4v mov qt avi mkv webm flv wmv ogv mpg mpeg ts mts m2ts vob 3gp 3g2 divx mxf asf rm rmvb y4m "
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_video_name() { local e; e="$(lower "${1##*.}")"; [[ "$1" == *.* && "$VIDEO_EXT" == *" $e "* ]]; }
# Stops the whole run if a video action or a video file would reach Frenzy without FRENZY_VIDEO_TESTS=1.
video_guard() { # action input...
  local a="$1" p f; shift
  [[ $VIDEO == 1 ]] && return 0
  [[ "$a" == video.* ]] && refuse "video action $a was about to run"
  for p in "$@"; do
    while IFS= read -r f; do
      is_video_name "$f" && refuse "video file ${f##*/} was about to be converted"
    done < <(find "$p" -print 2>/dev/null)
  done
}
# 0 when the job would drive the hardware video encoder (video, HEIC or AVIF out).
encoder_risk() { # action input
  case "$1" in
    video.*|image.to-heic|image.to-avif) return 0;;
    image.compress|image.resize-half|image.strip-metadata)
      local info; info="$("$TOOL" image "$2" 2>/dev/null </dev/null)" || return 1   # undecodable: fails before any encode
      case "$info" in *uti=public.heic*|*uti=public.heif*|*uti=public.avif*|*uti=public.avci*) return 0;; esac
      [[ "$1" == image.compress && "$info" == *alpha=1* ]] && return 0   # Compress keeps transparency as HEIC
      return 1;;
  esac
  return 1
}

# ---------------------------------------------------------------- results
R_NAME=(); R_STATUS=(); R_DETAIL=(); R_TIME=(); FAILS=0; PASSES=0; SKIPS=0
record() { # name status detail [seconds]
  local d="${3//|//}"; d="${d//$'\n'/ }"; [[ ${#d} -gt 400 ]] && d="${d:0:400}..."
  R_NAME+=("${1//|//}"); R_STATUS+=("$2"); R_DETAIL+=("$d"); R_TIME+=("${4:--}")
  case "$2" in PASS) PASSES=$((PASSES + 1));; SKIP) SKIPS=$((SKIPS + 1));; *) FAILS=$((FAILS + 1));; esac
  printf '%-4s %s  (%s)\n' "$2" "$1" "$d"
}

now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", b - a }'; }
with_timeout() { perl -e '$t = shift @ARGV; alarm $t; exec { $ARGV[0] } @ARGV or exit 127' "$@"; }
has_flag() { [[ ",$1," == *",$2,"* || ",$1," == *",$2="* ]]; }
flag_val() { local f; IFS=',' read -r -a f <<< "$1"; for x in ${f[@]+"${f[@]}"}; do [[ "$x" == "$2="* ]] && { echo "${x#*=}"; return; }; done; }
# Real Unicode NFC (iconv's UTF-8-MAC stops at emoji and truncates). Any bytes go through: invalid UTF-8 is kept as is.
nfc() {
  /usr/bin/python3 -I -c 'import sys, unicodedata
for l in sys.stdin.buffer:
    sys.stdout.buffer.write(unicodedata.normalize("NFC", l.decode("utf-8", "surrogateescape")).encode("utf-8", "surrogateescape"))'
}
snapshot() { (cd "$1" && find . -mindepth 1 | LC_ALL=C sed 's|^\./||' | nfc | LC_ALL=C sort); }
hash_tree() { find "$1" -type f -print0 | xargs -0 shasum -a 256 2>/dev/null; }
canon_dir() { (cd "$1" 2>/dev/null && pwd -P); }
kv() { local s=" $1 "; s="${s#* $2=}"; [[ "$s" == " $1 " ]] && return 1; echo "${s%% *}"; }

# ---------------------------------------------------------------- 1. helpers
echo "building helpers into $BUILD ..."
SDK="$(xcrun --show-sdk-path 2>/dev/null)" || { echo "xcrun/swiftc missing"; exit 3; }
ARCH="$(uname -m)"
MODS="$BUILD/mods"; mkdir -p "$MODS"
TOOL="$BUILD/fz-tool"; REG="$BUILD/fz-registry"
swiftc -sdk "$SDK" -swift-version 5 -O -o "$TOOL" "$HERE/tool.swift" > "$BUILD/build-tool.log" 2>&1 \
  || { tail -20 "$BUILD/build-tool.log"; echo "could not build fz-tool"; exit 3; }
COMMON=(-sdk "$SDK" -target "$ARCH-apple-macos14.0" -Onone -I "$MODS" -L "$MODS"
        -plugin-path /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins)
build_lib() {
  local name="$1"; shift
  swiftc "${COMMON[@]}" -swift-version 6 -parse-as-library -enable-upcoming-feature ExistentialAny -enable-testing \
    -module-name "$name" -emit-module -emit-module-path "$MODS/$name.swiftmodule" \
    -emit-library -static -o "$MODS/lib$name.a" "$@" >> "$BUILD/build-registry.log" 2>&1
}
: > "$BUILD/build-registry.log"
build_lib HaloCore "$ROOT"/Sources/HaloCore/*.swift \
  && build_lib HaloConverters "$ROOT"/Sources/HaloConverters/*.swift \
  && swiftc "${COMMON[@]}" -swift-version 5 -lHaloCore -lHaloConverters -o "$REG" "$HERE/registry.swift" >> "$BUILD/build-registry.log" 2>&1 \
  || { tail -20 "$BUILD/build-registry.log"; echo "could not build fz-registry"; exit 3; }

ENGINE_ON=0
[[ -x "$APP_ENGINE" && "$(sysctl -n hw.optional.arm64 2>/dev/null)" == 1 ]] && ENGINE_ON=1
# An engine this script may run directly to make MP3/FLAC/WebP fixtures. The bundled one is signed for the worker's
# sandbox and may refuse to start on its own, so the source tree's build is the fallback.
RUN_ENGINE=""
for e in "$APP_ENGINE" "$ROOT/vendor/build/arm64/bin/frenzy-media-engine"; do
  if [[ -x "$e" ]] && with_timeout 15 "$e" -hide_banner -version >/dev/null 2>&1 </dev/null; then RUN_ENGINE="$e"; break; fi
done
eng() { with_timeout 60 "$RUN_ENGINE" -nostdin -hide_banner -loglevel error -y "$@" </dev/null; }

"$REG" "$ENGINE_ON" list > "$WORK/actions.tsv" || { echo "registry list failed"; exit 3; }
card_of() { awk -F'\t' -v id="$1" '$1 == id { print $3 }' "$WORK/actions.tsv"; }
only_ok() { [[ -z "$ONLY" ]] || grep -Eq -- "$ONLY" <<< "$1"; }
echo "app: $APP"; echo "registry: $(wc -l < "$WORK/actions.tsv" | tr -d ' ') actions (engine: $ENGINE_ON)"

# ---------------------------------------------------------------- 2. fixtures (no video, no HEIC/AVIF encoding)
D=""
fd() { D="$FIX/$1"; mkdir -p "$D"; }
T() { "$TOOL" "$@" >/dev/null 2>&1 </dev/null; }
add_fixture() { # id name class flags
  if [[ -e "$FIX/$1/$2" ]]; then printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" >> "$MANIFEST"
  else record "fixture $2" FAIL "could not be made"; fi
}
fixture_skip() { record "fixture $1" SKIP "$2"; }

make_fixtures() {
  local i L
  # Images: opaque, with big text so OCR has something to read.
  fd img-png; T png "$D/photo.png" 1200 400 "FRENZY 2026"; add_fixture img-png photo.png good text
  local PNG="$D/photo.png"
  fd img-jpg; T jpeg-gps "$D/camera.jpg" "FRENZY 2026"; add_fixture img-jpg camera.jpg good text,gps
  fd img-gif; T gif-anim "$D/anim.gif" "FRENZY 2026"; add_fixture img-gif anim.gif good text,animated
  fd img-bmp; sips -s format bmp "$PNG" --out "$D/scan.bmp" >/dev/null 2>&1; add_fixture img-bmp scan.bmp good text
  fd img-tiff; sips -s format tiff "$PNG" --out "$D/print.tiff" >/dev/null 2>&1; add_fixture img-tiff print.tiff good text
  # HEIC: copied, never encoded (HEIC encoding uses the hardware video encoder).
  local heic
  heic="$(find "/System/Library/Desktop Pictures" "/Library/Desktop Pictures" -iname '*.heic' -size -3000k 2>/dev/null | head -1)"
  if [[ -n "$heic" ]]; then fd img-heic; cp "$heic" "$D/wallpaper.heic"; add_fixture img-heic wallpaper.heic good notext
  else fixture_skip "wallpaper.heic" "no small HEIC on this Mac to copy; HEIC is never encoded here (hardware encoder)"; fi
  if [[ -n "$RUN_ENGINE" ]]; then
    fd img-webp; eng -f png_pipe -i "file:$PNG" -frames:v 1 -c:v libwebp -pix_fmt yuv420p -f webp "file:$D/web.webp" >/dev/null 2>&1
    add_fixture img-webp web.webp good text
  else fixture_skip "web.webp" "no runnable media engine to write WebP (macOS can't)"; fi
  # Nasty names.
  fd n-hindi; cp "$PNG" "$D/नमस्ते 🎉 photo.png"; add_fixture n-hindi "नमस्ते 🎉 photo.png" good text
  fd n-space; cp "$PNG" "$D/my  holiday photo.png"; add_fixture n-space "my  holiday photo.png" good text
  fd n-dash; cp "$PNG" "$D/-rf --help.png"; add_fixture n-dash "-rf --help.png" good text
  L=""; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do L="${L}नमस्ते"; done
  fd n-long; cp "$PNG" "$D/$L long.png"; add_fixture n-long "$L long.png" good text
  fd n-zero-png; : > "$D/empty.png"; add_fixture n-zero-png empty.png bad
  fd n-zero-pdf; : > "$D/empty.pdf"; add_fixture n-zero-pdf empty.pdf bad
  fd n-zero-txt; : > "$D/empty.txt"; add_fixture n-zero-txt empty.txt either
  fd n-bad-png; { printf '\x89PNG\r\n\x1a\n'; head -c 4096 /dev/urandom; } > "$D/broken.png"; add_fixture n-bad-png broken.png bad
  fd n-bad-pdf; { printf '%%PDF-1.4\n'; head -c 4096 /dev/urandom; } > "$D/broken.pdf"; add_fixture n-bad-pdf broken.pdf bad
  fd n-bad-docx; { printf 'PK\x03\x04'; head -c 4096 /dev/urandom; } > "$D/broken.docx"; add_fixture n-bad-docx broken.docx bad
  fd n-png-as-jpg; cp "$PNG" "$D/secretly-png.jpg"; add_fixture n-png-as-jpg secretly-png.jpg either
  fd n-text-as-png; printf 'hello, I am not a picture\n' > "$D/not-an-image.png"; add_fixture n-text-as-png not-an-image.png bad
  # SVG.
  fd svg; printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="400" height="200" viewBox="0 0 400 200"><rect width="400" height="200" fill="#ffffff"/><circle cx="60" cy="100" r="40" fill="#dd3333"/><text x="120" y="115" font-family="Helvetica" font-size="40">Frenzy</text></svg>' > "$D/logo.svg"
  add_fixture svg logo.svg good -
  fd svg-ext; printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="100" height="100"><image xlink:href="https://example.com/x.png" width="100" height="100"/><image href="file:///etc/hosts" width="10" height="10"/></svg>' > "$D/outside-link.svg"
  add_fixture svg-ext outside-link.svg bad
  fd svg-ent; printf '%s\n' '<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><text x="0" y="50">&c;</text></svg>' > "$D/entities.svg"
  add_fixture svg-ent entities.svg bad
  # PDFs.
  fd pdf-text; T pdf-text "$D/report.pdf" 3; add_fixture pdf-text report.pdf good text,pages=3
  T png "$SRC/ocr.png" 1600 500 "FRENZY 2026"
  fd pdf-scan; T pdf-scan "$D/scanned letter.pdf" "$SRC/ocr.png"; add_fixture pdf-scan "scanned letter.pdf" good ocr,pages=1
  fd pdf-locked; T pdf-encrypt "$FIX/pdf-text/report.pdf" "$D/locked.pdf" "frenzy-test"; add_fixture pdf-locked locked.pdf bad
  fd pdf-js; T pdf-js "$D/with-javascript.pdf"; add_fixture pdf-js with-javascript.pdf good text,pages=1
  fd pdf-dash; cp "$FIX/pdf-text/report.pdf" "$D/--help.pdf"; add_fixture pdf-dash "--help.pdf" good text,pages=3
  fd n-pdf-as-txt; cp "$FIX/pdf-text/report.pdf" "$D/actually-pdf.txt"; add_fixture n-pdf-as-txt actually-pdf.txt either
  if [[ $BIG == 1 ]]; then fd pdf-big; T pdf-text "$D/big 300 pages.pdf" 300; add_fixture pdf-big "big 300 pages.pdf" good text,pages=300,big
  else fixture_skip "big 300 pages.pdf" "--no-big"; fi
  # Documents, from one HTML source through textutil.
  printf '%s\n' '<html><head><meta charset="utf-8"><title>Frenzy</title></head><body><h1>Frenzy document test</h1><p>Hello <b>bold</b> and <i>italic</i>. नमस्ते 🎉</p><ul><li>one</li><li>two</li></ul></body></html>' > "$SRC/doc.html"
  fd doc-html; cp "$SRC/doc.html" "$D/page.html"; add_fixture doc-html page.html good text
  fd doc-txt; printf 'Frenzy notes\nLine two, नमस्ते 🎉\n' > "$D/notes.txt"; add_fixture doc-txt notes.txt good text
  cp "$D/notes.txt" "$SRC/notes.txt"
  fd doc-md; printf '# Frenzy readme\n\n- one\n- **two**\n' > "$D/readme.md"; add_fixture doc-md readme.md good text
  fd doc-csv; printf 'name,value\nFrenzy,1\nनमस्ते,2\n' > "$D/table.csv"; add_fixture doc-csv table.csv good text
  fd doc-cafe; printf 'Frenzy café résumé\n' > "$D/Café résumé.txt"; add_fixture doc-cafe "Café résumé.txt" good text
  local f
  for f in "rtf letter.rtf" "docx essay.docx" "doc old.doc" "odt open.odt" "rtfd rich.rtfd"; do
    set -- $f
    fd "doc-$1"; textutil -convert "$1" -output "$D/$2" "$SRC/doc.html" >/dev/null 2>&1 </dev/null; add_fixture "doc-$1" "$2" good text
  done
  # EPUB, built like a real one (stored mimetype first).
  local E="$SRC/epub"; mkdir -p "$E/META-INF" "$E/OEBPS"
  printf 'application/epub+zip' > "$E/mimetype"
  printf '%s\n' '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>' > "$E/META-INF/container.xml"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">frenzy-test</dc:identifier><dc:title>Frenzy book</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-11-07T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="chapter1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>' > "$E/OEBPS/content.opf"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head><body><nav epub:type="toc"><ol><li><a href="chapter1.xhtml">One</a></li></ol></nav></body></html>' > "$E/OEBPS/nav.xhtml"
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head><body><h1>Frenzy chapter one</h1><p>It was a <b>bright</b> day. नमस्ते 🎉</p></body></html>' > "$E/OEBPS/chapter1.xhtml"
  fd doc-epub; (cd "$E" && zip -X0q "$D/book.epub" mimetype && zip -Xr9Dq "$D/book.epub" META-INF OEBPS) </dev/null
  add_fixture doc-epub book.epub good text
  # Audio: generated PCM, speech, Apple encoders (AAC is AudioToolbox, not the video encoder).
  fd au-wav; T wav "$D/tone.wav" 2; add_fixture au-wav tone.wav good audio
  fd au-aiff
  if ! say -o "$D/speech.aiff" "Frenzy audio test" >/dev/null 2>&1 </dev/null; then
    afconvert -f AIFF -d BEI16 "$FIX/au-wav/tone.wav" "$D/speech.aiff" >/dev/null 2>&1 </dev/null
  fi
  add_fixture au-aiff speech.aiff good audio
  fd au-m4a; afconvert -f m4af -d aac "$FIX/au-wav/tone.wav" "$D/tone.m4a" >/dev/null 2>&1 </dev/null; add_fixture au-m4a tone.m4a good audio
  fd au-caf; afconvert -f caff -d LEI16 "$FIX/au-wav/tone.wav" "$D/tone.caf" >/dev/null 2>&1 </dev/null; add_fixture au-caf tone.caf good audio
  if [[ -n "$RUN_ENGINE" ]]; then
    fd au-mp3; eng -i "file:$FIX/au-wav/tone.wav" -c:a libmp3lame -b:a 128k -f mp3 "file:$D/tone.mp3" >/dev/null 2>&1; add_fixture au-mp3 tone.mp3 good audio
    fd au-flac; eng -i "file:$FIX/au-wav/tone.wav" -c:a flac -f flac "file:$D/tone.flac" >/dev/null 2>&1; add_fixture au-flac tone.flac good audio
  else
    fixture_skip "tone.mp3" "no runnable media engine (macOS has no MP3 encoder)"
    fixture_skip "tone.flac" "no runnable media engine"
  fi
  # OGG and Opus inputs: neither macOS nor Frenzy's engine writes them, so the developer FFmpeg (CPU audio only) does.
  local DEVFF="$HOME/.local/bin/ffmpeg"
  if [[ -x "$DEVFF" ]]; then
    fd au-ogg; "$DEVFF" -hide_banner -loglevel error -y -i "$FIX/au-wav/tone.wav" -c:a libvorbis -q:a 4 "$D/tone.ogg" </dev/null; add_fixture au-ogg tone.ogg good audio
    fd au-opus; "$DEVFF" -hide_banner -loglevel error -y -i "$FIX/au-wav/tone.wav" -c:a libopus -b:a 96k "$D/tone.opus" </dev/null; add_fixture au-opus tone.opus good audio
  else
    fixture_skip "OGG / Opus input" "no developer FFmpeg at $DEVFF to write them; drop a real file in to cover them"
  fi
  # Archives and folders.
  local B="$SRC/bundle"; mkdir -p "$B/sub"
  printf 'Frenzy a\n' > "$B/a.txt"; printf 'Frenzy b\n' > "$B/sub/b.txt"; printf 'नमस्ते\n' > "$B/नमस्ते.txt"; cp "$PNG" "$B/pic.png"
  fd ar-zip; ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$B" "$D/bundle.zip" </dev/null; add_fixture ar-zip bundle.zip good src=bundle
  fd ar-tgz; tar -czf "$D/bundle.tar.gz" -C "$SRC" bundle </dev/null; add_fixture ar-tgz bundle.tar.gz good src=bundle
  fd ar-tar; tar -cf "$D/bundle.tar" -C "$SRC" bundle </dev/null; add_fixture ar-tar bundle.tar good src=bundle
  fd ar-gz; gzip -c "$SRC/notes.txt" > "$D/notes.txt.gz"; add_fixture ar-gz notes.txt.gz good src=notes.txt
  fd ar-xz
  if tar -cJf "$D/bundle.tar.xz" -C "$SRC" bundle </dev/null 2>/dev/null; then add_fixture ar-xz bundle.tar.xz good src=bundle
  else fixture_skip "bundle.tar.xz" "this tar can't write xz"; fi
  fd ar-slip; T zip-entry "$D/evil.zip" "../evil.txt" "escaped"; add_fixture ar-slip evil.zip bad
  fd ar-bad; { printf 'PK\x03\x04'; head -c 2048 /dev/urandom; } > "$D/broken.zip"; add_fixture ar-bad broken.zip bad
  fd folder; cp -R "$B" "$D/My Folder"; add_fixture folder "My Folder" good -
  fd folder2; cp -R "$B" "$D/second folder"; add_fixture folder2 "second folder" good -
  # The 60-file batch (not in the single-file matrix).
  if [[ $BIG == 1 ]]; then
    mkdir -p "$FIX/batch60"
    for i in $(seq -w 1 60); do T png "$FIX/batch60/img-$i.png" 400 150 "FRENZY $i"; done
  fi
}
echo "making fixtures in $FIX ..."
make_fixtures
hash_tree "$FIX" > "$WORK/fixtures.sha"
hash_tree "$SRC" > "$WORK/src.sha"

# Every fixture through the registry (one process): what it resolves as and which actions take it.
FIXPATHS=()
while IFS=$'\t' read -r id name cls flags <&3; do FIXPATHS+=("$FIX/$id/$name"); done 3< "$MANIFEST"
"$REG" "$ENGINE_ON" match ${FIXPATHS[@]+"${FIXPATHS[@]}"} > "$WORK/match.tsv" </dev/null || { echo "registry match failed"; exit 3; }
paste "$MANIFEST" "$WORK/match.tsv" > "$WORK/plan.tsv"
# Refuse before any conversion if a fixture somehow resolved as video.
while IFS=$'\t' read -r id name cls flags mpath mtype mvideo mids <&3; do
  [[ "$mvideo" == "video:1" && $VIDEO == 0 ]] && refuse "fixture $name resolves as video ($mtype)"
  is_video_name "$name" && [[ $VIDEO == 0 ]] && refuse "fixture $name has a video extension"
done 3< "$WORK/plan.tsv"

# ---------------------------------------------------------------- 3. checking one output
CF=""
EMPTY_OK=0     # 1 while checking a document made from an empty input: empty but valid is right
check_file() { # path -> 0/1, CF = detail
  local p="$1" ext hex info
  ext="$(lower "${p##*.}")"; [[ "$p" == *.* ]] || ext=""
  [[ -f "$p" ]] || { CF="not a file: ${p##*/}"; return 1; }
  [[ -s "$p" ]] || { CF="empty file: ${p##*/}"; return 1; }
  hex="$(xxd -p -l 16 "$p" | tr -d '\n')"
  local magic_ok=1
  case "$ext" in
    jpg|jpeg) [[ "$hex" == ffd8ff* ]] || magic_ok=0;;
    png) [[ "$hex" == 89504e470d0a1a0a* ]] || magic_ok=0;;
    gif) [[ "$hex" == 47494638* ]] || magic_ok=0;;
    bmp) [[ "$hex" == 424d* ]] || magic_ok=0;;
    tif|tiff) [[ "$hex" == 49492a00* || "$hex" == 4d4d002a* ]] || magic_ok=0;;
    webp) [[ "${hex:0:8}" == 52494646 && "${hex:16:8}" == 57454250 ]] || magic_ok=0;;
    heic|heif|avif|m4a|mp4|m4v|mov) [[ "${hex:8:8}" == 66747970 || "${hex:8:8}" == 6d646174 || "${hex:8:8}" == 77696465 ]] || magic_ok=0;;
    ico) [[ "$hex" == 00000100* ]] || magic_ok=0;;
    pdf) [[ "$hex" == 255044462d* ]] || magic_ok=0;;
    zip|docx|odt|epub) [[ "$hex" == 504b0304* ]] || magic_ok=0;;
    gz|tgz) [[ "$hex" == 1f8b* ]] || magic_ok=0;;
    rtf) [[ "$hex" == 7b5c727466* ]] || magic_ok=0;;
    mp3) [[ "$hex" == 494433* || "$hex" == fff* || "$hex" == ffe* ]] || magic_ok=0;;
    wav) [[ "${hex:0:8}" == 52494646 && "${hex:16:8}" == 57415645 ]] || magic_ok=0;;
    aif|aiff) [[ "${hex:0:8}" == 464f524d && ( "${hex:16:8}" == 41494646 || "${hex:16:8}" == 41494643 ) ]] || magic_ok=0;;
    flac) [[ "$hex" == 664c6143* ]] || magic_ok=0;;
    caf) [[ "$hex" == 63616666* ]] || magic_ok=0;;
  esac
  [[ $magic_ok == 1 ]] || { CF="${p##*/}: wrong magic bytes for .$ext ($hex)"; return 1; }
  case "$ext" in
    jpg|jpeg|png|gif|bmp|tif|tiff|webp|heic|heif|avif|ico)
      info="$("$TOOL" image "$p" 2>&1 </dev/null)" || { CF="${p##*/}: $info"; return 1; }; CF="$info";;
    pdf)
      info="$("$TOOL" pdf "$p" 2>&1 </dev/null)" || { CF="${p##*/}: $info"; return 1; }
      [[ "$info" == *locked=0* ]] || { CF="${p##*/}: output PDF is locked"; return 1; }; CF="$info";;
    docx|odt|epub)
      unzip -tq "$p" >/dev/null 2>&1 </dev/null || { CF="${p##*/}: zip container fails unzip -t"; return 1; }
      if [[ "$ext" != epub ]]; then
        info="$(textutil -convert txt -stdout "$p" 2>/dev/null </dev/null)" || { CF="${p##*/}: textutil can't read it"; return 1; }
        [[ -n "${info//[[:space:]]/}" || $EMPTY_OK == 1 ]] || { CF="${p##*/}: no text inside"; return 1; }
      fi
      CF="valid $ext";;
    rtf|doc|html|htm)
      info="$(textutil -convert txt -stdout "$p" 2>/dev/null </dev/null)" || { CF="${p##*/}: textutil can't read it"; return 1; }
      [[ -n "${info//[[:space:]]/}" || $EMPTY_OK == 1 ]] || { CF="${p##*/}: no text inside"; return 1; }; CF="valid $ext";;
    zip) unzip -tq "$p" >/dev/null 2>&1 </dev/null || { CF="${p##*/}: unzip -t fails"; return 1; }
      CF="zip ok, $(unzip -Z1 "$p" 2>/dev/null | wc -l | tr -d ' ') entries";;
    gz|tgz)
      if [[ "$p" == *.tar.gz || "$ext" == tgz ]]; then tar -tzf "$p" >/dev/null 2>&1 </dev/null || { CF="${p##*/}: tar -t fails"; return 1; }
      else gzip -t "$p" 2>/dev/null || { CF="${p##*/}: gzip -t fails"; return 1; }; fi
      CF="archive ok";;
    mp4|m4v|mov)   # only ever reached in the FRENZY_VIDEO_TESTS section; reads metadata, encodes nothing
      info="$("$TOOL" movie-check "$p" 2>&1 </dev/null)" || { CF="${p##*/}: $info"; return 1; }; CF="$info";;
    mp3|m4a|wav|aif|aiff|flac|caf)
      info="$("$TOOL" audio "$p" 2>&1 </dev/null)" || { CF="${p##*/}: $info"; return 1; }
      if command -v ffprobe >/dev/null 2>&1; then
        ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$p" </dev/null 2>/dev/null | grep -q audio \
          || { CF="${p##*/}: ffprobe finds no audio stream"; return 1; }
        info="$info ffprobe=ok"
      fi
      CF="$info";;
    txt|md|csv)
      iconv -f UTF-8 -t UTF-8 "$p" >/dev/null 2>&1 || { CF="${p##*/}: not valid UTF-8"; return 1; }
      CF="utf-8 text, $(wc -c < "$p" | tr -d ' ') bytes";;
    *) CF="exists (${p##*/})";;
  esac
  return 0
}

check_tree() { # dir ext-or-any -> 0/1, CF; sets TREE_COUNT
  local dir="$1" want="$2" f n=0 bad=""
  TREE_COUNT=0
  while IFS= read -r f; do
    n=$((n + 1)); [[ $n -gt 400 ]] && continue
    if [[ "$want" != any && "$(lower "${f##*.}")" != "$want" ]]; then bad="unexpected ${f##*/} in folder"; break; fi
    check_file "$f" || { bad="$CF"; break; }
  done < <(find "$dir" -type f ! -name '.DS_Store')
  TREE_COUNT=$n
  [[ -z "$bad" ]] || { CF="$bad"; return 1; }
  [[ $n -gt 0 ]] || { CF="empty folder"; return 1; }
  CF="folder with $n files"; return 0
}

# Whether the word Frenzy is in a file's text. Via a file, not a pipe: with pipefail, grep -q quitting early makes
# a large writer die of SIGPIPE and the check fail although the word is there.
has_frenzy() { # path
  local t="$WORK/text.$$"
  text_of "$1" > "$t" 2>/dev/null
  grep -qi frenzy "$t"; local r=$?; rm -f "$t"; return $r
}
text_of() { # path -> text on stdout
  case "$(lower "${1##*.}")" in
    txt|md|csv|html|htm) cat "$1";;
    pdf) "$TOOL" pdf-text-dump "$1" </dev/null;;
    docx|rtf|odt|doc) textutil -convert txt -stdout "$1" 2>/dev/null </dev/null;;
  esac
}

expected_kind() { # action -> file:EXT | image | dir:EXT | dir:any | unpack
  case "$1" in
    image.to-jpg|image.svg-to-jpg) echo file:jpg;;
    image.to-png|image.svg-to-png) echo file:png;;
    image.to-heic) echo file:heic;;
    image.to-tiff) echo file:tiff;;
    image.to-webp) echo file:webp;;
    image.to-avif) echo file:avif;;
    image.to-ico) echo file:ico;;
    image.to-pdf|image.combine-pdf|image.svg-to-pdf|pdf.compress|pdf.merge|pdf.rotate-right|document.to-pdf|document.epub-to-pdf) echo file:pdf;;
    image.compress|image.resize-half|image.strip-metadata) echo image;;
    text.ocr-image|pdf.to-text|document.to-txt|document.epub-to-txt) echo file:txt;;
    pdf.to-word|document.to-docx|document.epub-to-docx) echo file:docx;;
    document.to-rtf) echo file:rtf;;
    pdf.to-images) echo dir:png;;
    pdf.split) echo dir:pdf;;
    audio.to-mp3|video.to-mp3) echo file:mp3;;
    audio.to-m4a|video.extract-audio|video.foreign-extract-audio) echo file:m4a;;
    audio.to-wav) echo file:wav;;
    audio.to-aiff) echo file:aiff;;
    audio.to-flac) echo file:flac;;
    archive.zip) echo file:zip;;
    archive.to-tgz) echo file:gz;;
    archive.unzip) echo dir:any;;
    archive.unpack) echo unpack;;
    video.to-mp4|video.compress|video.smaller|video.to-hevc|video.foreign-to-mp4|video.foreign-to-hevc) echo file:mp4;;
    video.to-gif|video.foreign-to-gif) echo file:gif;;
    *) echo unknown;;
  esac
}

pages_of() { kv "$("$TOOL" pdf "$1" 2>/dev/null </dev/null)" pages; }
dims_of() { local i; i="$("$TOOL" image "$1" 2>/dev/null </dev/null)" || return 1; echo "$(kv "$i" w) $(kv "$i" h)"; }
secs_of() { kv "$("$TOOL" audio "$1" 2>/dev/null </dev/null)" seconds; }

VD=""
# The input an output came from: the one whose name stem starts the output's name (batches), else the first.
match_input() { # out input...
  local o="${1##*/}" best="$2" bl=0 p st; shift
  for p in "$@"; do
    st="${p##*/}"; st="${st%%.*}"; [[ -z "$st" ]] && continue
    if [[ "$o" == "$st"* && ${#st} -gt $bl ]]; then best="$p"; bl=${#st}; fi
  done
  echo "$best"
}

# Kind, decoding and what the action promised. inputs = the run copies.
verify_output() { # action out flags nidx input...
  local a="$1" o="$2" fl="$3" nidx="$4"; shift 4
  local first kind ext d1 d2 n p r1 r2 s1 s2 x dd
  first="$(match_input "$o" "$@")"
  kind="$(expected_kind "$a")"
  EMPTY_OK=0; [[ "$a" == document.* && -f "$first" && ! -s "$first" ]] && EMPTY_OK=1
  # Name rules (never overwrite is checked by the caller against the before-listing).
  x="$("$TOOL" name-check "${first##*/}" "${o##*/}" $nidx 2>&1 </dev/null)" || { VD="name: $x"; return 1; }
  case "$kind" in
    file:*)
      ext="${kind#file:}"
      if [[ "$ext" == gz ]]; then [[ "$o" == *.tar.gz ]] || { VD="expected .tar.gz, got ${o##*/}"; return 1; }
      else [[ "$(lower "${o##*.}")" == "$ext" ]] || { VD="expected .$ext, got ${o##*/}"; return 1; }; fi
      check_file "$o" || { VD="$CF"; return 1; };;
    image)
      case "$(lower "${o##*.}")" in jpg|jpeg|png|gif|bmp|tif|tiff|webp|heic|heif|avif) ;; *) VD="not an image name: ${o##*/}"; return 1;; esac
      check_file "$o" || { VD="$CF"; return 1; };;
    dir:*) [[ -d "$o" ]] || { VD="expected a folder, got ${o##*/}"; return 1; }
      check_tree "$o" "${kind#dir:}" || { VD="$CF"; return 1; };;
    unpack) if [[ -d "$o" ]]; then check_tree "$o" any || { VD="$CF"; return 1; }; else check_file "$o" || { VD="$CF"; return 1; }; fi;;
    *) VD="no verifier for $a: add it to expected_kind() in scripts/e2e-actions.sh"; return 1;;
  esac
  VD="$CF"
  # What each action promises.
  case "$a" in
    image.to-jpg|image.to-png|image.to-tiff|image.to-webp|image.to-heic|image.to-avif)
      d1="$(dims_of "$first")"; d2="$(dims_of "$o")"
      [[ -n "$d1" && "$d1" == "$d2" ]] || { VD="size changed: ${d1:-?} -> ${d2:-?}"; return 1; };;
    image.resize-half)
      d1="$(dims_of "$first")"; d2="$(dims_of "$o")"
      dd=($d1 $d2)
      [[ ${#dd[@]} -eq 4 ]] && (( dd[2] * 2 >= dd[0] - 2 && dd[2] * 2 <= dd[0] + 2 )) || { VD="not half size: $d1 -> $d2"; return 1; };;
  esac
  case "$a" in
    image.compress|image.resize-half|image.strip-metadata)
      x="$("$TOOL" meta "$o" 2>/dev/null </dev/null)"
      [[ "$x" == gps=0* ]] || { VD="location still in the output ($x)"; return 1; }
      if [[ "$a" == image.strip-metadata ]]; then [[ "$x" == *exif=0* ]] || { VD="EXIF still in the output ($x)"; return 1; }; fi;;
  esac
  case "$a" in
    image.to-pdf) [[ "$(pages_of "$o")" == 1 ]] || { VD="expected 1 page"; return 1; };;
    image.combine-pdf) [[ "$(pages_of "$o")" == "$#" ]] || { VD="expected $# pages, got $(pages_of "$o")"; return 1; };;
    pdf.compress) [[ "$(pages_of "$o")" == "$(pages_of "$first")" ]] || { VD="page count changed"; return 1; };;
    pdf.merge) n=0; for p in "$@"; do x="$(pages_of "$p")"; n=$((n + ${x:-0})); done
      [[ "$(pages_of "$o")" == "$n" ]] || { VD="merged pages $(pages_of "$o"), want $n"; return 1; };;
    pdf.to-images|pdf.split)
      [[ "$TREE_COUNT" == "$(pages_of "$first")" ]] || { VD="$TREE_COUNT files for $(pages_of "$first") pages"; return 1; };;
    pdf.rotate-right)
      r1="$(kv "$("$TOOL" pdf "$first" </dev/null)" rotation)"; r2="$(kv "$("$TOOL" pdf "$o" </dev/null)" rotation)"
      [[ "$r2" == "$(( (r1 + 90) % 360 ))" ]] || { VD="rotation $r1 -> $r2, want +90"; return 1; };;
    audio.*)
      s1="$(secs_of "$first")"; s2="$(secs_of "$o")"
      awk -v a="${s1:-0}" -v b="${s2:-0}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(a > 0 && d <= 0.6) }' \
        || { VD="duration ${s1:-?}s -> ${s2:-?}s"; return 1; };;
    archive.zip|archive.to-tgz)
      x="$WORK/x/$CASE_N"; mkdir -p "$x"
      if [[ "$a" == archive.zip ]]; then ditto -x -k "$o" "$x" </dev/null 2>/dev/null || { VD="ditto can't extract"; return 1; }
      else tar -xzf "$o" -C "$x" </dev/null 2>/dev/null || { VD="tar can't extract"; return 1; }; fi
      for p in "$@"; do
        if [[ -d "$p" ]]; then diff -r "$p" "$x/${p##*/}" >/dev/null 2>&1 || { VD="extracted ${p##*/} differs from the original"; return 1; }
        else cmp -s "$p" "$x/${p##*/}" || { VD="extracted ${p##*/} differs from the original"; return 1; }; fi
      done
      VD="$VD; round-trip identical";;
    archive.unzip|archive.unpack)
      x="$(flag_val "$fl" src)"
      if [[ -n "$x" ]]; then
        if [[ -d "$SRC/$x" ]]; then diff -r "$SRC/$x" "$o" >/dev/null 2>&1 || { VD="unpacked folder differs from what was packed"; return 1; }
        else cmp -s "$SRC/$x" "$o" || { VD="unpacked file differs from what was packed"; return 1; }; fi
        VD="$VD; identical to the source"
      fi;;
  esac
  # Text that went in must come out: text outputs from anything with words in it (OCR included), and PDFs made
  # from documents or edited from a PDF with a text layer.
  local textcheck=0
  if [[ "$a" == text.ocr-image ]]; then has_flag "$fl" notext || textcheck=1
  elif has_flag "$fl" text || has_flag "$fl" ocr; then
    case "$(lower "${o##*.}")" in
      txt|docx|rtf) textcheck=1;;
      pdf) case "$a" in
             document.to-pdf|document.epub-to-pdf) has_flag "$fl" text && textcheck=1;;
             # Edited PDFs keep a text layer only if the input had one (a scan has none).
             pdf.compress|pdf.rotate-right|pdf.merge) has_flag "$fl" text && has_frenzy "$first" && textcheck=1;;
           esac;;
    esac
  fi
  if [[ $textcheck == 1 ]]; then
    has_frenzy "$o" || { VD="the word 'Frenzy' from the input is missing in ${o##*/}"; return 1; }
    VD="$VD; text kept"
  fi
  return 0
}

# ---------------------------------------------------------------- 4. one conversion, every check
CASE_N=0
CASE_RUN=""     # set by callers that prepare the run folder themselves (collisions)
run_case() { # label action expect flags nameindex input...
  local label="$1" a="$2" expect="$3" fl="$4" nidx="$5"; shift 5
  CASE_N=$((CASE_N + 1)); local n=$CASE_N run log src inputs=()
  if [[ $PLAN == 1 ]]; then printf 'PLAN %s\t%s\t%s\n' "$a" "$expect" "$label"; return; fi
  if [[ -n "$CASE_RUN" ]]; then run="$CASE_RUN"; inputs=("$@")
  else
    run="$WORK/runs/$n"; mkdir -p "$run"
    for src in "$@"; do cp -Rp "$src" "$run/" || { record "$label" FAIL "could not copy the fixture"; return; }; inputs+=("$run/${src##*/}"); done
  fi
  video_guard "$a" "${inputs[@]}"
  log="$LOGS/$n"
  snapshot "$run" > "$log.before"
  hash_tree "$run" > "$log.sha"
  local tmo=$TIMEOUT; has_flag "$fl" big && tmo=$BIG_TIMEOUT
  local t0 t1 secs rc
  t0="$(now)"
  with_timeout "$tmo" "$BIN" --convert "$a" "${inputs[@]}" > "$log.out" 2> "$log.err" </dev/null; rc=$?
  t1="$(now)"; secs="$(elapsed "$t0" "$t1")"
  printf '%s\t%s\n' "$a" "$secs" >> "$TIMINGS"

  local outs=() line nfail=0 fmsg="" problems=""
  while IFS= read -r line; do
    case "$line" in
      "OUTPUT "*) outs+=("${line#OUTPUT }");;
      "FAILURE "*) nfail=$((nfail + 1)); fmsg="$fmsg${line#FAILURE }; ";;
    esac
  done < "$log.out"
  local nout=${#outs[@]}
  [[ $rc == 142 ]] && problems="$problems timed out after ${tmo}s;"
  grep -qF "$CRASH_TEXT" "$log.out" && problems="$problems the worker crashed;"
  # Originals and anything already in the folder: byte-identical.
  shasum -a 256 -c "$log.sha" >/dev/null 2>&1 || problems="$problems an original or an earlier file changed: $(shasum -a 256 -c "$log.sha" 2>&1 | grep -v ': OK$' | head -2 | tr '\n' ' ');"
  # Nothing removed, nothing new except the outputs, no scratch left.
  snapshot "$run" > "$log.after"
  local gone newe o orel ok e
  gone="$(LC_ALL=C comm -23 "$log.before" "$log.after")"; [[ -z "$gone" ]] || problems="$problems files disappeared: ${gone//$'\n'/, };"
  local orels=()
  for o in ${outs[@]+"${outs[@]}"}; do
    [[ -e "$o" ]] || { problems="$problems reported output missing: ${o##*/};"; continue; }
    [[ "$(canon_dir "${o%/*}")" == "$(canon_dir "$run")" ]] || problems="$problems output saved outside the input's folder: $o;"
    orel="$(printf '%s\n' "${o##*/}" | nfc)"; orels+=("$orel")
    grep -qxF -- "$orel" "$log.before" && problems="$problems overwrote existing ${o##*/};"
  done
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    ok=0; for orel in ${orels[@]+"${orels[@]}"}; do [[ "$e" == "$orel" || "$e" == "$orel/"* ]] && { ok=1; break; }; done
    [[ $ok == 1 ]] || { problems="$problems unexpected new file: $e;"; break; }
  done < <(LC_ALL=C comm -13 "$log.before" "$log.after")
  [[ -z "$(find "$run" -name '.halo-*' 2>/dev/null)" ]] || problems="$problems .halo-* scratch left behind;"

  # The expected outcome.
  local want="${expect#*:}" detail=""
  case "$expect" in
    ok:*) [[ $rc == 0 && $nout == "$want" && $nfail == 0 ]] || problems="$problems wanted $want output(s), got $nout (exit $rc) ${fmsg};";;
    partial:*) [[ $nout == "$want" && $nfail -ge 1 ]] || problems="$problems wanted $want output(s) and some failures, got $nout and $nfail;";;
    small:*) # Compress: each input either shrinks or is reported as already small
      if [[ $((nout + nfail)) != "$want" ]]; then problems="$problems wanted $want results, got $nout outputs + $nfail failures;"
      elif [[ $nfail -gt 0 && "$(grep '^FAILURE ' "$log.out" | grep -vcF "$SMALL_TEXT")" != 0 ]]; then problems="$problems failed for another reason: $fmsg;"
      fi
      [[ $nfail -gt 0 ]] && detail="already small x$nfail; ";;
    fail) [[ $rc != 0 && $nout == 0 && $nfail -ge 1 ]] || problems="$problems should have been refused, got $nout output(s) (exit $rc);"
      detail="refused: ${fmsg:0:120}";;
    either) [[ $nout -gt 0 || $nfail -ge 1 ]] || problems="$problems no output and no message;"
      [[ $nout == 0 ]] && detail="refused: ${fmsg:0:120}";;
  esac
  # Every output verified.
  for o in ${outs[@]+"${outs[@]}"}; do
    [[ -e "$o" ]] || continue
    if verify_output "$a" "$o" "$fl" "$nidx" "${inputs[@]}"; then detail="$detail${o##*/}: $VD; "
    else problems="$problems ${o##*/}: $VD;"; fi
  done
  if [[ -n "$problems" ]]; then record "$label" FAIL "$problems (log $log.out)" "$secs"
  else record "$label" PASS "$detail" "$secs"; fi
}

expect_for() { # class action count flags
  local cls="$1" a="$2" n="$3" f="$4"
  case "$a" in archive.zip|archive.to-tgz) echo "ok:1"; return;; esac
  case "$cls" in bad) echo fail; return;; either) echo either; return;; esac
  case "$a" in
    # Compress honestly refuses an animated GIF ("can't be compressed yet"): that input is a clean failure.
    image.compress) if has_flag "$f" animated; then echo fail; else echo "small:$n"; fi;;
    pdf.compress) echo "small:$n";;
    text.ocr-image) if has_flag "$f" notext; then echo either; else echo "ok:$n"; fi;;
    *) echo "ok:$n";;
  esac
}

# Runs that would drive the hardware video encoder are listed here and only run in the FRENZY_VIDEO_TESTS section.
gate() { # action label expectation input...  (the expectation is judged exactly as in the main run)
  local a="$1" label="$2" exp="$3"; shift 3
  printf '%s\t%s\t%s' "$a" "$label" "$exp" >> "$GATED"; local p; for p in "$@"; do printf '\t%s' "$p" >> "$GATED"; done; echo >> "$GATED"
  if [[ $VIDEO == 1 && $PLAN == 0 ]]; then echo "     deferred to the video section: $label"
  else record "$label" SKIP "uses the hardware video encoder (HEIC/AVIF out); runs only with FRENZY_VIDEO_TESTS=1"; fi
}

# ---------------------------------------------------------------- 5. worker, sandbox, engine
selftest() { # label
  local out rc rows bad
  out="$(with_timeout 90 "$BIN" --worker-self-test 2>&1 </dev/null)"; rc=$?
  printf '%s\n' "$out" > "$LOGS/selftest-$1.txt"
  if grep -q "WORKER_SELF_TEST PASS" <<< "$out"; then
    record "worker self-test ($1)" PASS "$(grep -c '| PASS |' <<< "$out") probes pass; $(grep 'sandbox container' <<< "$out" | head -1)"
  else
    record "worker self-test ($1)" FAIL "exit $rc: $(grep -E 'FAIL|ERROR' <<< "$out" | head -3 | tr '\n' ' ')"
  fi
  rows="$(grep -E '^\| (TCP|UDP|DNS|URLSession|engine opens tcp)' <<< "$out")"
  bad="$(grep -v '| PASS |' <<< "$rows")"
  if [[ -n "$rows" && -z "$bad" ]]; then record "network denied in the worker ($1)" PASS "$(wc -l <<< "$rows" | tr -d ' ') network probes denied"
  else record "network denied in the worker ($1)" FAIL "${bad:-no network probes in the self-test output}"; fi
}

engine_checks() {
  local videoout w enc venc missing
  videoout="$("$REG" "$ENGINE_ON" videoout </dev/null)"
  missing=""; for w in $videoout; do cut -f1 "$WORK/actions.tsv" | grep -qxF "$w" || missing="$missing $w"; done
  [[ -z "$missing" ]] && record "foreign video out registered (x264 / x265)" PASS "$(echo $videoout)" || record "foreign video out registered (x264 / x265)" FAIL "missing:$missing"
  if [[ -x "$APP_ENGINE" ]]; then
    if otool -L "$APP_ENGINE" 2>/dev/null | grep -qi videotoolbox; then record "engine does not link VideoToolbox" FAIL "otool -L lists VideoToolbox"
    else record "engine does not link VideoToolbox" PASS "otool -L ${APP_ENGINE##*/}"; fi
  else record "engine does not link VideoToolbox" SKIP "no media engine in this app bundle"; fi
  if [[ -n "$RUN_ENGINE" ]]; then
    enc="$(with_timeout 20 "$RUN_ENGINE" -hide_banner -encoders 2>/dev/null </dev/null)"
    venc="$(awk '$1 ~ /^V/ { print $2 }' <<< "$enc" | grep -vxE 'gif|libwebp|libwebp_anim|png|libx264|libx265' | grep -v '^=' | tr '\n' ' ')"
    [[ -z "${venc// /}" ]] && record "engine video encoders are CPU only" PASS "gif, webp, x264, x265 (${RUN_ENGINE#$ROOT/})" \
      || record "engine video encoders are CPU only" FAIL "unexpected video encoders: $venc"
    if with_timeout 20 "$RUN_ENGINE" -hide_banner -buildconf 2>/dev/null </dev/null | grep -q -- '--enable-videotoolbox'; then
      record "engine built without VideoToolbox" FAIL "-buildconf has --enable-videotoolbox"
    else record "engine built without VideoToolbox" PASS "-buildconf"; fi
  else record "engine video encoders are CPU only" SKIP "no runnable media engine"; fi
}

# ---------------------------------------------------------------- 6. run
DL_BEFORE="$WORK/downloads-before.txt"; ls -A "$HOME/Downloads" 2>/dev/null | sort > "$DL_BEFORE"
CR_BEFORE="$WORK/crashes-before.txt"; ls "$CRASH_DIR" 2>/dev/null | grep -iE '^(Frenzy|frenzy-media-engine)' | sort > "$CR_BEFORE"

if [[ $PLAN == 0 ]]; then
  selftest start
  engine_checks
fi

echo "== single-file matrix"
VIDEO_OFFERED=0
while IFS=$'\t' read -r id name cls flags mpath mtype mvideo mids <&3; do
  p="$FIX/$id/$name"
  if [[ "$mids" == "-" || -z "$mids" ]]; then
    [[ "$cls" == good ]] && record "actions for $name" FAIL "no action offered for $mtype"
    continue
  fi
  IFS=',' read -r -a ids <<< "$mids"
  for a in "${ids[@]}"; do
    only_ok "$a" || continue
    if [[ "$a" == video.* ]]; then VIDEO_OFFERED=$((VIDEO_OFFERED + 1)); record "$a on $name" FAIL "a video action is offered for a non-video file ($mtype)"; continue; fi
    if encoder_risk "$a" "$p"; then gate "$a" "$a on $name" "$(expect_for "$cls" "$a" 1 "$flags")" "$p"; continue; fi
    run_case "$a on $name" "$a" "$(expect_for "$cls" "$a" 1 "$flags")" "$flags" "" "$p"
  done
done 3< "$WORK/plan.tsv"
[[ $PLAN == 0 && $VIDEO_OFFERED == 0 ]] && record "video actions never offered for non-video files" PASS "$(wc -l < "$WORK/plan.tsv" | tr -d ' ') fixtures checked against the registry"

echo "== multi-file drops"
fx() { echo "$FIX/$1/$2"; }
fixture_flags() { # path -> the flags add_fixture gave it
  local p="$1" id; id="${p%/*}"; id="${id##*/}"
  awk -F'\t' -v id="$id" -v n="${p##*/}" '$1 == id && $2 == n { print $4; exit }' "$MANIFEST"
}
group_case() { # label goodcount flags path...
  local label="$1" good="$2" fl="$3"; shift 3
  local ids a card exp p risky
  ids="$("$REG" "$ENGINE_ON" group "$@" </dev/null)"
  [[ "$ids" == "-" ]] && { record "$label" FAIL "no action takes these files together"; return; }
  IFS=',' read -r -a arr <<< "$ids"
  for a in "${arr[@]}"; do
    only_ok "$a" || continue
    [[ "$a" == video.* ]] && { record "$a on $label" FAIL "video action offered"; continue; }
    risky=0; for p in "$@"; do encoder_risk "$a" "$p" && risky=1; done
    card="$(card_of "$a")"
    # OCR on a picture with no words honestly says "No text found": that input is a failure, not an output.
    local g="$good"
    if [[ "$a" == text.ocr-image ]]; then for p in "$@"; do has_flag "$(fixture_flags "$p")" notext && g=$((g - 1)); done; fi
    if [[ "$a" == archive.zip || "$a" == archive.to-tgz ]]; then exp="ok:1"
    elif [[ "$g" != "$good" ]]; then exp="partial:$g"
    elif [[ "$good" == "$#" ]]; then
      if [[ "$card" == combined:* ]]; then exp="ok:1"; else exp="$(expect_for good "$a" "$#" "$fl")"; fi
    else
      if [[ "$card" == combined:* ]]; then exp="fail"
      elif [[ "$a" == *compress* ]]; then exp="either"
      else exp="partial:$good"; fi
    fi
    # Compress refuses an animated GIF and leaves already-small files alone: a mix comes back partly done.
    if [[ "$a" == image.compress ]]; then for p in "$@"; do has_flag "$(fixture_flags "$p")" animated && exp="either"; done; fi
    if [[ $risky == 1 ]]; then gate "$a" "$a on $label" "$exp" "$@"; continue; fi
    run_case "$a on $label" "$a" "$exp" "$fl" "" "$@"
  done
}
PDFS=("$(fx pdf-text report.pdf)" "$(fx pdf-scan "scanned letter.pdf")" "$(fx pdf-js with-javascript.pdf)")
group_case "3 PDFs" 3 text "${PDFS[@]}"
group_case "a PDF and a locked PDF" 1 text "$(fx pdf-text report.pdf)" "$(fx pdf-locked locked.pdf)"
IMGS=("$(fx img-png photo.png)" "$(fx img-jpg camera.jpg)" "$(fx img-gif anim.gif)" "$(fx img-bmp scan.bmp)" "$(fx img-tiff print.tiff)")
[[ -e "$(fx img-webp web.webp)" ]] && IMGS+=("$(fx img-webp web.webp)")
[[ -e "$(fx img-heic wallpaper.heic)" ]] && IMGS+=("$(fx img-heic wallpaper.heic)")
group_case "${#IMGS[@]} mixed images" "${#IMGS[@]}" text "${IMGS[@]}"
group_case "2 good images and a broken one" 2 text "$(fx img-png photo.png)" "$(fx n-bad-png broken.png)" "$(fx img-tiff print.tiff)"
group_case "2 folders" 2 - "$(fx folder "My Folder")" "$(fx folder2 "second folder")"
if [[ $PLAN == 0 ]]; then
  MIXED_IDS="$("$REG" "$ENGINE_ON" group "$(fx img-png photo.png)" "$(fx pdf-text report.pdf)" "$(fx doc-txt notes.txt)" </dev/null)"
  [[ "$MIXED_IDS" == "archive.zip" ]] && record "image + PDF + text offers only Zip" PASS "$MIXED_IDS" \
    || record "image + PDF + text offers only Zip" FAIL "offered: $MIXED_IDS"
fi
run_case "archive.zip on image + PDF + text" archive.zip ok:1 - "" "$(fx img-png photo.png)" "$(fx pdf-text report.pdf)" "$(fx doc-txt notes.txt)"
if [[ $BIG == 1 ]]; then
  B60=(); for f in "$FIX"/batch60/*.png; do B60+=("$f"); done
  for a in image.to-jpg image.to-pdf image.combine-pdf archive.zip; do
    only_ok "$a" || continue
    case "$(card_of "$a")" in combined:*) e="ok:1";; *) e="ok:60";; esac
    run_case "$a on a 60-file batch" "$a" "$e" "text,big" "" "${B60[@]}"
  done
else record "60-file batch" SKIP "--no-big"; fi

echo "== never overwrite"
collision() { # action fixture-id name flags
  local a="$1" id="$2" name="$3" fl="$4"
  only_ok "$a" || return 0
  CASE_N=$((CASE_N + 1)); local run="$WORK/runs/c$CASE_N"; mkdir -p "$run"; cp -Rp "$FIX/$id/$name" "$run/"
  CASE_RUN="$run"
  run_case "$a on $name (1st run)" "$a" ok:1 "$fl" "" "$run/$name"
  run_case "$a on $name again -> ' 2', 1st untouched" "$a" ok:1 "$fl" 2 "$run/$name"
  CASE_RUN=""
}
collision image.to-jpg img-png photo.png text
collision pdf.rotate-right pdf-text report.pdf text,pages=3
collision pdf.to-images pdf-text report.pdf text,pages=3
collision document.to-pdf doc-txt notes.txt text
collision audio.to-wav au-m4a tone.m4a audio
collision archive.zip folder "My Folder" -
collision archive.unzip ar-zip bundle.zip src=bundle
if only_ok image.to-jpg; then
  CASE_N=$((CASE_N + 1)); DECOY="$WORK/runs/decoy$CASE_N"; mkdir -p "$DECOY"
  cp "$FIX/img-png/photo.png" "$DECOY/photo.png"; cp "$FIX/img-jpg/camera.jpg" "$DECOY/photo.jpg"
  CASE_RUN="$DECOY"; run_case "image.to-jpg next to an existing photo.jpg -> photo 2.jpg" image.to-jpg ok:1 text 2 "$DECOY/photo.png"; CASE_RUN=""
fi

[[ $PLAN == 1 ]] && { echo; echo "PLAN: $CASE_N conversions planned, $(wc -l < "$GATED" | tr -d ' ') gated behind FRENZY_VIDEO_TESTS=1"; exit 0; }

echo "== read-only disk image"
RO_SRC="$WORK/ro-src"; mkdir -p "$RO_SRC" "$WORK/mnt"
TOKEN="$(basename "$WORK" | tr -cd 'A-Za-z0-9')"
cp "$FIX/img-png/photo.png" "$RO_SRC/ro-photo-$TOKEN.png"
if hdiutil create -quiet -srcfolder "$RO_SRC" -volname FrenzyRO -format UDRO "$WORK/ro.dmg" </dev/null \
   && hdiutil attach -quiet -readonly -nobrowse -noverify -noautoopen -mountroot "$WORK/mnt" "$WORK/ro.dmg" </dev/null; then
  MOUNTED="$WORK/mnt/FrenzyRO"
  if touch "$MOUNTED/.probe" 2>/dev/null; then record "read-only disk image is read-only" FAIL "could write to it"
  else record "read-only disk image is read-only" PASS "mounted at $MOUNTED"; fi
  if [[ $DOWNLOADS_OK == 1 ]] && only_ok image.to-jpg; then
    ROF="$MOUNTED/ro-photo-$TOKEN.png"; ROH="$(shasum -a 256 "$ROF" | cut -d' ' -f1)"
    t0="$(now)"; with_timeout "$TIMEOUT" "$BIN" --convert image.to-jpg "$ROF" > "$LOGS/ro.out" 2>&1 </dev/null; rc=$?; secs="$(elapsed "$t0" "$(now)")"
    O="$(grep '^OUTPUT ' "$LOGS/ro.out" | head -1 | cut -c8-)"
    if [[ $rc == 0 && "$O" == "$HOME/Downloads/ro-photo-$TOKEN"* && -f "$O" ]] && check_file "$O"; then
      mkdir -p "$WORK/from-downloads"; mv "$O" "$WORK/from-downloads/"
      [[ "$(shasum -a 256 "$ROF" | cut -d' ' -f1)" == "$ROH" ]] && record "convert from a read-only volume -> Downloads" PASS "$CF; moved back out of Downloads" "$secs" \
        || record "convert from a read-only volume -> Downloads" FAIL "original changed" "$secs"
    else
      record "convert from a read-only volume -> Downloads" FAIL "exit $rc, output '${O:-none}': $(tr '\n' ' ' < "$LOGS/ro.out")" "$secs"
    fi
  else
    record "convert from a read-only volume -> Downloads" SKIP "would write to ~/Downloads; run with FRENZY_E2E_DOWNLOADS=1"
  fi
  hdiutil detach "$MOUNTED" -quiet 2>/dev/null || hdiutil detach "$MOUNTED" -force -quiet 2>/dev/null; MOUNTED=""
else
  record "read-only disk image" FAIL "hdiutil could not make or mount it"
fi

echo "== worker crash test (non-video job)"
CRASH_IN="$FIX/pdf-big/big 300 pages.pdf"; [[ -e "$CRASH_IN" ]] || CRASH_IN="$FIX/pdf-text/report.pdf"
CR_RUN="$WORK/runs/crash"; mkdir -p "$CR_RUN"; cp "$CRASH_IN" "$CR_RUN/"
snapshot "$CR_RUN" > "$LOGS/crash.before"
t0="$(now)"
with_timeout 180 "$BIN" --worker-crash-test pdf.to-images "$CR_RUN/${CRASH_IN##*/}" > "$LOGS/crash.out" 2>&1 </dev/null; rc=$?
secs="$(elapsed "$t0" "$(now)")"
snapshot "$CR_RUN" > "$LOGS/crash.after"
if [[ $rc == 0 ]] && grep -q "CRASH_TEST PASS" "$LOGS/crash.out" && cmp -s "$LOGS/crash.before" "$LOGS/crash.after" \
   && [[ -z "$(find "$CR_RUN" -name '.halo-*')" ]]; then
  record "worker killed mid-job: clean failure, fresh worker, nothing saved" PASS "$(grep -E 'job outcome|pid after' "$LOGS/crash.out" | tr '\n' ' ')" "$secs"
else
  record "worker killed mid-job: clean failure, fresh worker, nothing saved" FAIL "exit $rc: $(tail -4 "$LOGS/crash.out" | tr '\n' ' ')" "$secs"
fi
selftest "after the crash test"

# ---------------------------------------------------------------- 7. OPTIONAL VIDEO SECTION (FRENZY_VIDEO_TESTS=1 only)
if [[ $VIDEO == 1 ]]; then
  echo
  echo "== OPTIONAL VIDEO SECTION: FRENZY_VIDEO_TESTS=1, one job at a time"
  # HEIC/AVIF out still goes through macOS ImageIO, which only has the hardware encoder: those jobs run only with
  # FRENZY_HEIC_TESTS=1 as well (one at a time, inside Frenzy's gate). Video below is x264/x265 on the CPU.
  [[ "${FRENZY_HEIC_TESTS:-}" == "1" ]] || : > "$GATED"
  while IFS=$'\t' read -r -a g <&3; do
    a="${g[0]}"; label="${g[1]}"; e="${g[2]}"; files=("${g[@]:3}")
    run_case "[heic] $label" "$a" "$e" - "" "${files[@]}"
  done 3< "$GATED"
  VD_DIR="$FIX/video"; mkdir -p "$VD_DIR"
  if [[ -n "${FRENZY_VIDEO_INPUT:-}" ]]; then cp "$FRENZY_VIDEO_INPUT" "$VD_DIR/"; VIN="$VD_DIR/${FRENZY_VIDEO_INPUT##*/}"
  else
    # Made by the developer FFmpeg's CPU encoders (x264 + AAC), never Apple's writer (the hardware encoder).
    VIN="$VD_DIR/clip.mov"; DEVFF="$HOME/.local/bin/ffmpeg"
    if [[ -x "$DEVFF" ]]; then
      "$DEVFF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30:d=4" -f lavfi -i "sine=f=440:r=44100:d=4" \
        -vf "noise=alls=24:allf=t,format=yuv420p" -c:v libx264 -preset ultrafast -b:v 6M -c:a aac -b:a 128k -t 4 "$VIN" </dev/null \
        || record "[video] make test movie" FAIL "developer FFmpeg failed"
    else record "[video] make test movie" SKIP "no developer FFmpeg at $DEVFF; pass FRENZY_VIDEO_INPUT=<file>"; fi
  fi
  if [[ -e "$VIN" ]]; then
    VLINE="$("$REG" "$ENGINE_ON" match "$VIN" </dev/null)"
    IFS=$'\t' read -r _ vtype _ vids <<< "$VLINE"
    IFS=',' read -r -a varr <<< "$vids"
    for a in "${varr[@]}"; do
      [[ "$a" == "-" ]] && continue
      only_ok "$a" || continue
      case "$a" in video.compress) e="small:1";; *) e="ok:1";; esac
      run_case "[video] $a on ${VIN##*/}" "$a" "$e" - "" "$VIN"
    done
  fi
fi

# ---------------------------------------------------------------- 8. global checks
if shasum -a 256 -c "$WORK/fixtures.sha" >/dev/null 2>&1 && shasum -a 256 -c "$WORK/src.sha" >/dev/null 2>&1; then
  record "every fixture byte-identical at the end" PASS "$(wc -l < "$WORK/fixtures.sha" | tr -d ' ') files"
else record "every fixture byte-identical at the end" FAIL "$(shasum -a 256 -c "$WORK/fixtures.sha" 2>&1 | grep -v ': OK$' | head -3 | tr '\n' ' ')"; fi
LEFT="$(find "$WORK" -name '.halo-*' 2>/dev/null | head -5)"
[[ -z "$LEFT" ]] && record "no .halo-* scratch anywhere" PASS "searched $WORK" || record "no .halo-* scratch anywhere" FAIL "$LEFT"
if [[ -d "$STAGING" ]]; then
  LEFT="$(find "$STAGING" -mindepth 1 -maxdepth 1 ! -name '.memory-limit' 2>/dev/null | head -5)"
  [[ -z "$LEFT" ]] && record "worker staging emptied" PASS "$STAGING" || record "worker staging emptied" FAIL "left: $LEFT (another Frenzy job running?)"
else record "worker staging emptied" PASS "no staging folder"; fi
DL_AFTER="$WORK/downloads-after.txt"; ls -A "$HOME/Downloads" 2>/dev/null | sort > "$DL_AFTER"
STEMS="$WORK/stems.txt"; cut -f2 "$MANIFEST" | sed -E 's/^([^.]+).*/\1/' | sort -u > "$STEMS"; echo "img-" >> "$STEMS"; echo "Archive" >> "$STEMS"
LEAK=""
while IFS= read -r nm; do
  while IFS= read -r st; do [[ -n "$st" && "$nm" == "$st"* ]] && { LEAK="$LEAK $nm;"; break; }; done < "$STEMS"
done < <(comm -13 "$DL_BEFORE" "$DL_AFTER")
[[ -z "$LEAK" ]] && record "nothing saved to ~/Downloads" PASS "compared before/after" || record "nothing saved to ~/Downloads" FAIL "new:$LEAK"
ls "$CRASH_DIR" 2>/dev/null | grep -iE '^(Frenzy|frenzy-media-engine)' | sort > "$WORK/crashes-after.txt"
NEWCR="$(comm -13 "$CR_BEFORE" "$WORK/crashes-after.txt" | tr '\n' ' ')"
[[ -z "${NEWCR// /}" ]] && record "no new Frenzy crash reports" PASS "$CRASH_DIR (the crash test uses SIGKILL, which writes none)" \
  || record "no new Frenzy crash reports" FAIL "$NEWCR"
selftest end

# ---------------------------------------------------------------- 9. report
REPORT="$BUILD/last-report.md"
{
  echo "# Frenzy e2e-actions $(date '+%Y-%m-%d %H:%M')"
  echo "app: $APP  engine: $ENGINE_ON  video section: $VIDEO"
  echo
  echo "| # | Check | Result | Seconds | Detail |"
  echo "|---|---|---|---|---|"
  for i in "${!R_NAME[@]}"; do echo "| $((i + 1)) | ${R_NAME[$i]} | ${R_STATUS[$i]} | ${R_TIME[$i]} | ${R_DETAIL[$i]} |"; done
  echo
  echo "## Time per action"
  echo
  echo "| Action | Runs | Total s | Average s | Slowest s |"
  echo "|---|---|---|---|---|"
  awk -F'\t' '{ n[$1]++; t[$1] += $2; if ($2 > m[$1]) m[$1] = $2 }
    END { for (a in n) printf "| %s | %d | %.1f | %.2f | %.1f |\n", a, n[a], t[a], t[a] / n[a], m[a] }' "$TIMINGS" | sort
  echo
  echo "PASS $PASSES, FAIL $FAILS, SKIP $SKIPS"
} > "$REPORT"
echo; cat "$REPORT"; echo; echo "report saved: $REPORT"
if [[ $FAILS -gt 0 ]]; then
  [[ $KEEP == 0 ]] && echo "(re-run with --keep to inspect the outputs; logs per case are in $LOGS)"
  echo "$FAILS FAILED"; exit 1
fi
echo "ALL PASS ($SKIPS skipped)"; exit 0
