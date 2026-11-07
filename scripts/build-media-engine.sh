#!/usr/bin/env bash
# Builds Frenzy's media engine: an arm64 FFmpeg (GPL v2 or later, with x264) with just the codecs and demuxers Frenzy needs.
#
#   scripts/build-media-engine.sh            builds if needed, otherwise says it is up to date
#   scripts/build-media-engine.sh --force    builds again from the tarballs
#   scripts/build-media-engine.sh --check    only verifies the existing binary (licence, no network, deps)
#
# Sources:  vendor/sources/ (downloaded once, SHA-256 pinned below). Kept so the LGPL obligations can be met.
# Output:   vendor/build/arm64/bin/frenzy-media-engine, vendor/build/arm64/licenses/, vendor/configure-line.txt
# Rules:    GPL v2 or later is fine (the founder chose open source for quality, 7 Nov 2026). No non-free code, no network.
#           CPU only: no VideoToolbox. Driving the hardware video encoder kernel-panicked the founder's Mac three times on
#           7 Nov 2026 (dart-ave0). Video encoders: x264 and x265, both CPU; x264 beat Apple's software H.264 by 16 VMAF
#           points at the same size and speed on a real 1080p clip. Picture encoders: libwebp and gif, also CPU.
# Tools:    cmake (x265 is built with it). Not shipped.
#           The script fails if any check below finds otherwise.
#
# It builds in a fixed path with no spaces (FFmpeg's configure can't handle them, and it keeps the home folder out of
# the binary), with ZERO_AR_DATE and a fixed locale, so the same tarballs give the same binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
SOURCES="$VENDOR/sources"
OUT="$VENDOR/build/arm64"
ENGINE="$OUT/bin/frenzy-media-engine"
WORK="${FRENZY_ENGINE_WORK:-/tmp/frenzy-media-engine}"
JOBS="${FRENZY_ENGINE_JOBS:-2}"
(( JOBS <= 4 )) || { echo "error: FRENZY_ENGINE_JOBS is $JOBS; 4 at most on this Mac" >&2; exit 64; }
MIN_MACOS=14.0

X264_C=b35605ace3ddf7c1a5d67a2eb553f034aef41d55  # x264 stable, 8 Jun 2025
X265_V=4.1
FFMPEG_V=9.0.2  LAME_V=3.100  WEBP_V=1.6.0  DAV1D_V=1.5.4  MESON_V=1.9.1  NINJA_V=1.13.1
# file|url|sha-256. Meson and Ninja are build tools only: they build dav1d and nothing of them ships.
MANIFEST=(
  "x265_$X265_V.tar.gz|https://download.videolan.org/pub/videolan/x265/x265_$X265_V.tar.gz|a31699c6a89806b74b0151e5e6a7df65de4b49050482fe5ebf8a4379d7af8f29"
  "x264-$X264_C.tar.bz2|https://code.videolan.org/videolan/x264/-/archive/$X264_C/x264-$X264_C.tar.bz2|6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"
  "ffmpeg-$FFMPEG_V.tar.xz|https://ffmpeg.org/releases/ffmpeg-$FFMPEG_V.tar.xz|8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"
  "lame-$LAME_V.tar.gz|https://downloads.sourceforge.net/project/lame/lame/$LAME_V/lame-$LAME_V.tar.gz|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
  "libwebp-$WEBP_V.tar.gz|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP_V.tar.gz|e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
  "dav1d-$DAV1D_V.tar.xz|https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_V/dav1d-$DAV1D_V.tar.xz|686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5"
  "meson-$MESON_V.tar.gz|https://github.com/mesonbuild/meson/releases/download/$MESON_V/meson-$MESON_V.tar.gz|4e076606f2afff7881d195574bddcd8d89286f35a17b4977a216f535dc0c74ac"
  "ninja-$NINJA_V.tar.gz|https://github.com/ninja-build/ninja/archive/refs/tags/v$NINJA_V.tar.gz|f0055ad0369bf2e372955ba55128d000cfcc21777057806015b45e4accbebf23"
)

# Only what Frenzy needs. Everything else stays out, so a hostile file has less code to reach: no HLS, DASH, concat,
# image sequences, subtitles or capture devices.
# rawvideo: only ever named explicitly (-f rawvideo) for the pipe Frenzy feeds with tone-mapped HDR frames (HDR to MP4).
DEMUXERS=matroska,avi,flv,asf,ogg,mov,mp3,wav,aiff,flac,aac,ac3,eac3,dts,dtshd,truehd,mlp,mpegts,mpegps,mpegvideo,m4v,amr,ape,wv,caf,image_png_pipe,rawvideo
VIDEO_DECODERS=h264,hevc,libdav1d,vp8,vp9,vp6,vp6a,vp6f,flv,h263,h263i,h263p,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,wmv3,vc1,mpeg1video,mpeg2video,mjpeg,theora,vp3,flashsv,flashsv2,rawvideo,prores,dvvideo,huffyuv,ffv1,cinepak,msvideo1,png
AUDIO_DECODERS=aac,aac_latm,ac3,eac3,dca,truehd,mlp,mp1,mp2,mp3,opus,vorbis,flac,alac,wmav1,wmav2,wmapro,wmalossless,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_mulaw,pcm_alaw,adpcm_ima_wav,adpcm_ms,amrnb,amrwb,ape,wavpack
# aac_at is AudioToolbox (audio only). No h264_videotoolbox or hevc_videotoolbox: see the CPU-only rule above.
ENCODERS=libx264,libx265,aac_at,libmp3lame,flac,libwebp,gif,pcm_s16le,pcm_s24le,pcm_s16be,pcm_s24be
MUXERS=mp4,mov,ipod,mp3,flac,wav,aiff,webp,gif,null
PARSERS=h264,hevc,vp8,vp9,av1,aac,aac_latm,ac3,dca,flac,mpeg4video,mpegvideo,mpegaudio,opus,vorbis,vc1,h263,mjpeg,png,vp3,mlp
BSFS=aac_adtstoasc,extract_extradata,vp9_superframe,vp9_superframe_split,av1_frame_merge,h264_mp4toannexb,hevc_mp4toannexb,mpeg4_unpack_bframes
# setparams: labels frames BT.709 before x264/x265 (FFmpeg takes colour tags from the frames, not from -color_* options).
FILTERS=scale,format,fps,split,palettegen,paletteuse,aresample,aformat,anull,null,transpose,hflip,vflip,rotate,setsar,crop,trim,atrim,setparams

configure_args() {
  local prefix="$1"
  printf '%s\n' \
    --prefix="$prefix" --cc=clang --arch=arm64 --target-os=darwin --enable-static --disable-shared \
    --enable-gpl --disable-nonfree --disable-version3 --disable-network --disable-autodetect --disable-everything \
    --disable-doc --disable-debug --disable-ffplay --disable-ffprobe --disable-avdevice --disable-iconv --disable-bzlib \
    --disable-lzma --enable-pthreads --enable-zlib --disable-videotoolbox --enable-audiotoolbox \
    --enable-libmp3lame --enable-libwebp --enable-libdav1d --enable-libx264 --enable-libx265 \
    --enable-protocol=file,pipe \
    --enable-demuxer="$DEMUXERS" --enable-decoder="$VIDEO_DECODERS,$AUDIO_DECODERS" --enable-encoder="$ENCODERS" \
    --enable-muxer="$MUXERS" --enable-parser="$PARSERS" --enable-bsf="$BSFS" --enable-filter="$FILTERS" \
    --pkg-config="$WORK/tools/bin/pkg-config-shim" --pkg-config-flags=--static \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS -I$prefix/include" \
    --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -L$prefix/lib"
}

verify() { # Every rule the founder set, checked on the real binary. Any failure stops the build.
  local bin="$1" fail=0
  echo "==> Verifying $bin"
  [[ "$(lipo -archs "$bin")" == arm64 ]] || { echo "FAIL: not arm64"; fail=1; }
  local license; license="$("$bin" -hide_banner -L 2>&1)"
  grep -q "GNU General Public License" <<<"$license" || { echo "FAIL: -L does not say GPL"; fail=1; }
  local conf; conf="$("$bin" -hide_banner -buildconf 2>&1)"
  if grep -Eq -- "--enable-(nonfree|version3|libxvid|libfdk)" <<<"$conf"; then echo "FAIL: forbidden configure flag"; fail=1; fi
  local encoders; encoders="$("$bin" -hide_banner -encoders 2>&1)"
  if grep -Eq "libxvid|libfdk" <<<"$encoders"; then echo "FAIL: forbidden encoder"; fail=1; fi
  # CPU only: nothing may reach the hardware video encoder.
  if grep -Eq -- "--enable-videotoolbox" <<<"$conf"; then echo "FAIL: built with VideoToolbox"; fail=1; fi
  if grep -Eqi "videotoolbox" <<<"$encoders"; then echo "FAIL: a VideoToolbox encoder is in"; fail=1; fi
  if otool -L "$bin" | grep -q "VideoToolbox.framework"; then echo "FAIL: links VideoToolbox"; fail=1; fi
  local video_encoders; video_encoders="$(awk '$1 ~ /^V/ && $2 != "=" {print $2}' <<<"$encoders" | sort | xargs)"
  [[ "$video_encoders" == "gif libwebp libx264 libx265" ]] || { echo "FAIL: video encoders are '$video_encoders', expected 'gif libwebp libx264 libx265'"; fail=1; }
  local protocols; protocols="$("$bin" -hide_banner -protocols 2>&1 | sed -n '/Input:/,/Output:/p' | grep -Ev 'Input:|Output:' | xargs)"
  [[ "$protocols" == "file pipe" ]] || { echo "FAIL: input protocols are '$protocols'"; fail=1; }
  local demuxers; demuxers="$("$bin" -hide_banner -demuxers 2>&1)"
  if grep -Eq " (hls|dash|concat|sdp|rtsp|image2|tty|srt|webvtt) " <<<"$demuxers"; then echo "FAIL: a demuxer that can reach other files is in"; fail=1; fi
  # WebP out reads a PNG Frenzy wrote through this one. (Its configure name is image_png_pipe; plain png_pipe is ignored.)
  grep -Eq " png_pipe " <<<"$demuxers" || { echo "FAIL: the png_pipe demuxer WebP needs is missing"; fail=1; }
  # No socket code at all: these would be undefined symbols if any were linked.
  if nm -u "$bin" | grep -Eq "^_(socket|connect|getaddrinfo|gethostbyname|sendto|bind|listen|accept)$"; then
    echo "FAIL: binary imports socket functions"; fail=1
  fi
  # Only Apple's system libraries and frameworks at run time.
  if otool -L "$bin" | tail -n +2 | awk '{print $1}' | grep -Ev "^(/usr/lib/|/System/Library/)" | grep -q .; then
    echo "FAIL: links something outside the system"; otool -L "$bin"; fail=1
  fi
  [[ "$fail" == 0 ]] || exit 1
  echo "    arm64, $(du -h "$bin" | cut -f1), GPL per -L, no forbidden flags or encoders, no VideoToolbox, video encoders: $video_encoders (CPU), protocols: $protocols, no socket imports, system libraries only"
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -x "$ENGINE" ]] || { echo "error: no engine at $ENGINE" >&2; exit 1; }
  verify "$ENGINE"; exit 0
fi

export LC_ALL=C TZ=UTC ZERO_AR_DATE=1 SOURCE_DATE_EPOCH=1793750400
STAMP="$(shasum -a 256 < "$0" | cut -d' ' -f1)"
if [[ "${1:-}" != "--force" && -x "$ENGINE" && "$(cat "$OUT/.stamp" 2>/dev/null)" == "$STAMP" ]]; then
  echo "Media engine is up to date: $ENGINE"; exit 0
fi

# ── Sources ─────────────────────────────────────────────────────────────────────────────────────────────────
mkdir -p "$SOURCES"
: > "$SOURCES/SHA256SUMS"
for line in "${MANIFEST[@]}"; do
  IFS='|' read -r file url sha <<<"$line"
  if [[ ! -f "$SOURCES/$file" ]]; then
    echo "==> Downloading $file"
    curl -fL --retry 5 -C - -o "$SOURCES/$file.part" "$url"
    mv "$SOURCES/$file.part" "$SOURCES/$file"
  fi
  [[ "$(shasum -a 256 "$SOURCES/$file" | cut -d' ' -f1)" == "$sha" ]] || { echo "error: $file does not match its pinned SHA-256" >&2; exit 1; }
  echo "$sha  $file" >> "$SOURCES/SHA256SUMS"
done
echo "==> Sources match their pinned SHA-256"

# ── Clean tree ──────────────────────────────────────────────────────────────────────────────────────────────
rm -rf "$WORK"
mkdir -p "$WORK/src" "$WORK/prefix" "$WORK/tools/bin"
PREFIX="$WORK/prefix"
for line in "${MANIFEST[@]}"; do
  IFS='|' read -r file _ _ <<<"$line"
  tar -xf "$SOURCES/$file" -C "$WORK/src"
done
export CFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS" CXXFLAGS="-O2 -mmacosx-version-min=$MIN_MACOS" LDFLAGS="-mmacosx-version-min=$MIN_MACOS"
export CC=clang CXX=clang++

# FFmpeg asks pkg-config about "libwebp" and "dav1d". This Mac has no pkg-config, and a short stand-in beats a third download.
cat > "$WORK/tools/bin/pkg-config-shim" <<SHIM
#!/bin/sh
for a in "\$@"; do case "\$a" in
  --version) echo 0.29.2; exit 0 ;;
esac; done
pkg=""
for a in "\$@"; do case "\$a" in "libwebp"|"libwebp "*) pkg=libwebp ;; "dav1d"|"dav1d "*|"libdav1d"*) pkg=libdav1d ;; "x264"|"x264 "*) pkg=x264 ;; "x265"|"x265 "*) pkg=x265 ;; esac; done
[ -n "\$pkg" ] || exit 1
for a in "\$@"; do case "\$a" in
  --cflags) echo "-I$PREFIX/include"; exit 0 ;;
  --libs) case "\$pkg" in libwebp) echo "-L$PREFIX/lib -lwebp -lsharpyuv -lm" ;; x264) echo "-L$PREFIX/lib -lx264 -lm -lpthread" ;; x265) echo "-L$PREFIX/lib -lx265 -lc++ -lm -lpthread" ;; *) echo "-L$PREFIX/lib -ldav1d" ;; esac; exit 0 ;;
esac; done
exit 0
SHIM
chmod +x "$WORK/tools/bin/pkg-config-shim"

# ── LAME (LGPL) ─────────────────────────────────────────────────────────────────────────────────────────────
echo "==> Building LAME $LAME_V"
(
  cd "$WORK/src/lame-$LAME_V"
  # Known upstream slip: the export list names a function that isn't built.
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend \
    --disable-gtktest --disable-decoder --disable-dependency-tracking >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
)

# ── libwebp (BSD) ───────────────────────────────────────────────────────────────────────────────────────────
echo "==> Building libwebp $WEBP_V"
(
  cd "$WORK/src/libwebp-$WEBP_V"
  ./configure --host=aarch64-apple-darwin --prefix="$PREFIX" --enable-static --disable-shared --disable-dependency-tracking \
    --disable-libwebpdemux --disable-libwebpdecoder --disable-libwebpmux --disable-gl --disable-sdl --disable-png --disable-jpeg \
    --disable-tiff --disable-gif --disable-wic >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
)

# ── dav1d (BSD), built with Meson and Ninja ─────────────────────────────────────────────────────────────────
echo "==> Building Ninja $NINJA_V and dav1d $DAV1D_V"
(
  cd "$WORK/src/ninja-$NINJA_V"
  python3 -I configure.py --bootstrap >/dev/null
  cp ninja "$WORK/tools/bin/ninja"
)
(
  export PATH="$WORK/tools/bin:$PATH"
  cd "$WORK/src/dav1d-$DAV1D_V"
  python3 -I "$WORK/src/meson-$MESON_V/meson.py" setup build --prefix="$PREFIX" --libdir=lib --buildtype=release \
    --default-library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false -Dbitdepths=8,16 >/dev/null
  ninja -C build -j "$JOBS" >/dev/null
  ninja -C build install >/dev/null
)

# ── x264 (GPL v2 or later), CPU only ────────────────────────────────────────────────────────────────────────
echo "==> Building x264 ${X264_C:0:10}"
(
  cd "$WORK/src/x264-$X264_C"
  ./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl --enable-pic \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS" --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" >/dev/null
  make -j"$JOBS" >/dev/null 2>"$WORK/x264-make.err" || { tail -20 "$WORK/x264-make.err" >&2; exit 1; }
  make install >/dev/null
)

# ── x265 (GPL v2 or later), CPU only: 8-bit and 10-bit (HDR) in one static library ──────────────────────────
echo "==> Building x265 $X265_V"
command -v cmake >/dev/null || { echo "error: x265 needs cmake (pip/uv 'cmake' is fine)" >&2; exit 1; }
(
  S="$WORK/src/x265_$X265_V/source"
  # CMake 4 refuses OLD policies. CMP0025 OLD only made Apple's clang report as "Clang"; match AppleClang directly.
  sed -i '' -e '/cmake_policy(SET CMP0025 OLD)/d' -e '/cmake_policy(SET CMP0054 OLD)/d' \
    -e 's/if(${CMAKE_CXX_COMPILER_ID} STREQUAL "Clang")/if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")/' "$S/CMakeLists.txt"
  # No SVE: Apple silicon doesn't have it. NEON (and dot product) stays on.
  COMMON=(-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS"
          -DCMAKE_OSX_ARCHITECTURES=arm64 -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF
          -DENABLE_SVE=OFF -DENABLE_SVE2=OFF -Wno-dev -G "Unix Makefiles")
  mkdir -p "$WORK/x265-10" "$WORK/x265-8"
  cd "$WORK/x265-10"
  cmake "$S" "${COMMON[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=OFF >/dev/null 2>"$WORK/x265-cmake.err" || { tail -20 "$WORK/x265-cmake.err" >&2; exit 1; }
  make -j"$JOBS" >/dev/null 2>"$WORK/x265-make.err" || { tail -20 "$WORK/x265-make.err" >&2; exit 1; }
  cp libx265.a "$WORK/x265-8/libx265_main10.a"
  cd "$WORK/x265-8"
  cmake "$S" "${COMMON[@]}" -DEXTRA_LIB=x265_main10.a -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    >/dev/null 2>"$WORK/x265-cmake.err" || { tail -20 "$WORK/x265-cmake.err" >&2; exit 1; }
  make -j"$JOBS" >/dev/null 2>"$WORK/x265-make.err" || { tail -20 "$WORK/x265-make.err" >&2; exit 1; }
  mv libx265.a libx265_main.a
  libtool -static -o libx265.a libx265_main.a libx265_main10.a 2>/dev/null
  make install >/dev/null 2>&1 || true
  cp libx265.a "$PREFIX/lib/libx265.a"
)

# ── FFmpeg (GPL v2 or later, because of x264 and x265) ──────────────────────────────────────────────────────────────────────────────
echo "==> Configuring FFmpeg $FFMPEG_V"
unset CC CXX CFLAGS CXXFLAGS LDFLAGS
FF="$WORK/src/ffmpeg-$FFMPEG_V"
ARGS=()
while IFS= read -r arg; do ARGS+=("$arg"); done < <(configure_args "$PREFIX")
(
  cd "$FF"
  ./configure "${ARGS[@]}" | tee "$WORK/ffmpeg-configure.log" | grep -E "^(License|WARNING)|Unknown" || true
  grep -q "^License: GPL version 2 or later" "$WORK/ffmpeg-configure.log" || { echo "error: FFmpeg's configure did not report GPL 2 or later" >&2; exit 1; }
  grep -q '^#define CONFIG_GPL 1$' config.h || { echo "error: CONFIG_GPL is not 1" >&2; exit 1; }
  grep -q '^#define CONFIG_NONFREE 0$' config.h || { echo "error: CONFIG_NONFREE is not 0" >&2; exit 1; }
  echo "==> Building FFmpeg (a few minutes)"
  make -j"$JOBS" ffmpeg >/dev/null 2>"$WORK/ffmpeg-make.err" || { tail -20 "$WORK/ffmpeg-make.err" >&2; exit 1; }
)

# ── Install into vendor/build ───────────────────────────────────────────────────────────────────────────────
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/licenses"
cp "$FF/ffmpeg" "$ENGINE"
strip -x "$ENGINE"
codesign --force --sign - --identifier com.snappycrew.frenzy.media-engine "$ENGINE"

cp "$FF/COPYING.GPLv2" "$OUT/licenses/FFmpeg-COPYING.GPLv2.txt"
cp "$FF/COPYING.LGPLv2.1" "$OUT/licenses/FFmpeg-COPYING.LGPLv2.1.txt"
cp "$WORK/src/x264-$X264_C/COPYING" "$OUT/licenses/x264-COPYING.txt"
cp "$WORK/src/x265_$X265_V/COPYING" "$OUT/licenses/x265-COPYING.txt"
cp "$FF/LICENSE.md" "$OUT/licenses/FFmpeg-LICENSE.md"
cp "$WORK/src/lame-$LAME_V/COPYING" "$OUT/licenses/LAME-COPYING.txt"
cp "$WORK/src/libwebp-$WEBP_V/COPYING" "$OUT/licenses/libwebp-COPYING.txt"
cp "$WORK/src/libwebp-$WEBP_V/PATENTS" "$OUT/licenses/libwebp-PATENTS.txt"
cp "$WORK/src/dav1d-$DAV1D_V/COPYING" "$OUT/licenses/dav1d-COPYING.txt"

{
  echo "# The exact FFmpeg configure line behind vendor/build/arm64/bin/frenzy-media-engine."
  echo "# Run from a clean ffmpeg-$FFMPEG_V tree after building x264, x265, LAME, libwebp and dav1d as scripts/build-media-engine.sh does."
  echo "./configure \\"
  printf '  %q \\\n' "${ARGS[@]}"
  echo
} > "$VENDOR/configure-line.txt"

verify "$ENGINE"
echo "$STAMP" > "$OUT/.stamp"
echo "SHA-256 of the engine: $(shasum -a 256 "$ENGINE" | cut -d' ' -f1)"
echo "Done: $ENGINE ($(du -h "$ENGINE" | cut -f1))"
