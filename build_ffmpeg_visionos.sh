#!/bin/bash
# ============================================================================
# FFmpeg Build Script for visionOS — JellyLens
# ============================================================================
#
# Produces 6 dynamic XCFrameworks: libavcodec, libavformat, libavutil,
# libswresample, libswscale, libavfilter.
#
# ARCHITECTURE:
#   FFmpeg is used for DEMUXING + software audio/video decode + filters.
#   Video decode uses Apple VideoToolbox directly (not FFmpeg's VT wrapper).
#   AV1 software decode uses libdav1d (2-3x faster than FFmpeg built-in on M2).
#   Network I/O uses BOTH FFmpeg native HTTPS and custom AVIO (FFmpegCachingProtocol):
#     - Native HTTPS: MKV/WebM (FFmpeg handles EBML streaming robustly)
#     - Custom AVIO:  MP4/MOV (caching benefits seek-heavy moov parsing)
#
# LICENSE: LGPL 2.1+ (no --enable-gpl, no GPL external libraries)
#
# TLS: Apple SecureTransport (deprecated but functional on visionOS 26.2)
#   Future migration path: mbedTLS (Apache 2.0, +828KB, TLS 1.3 support)
#
# DEPENDENCIES:
#   libdav1d: Required for optimized AV1 decode (2-3x faster than FFmpeg built-in)
#   - Built from source for visionOS device + simulator (Homebrew dav1d is macOS-only;
#     linking it when cross-compiling FFmpeg fails: "built for macOS").
#   - Meson + Ninja required: brew install meson ninja
#   - License: BSD 2-clause (compatible with LGPL)
#
# Default version: n8.1.1 (override with FFMPEG_TAG env).
# ============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FFMPEG_SRC="${ROOT_DIR}/build/ffmpeg-src"
BUILD_DIR="${ROOT_DIR}/build/ffmpeg-build"
FFMPEG_TAG="${FFMPEG_TAG:-n8.1.1}"
VISIONOS_DEPLOYMENT_TARGET="26.2"

# dav1d: same major as Homebrew for predictable behavior (override with DAV1D_TAG)
DAV1D_SRC="${ROOT_DIR}/build/dav1d-src"
DAV1D_TAG="${DAV1D_TAG:-1.5.3}"
DAV1D_PREFIX_XROS="${ROOT_DIR}/build/dav1d-prefix-xros"
DAV1D_PREFIX_XRSIM="${ROOT_DIR}/build/dav1d-prefix-xrsimulator"

COMMON_FLAGS=(
  # === PLATFORM / CROSS-COMPILE ===
  --enable-cross-compile
  --target-os=darwin

  # === ARCHITECTURE / OPTIMIZATION ===
  --enable-optimizations
  --enable-lto
  --enable-pthreads
  --enable-neon           # ARM NEON SIMD - critical for software fallback decoders
  --enable-asm            # Assembly optimizations
  --enable-hardcoded-tables
  --disable-debug
  # Note: Additional ARM64 flags (-O3 -march=armv8-a+simd -mcpu=apple-m2 -ffast-math)
  # are set in --extra-cflags in build_target() below

  # === BUILD TYPE: Dynamic libraries for XCFramework embedding ===
  --enable-shared
  --disable-static
  --install-name-dir=@rpath

  # === DISABLE DEFAULTS ===
  --disable-everything
  --disable-programs
  --disable-doc
  --disable-autodetect

  # =========================================================================
  # NETWORK & TLS (CRITICAL: Required for HTTPS streaming from Jellyfin)
  # =========================================================================
  # FFmpeg needs native HTTPS for MKV/WebM direct streaming.
  # The custom AVIO path (FFmpegCachingProtocol) handles MP4/MOV caching.
  # Both paths coexist — see FFmpegDemuxer.swift shouldDisableCache logic.
  # SecureTransport provides TLS via Apple's Security.framework (zero binary overhead).
  --enable-network
  --enable-securetransport

  # === PROTOCOLS ===
  --enable-protocol=file       # Local file access
  --enable-protocol=http       # HTTP streaming (Jellyfin fallback/local)
  --enable-protocol=https      # HTTPS streaming (Jellyfin primary)
  --enable-protocol=tcp        # TCP transport (required by HTTP/HTTPS)
  --enable-protocol=tls        # TLS transport (required by HTTPS, selects SecureTransport)
  # FFmpeg 8.1+: old HLS protocol (hls+http) removed; use hls demuxer + http/https.

  # =========================================================================
  # DEMUXERS (CONTAINER FORMATS)
  # =========================================================================
  # Core containers — every format Jellyfin can serve
  --enable-demuxer=matroska    # MKV/WebM (primary format for Jellyfin media)
  --enable-demuxer=mov         # MP4/MOV/M4V (Apple native containers)
  --enable-demuxer=mpegts      # MPEG Transport Stream (live TV, DVR recordings)
  --enable-demuxer=mpegps      # MPEG-1/2 Program Stream (VOB, .mpeg, .mpg files); internal name ff_mpegps_demuxer
  --enable-demuxer=avi         # AVI (legacy media)
  --enable-demuxer=flv         # Flash Video (legacy streaming)
  --enable-demuxer=ogg         # OGG (Opus/Vorbis audio, Theora video)
  --enable-demuxer=asf         # ASF/WMV/WMA (Windows Media)
  --enable-demuxer=mxf         # MXF (professional broadcast)
  --enable-demuxer=hls         # HLS playlist demuxer
  --enable-demuxer=concat      # File concatenation
  --enable-demuxer=data        # Data protocol helper
  # Raw stream demuxers
  --enable-demuxer=h264        # Raw H.264 annex-B streams
  --enable-demuxer=hevc        # Raw HEVC streams
  --enable-demuxer=mpegvideo   # Raw MPEG-1/2 video — REQUIRED for MPEG-PS probe fix:
                               # avformat_find_stream_info sets request_probe=1 on MPEG-PS video PES
                               # (0xe0). Without mpegvideo_probe registered, mp3_probe wrongly wins
                               # on MPEG-2 bitstreams containing 0xff 0xf3 sync bytes. With this
                               # demuxer, mpegvideo_probe correctly identifies the video stream.
  --enable-demuxer=flac        # Standalone FLAC files
  --enable-demuxer=aac         # Raw AAC streams
  --enable-demuxer=mp3         # MP3 files
  --enable-demuxer=wav         # WAV audio files
  # Subtitle files (standalone, not embedded)
  --enable-demuxer=srt         # SRT subtitle files
  --enable-demuxer=ass         # ASS/SSA subtitle files

  # =========================================================================
  # MUXERS (output containers — needed by the v10 DV offline-cache path)
  # =========================================================================
  # MKVtoFMP4Remuxer (DV native v10, Rules 27-29) stream-copies HEVC+EAC3 from MKV
  # into a fragmented MP4 via FFmpeg's avformat_alloc_output_context2("mp4"). With
  # --disable-everything and no muxer enabled the call fails:
  #   "🎬 DV_NATIVE_FAILED stage=muxerUnavailable mp4_muxer_not_registered
  #    (FFmpeg --disable-muxers)" (device 2026-06-03)
  # which forces the v10 offline path to a degraded fallback. movenc provides both
  # mov and mp4 (incl. fragmented/fMP4). Copy-remux only — no encoders required.
  # The streaming-proxy default (Rule 30) does NOT use this; it only restores the
  # offline cache path.
  --enable-muxer=mov           # MOV container (movenc)
  --enable-muxer=mp4           # MP4 / fragmented MP4 (movenc) — required by MKVtoFMP4Remuxer

  # =========================================================================
  # VIDEO DECODERS
  # =========================================================================
  # Modern codecs (hardware decode via VideoToolbox, FFmpeg used as parser/fallback)
  --enable-decoder=h264
  --enable-decoder=hevc
  --enable-decoder=vp9         # No hardware decode on Vision Pro M2 — software only
  --enable-decoder=vp8         # Legacy WebM codec — software only
  --enable-decoder=libdav1d    # AV1 via dav1d (2-3x faster than built-in on M2)
                               # NOTE: av1_videotoolbox hwaccel is intentionally NOT enabled.
                               # M1/M2 have NO VideoToolbox AV1 decoder (not hardware, not software).
                               # AV1 routes to Path B (FFmpegPipeline) via libdav1d on M1/M2.
                               # M3+ hardware AV1 can be added when it's supported in FFmpeg stable.
  --enable-decoder=av1         # AV1 built-in fallback if libdav1d unavailable at runtime
                               # FFmpegVideoDecoder prefers libdav1d by name; this is a compile-time backup.
  # Professional formats
  --enable-decoder=prores
  --enable-decoder=prores_aw
  --enable-decoder=prores_ks
  --enable-decoder=dnxhd
  # Legacy formats
  --enable-decoder=vc1
  --enable-decoder=wmv3
  --enable-decoder=mpeg2video
  --enable-decoder=mpeg4
  --enable-decoder=msmpeg4v2
  --enable-decoder=msmpeg4v3
  --enable-decoder=svq3
  --enable-decoder=h263
  --enable-decoder=flv
  --enable-decoder=rv10
  --enable-decoder=rv20
  --enable-decoder=rv30
  --enable-decoder=rv40
  --enable-decoder=theora      # Theora (OGV) — completes the Experimental-Formats story (Rule 31);
                               # ogg demuxer already enabled (line above), software decode only.
  --enable-decoder=vvc         # VVC/H.266 — future-proofing fold-in pre-authorized by
  --enable-parser=vvc          # memory/topics/ffmpeg-build-assessment.md ("if we ever DO rebuild").
  # Image decoders (cover art in MKV, thumbnails)
  --enable-decoder=mjpeg
  --enable-decoder=png
  --enable-decoder=webp

  # =========================================================================
  # AUDIO DECODERS
  # =========================================================================
  # Passthrough formats (AC3/EAC3/AAC use AVSampleBufferAudioRenderer hardware)
  --enable-decoder=aac
  --enable-decoder=aac_latm
  --enable-decoder=ac3
  --enable-decoder=eac3
  # Lossless audio (FFmpeg decode to PCM)
  --enable-decoder=flac
  --enable-decoder=truehd
  --enable-decoder=mlp
  --enable-decoder=alac
  --enable-decoder=wavpack
  # DTS family (FFmpeg decode to PCM)
  --enable-decoder=dca
  # Lossy audio (FFmpeg decode to PCM)
  --enable-decoder=opus
  --enable-decoder=vorbis
  --enable-decoder=mp3
  --enable-decoder=mp2
  # Windows Media Audio
  --enable-decoder=wmalossless
  --enable-decoder=wmav1
  --enable-decoder=wmav2
  --enable-decoder=wmapro
  # PCM formats (passthrough/minimal decode)
  --enable-decoder=pcm_s16le
  --enable-decoder=pcm_s24le
  --enable-decoder=pcm_s32le
  --enable-decoder=pcm_f32le
  --enable-decoder=pcm_s16be
  --enable-decoder=pcm_s24be
  --enable-decoder=pcm_s32be
  --enable-decoder=pcm_f32be
  --enable-decoder=pcm_bluray
  # ADPCM / telephony
  --enable-decoder=adpcm_ms
  --enable-decoder=adpcm_ima_wav
  --enable-decoder=g726
  --enable-decoder=g729
  --enable-decoder=gsm_ms

  # =========================================================================
  # SUBTITLE DECODERS
  # =========================================================================
  # Text subtitles (extracted and rendered in Swift)
  --enable-decoder=ass
  --enable-decoder=ssa
  --enable-decoder=srt
  --enable-decoder=subrip
  --enable-decoder=webvtt
  --enable-decoder=mov_text     # MP4 tx3g text subtitles
  --enable-decoder=ttml          # TTML text subtitles
  --enable-decoder=microdvd      # MicroDVD text subtitles
  --enable-decoder=sami          # SAMI/SMI text subtitles
  # Bitmap subtitles (PGS/VOBSUB for burn-in via overlay filter)
  --enable-decoder=pgssub       # PGS (Blu-ray)
  --enable-decoder=dvdsub       # VOBSUB (DVD)
  --enable-decoder=dvbsub       # DVB

  # =========================================================================
  # PARSERS (Frame detection, codec parameter extraction)
  # =========================================================================
  --enable-parser=h264
  --enable-parser=hevc
  --enable-parser=vp9
  --enable-parser=av1
  --enable-parser=mpegvideo    # MPEG-1/2 video — required for avformat_find_stream_info to identify MPEG-PS video streams
  --enable-parser=mpeg4video
  --enable-parser=vc1
  --enable-parser=aac
  --enable-parser=aac_latm
  --enable-parser=flac
  --enable-parser=dca
  --enable-parser=ac3
  --enable-parser=mlp
  --enable-parser=mpegaudio
  --enable-parser=opus
  --enable-parser=vorbis

  # =========================================================================
  # BITSTREAM FILTERS
  # =========================================================================
  --enable-bsf=h264_mp4toannexb   # H.264 MP4 to Annex-B conversion
  --enable-bsf=hevc_mp4toannexb   # HEVC MP4 to Annex-B conversion
  --enable-bsf=av1_frame_merge    # AV1 temporal unit assembly
  --enable-bsf=av1_metadata       # AV1 metadata injection
  --enable-bsf=vp9_superframe     # VP9 superframe handling
  --enable-bsf=opus_metadata      # Opus header rewriting
  --enable-bsf=aac_adtstoasc      # AAC ADTS to ASC conversion
  --enable-bsf=extract_extradata  # Codec extradata extraction (Atmos detection)
  --enable-bsf=prores_metadata    # ProRes metadata
  --enable-bsf=dnxhd_metadata     # DNxHD metadata

  # =========================================================================
  # FILTERS (libavfilter — all LGPL, zero license change)
  # =========================================================================
  --enable-avfilter
  --enable-filter=scale          # Video scaling
  --enable-filter=format         # Pixel format conversion
  --enable-filter=aformat        # Audio format conversion
  --enable-filter=asetnsamples   # Audio sample count adjustment
  --enable-filter=cropdetect     # Black bar detection for cinema mode
  --enable-filter=yadif          # Deinterlacing (standard quality)
  --enable-filter=yadif_videotoolbox  # VT-accelerated deinterlacing (broadcast/MPEG-TS content)
  --enable-filter=bwdif          # Deinterlacing (higher quality, Bob Weaver)
  --enable-filter=loudnorm       # EBU R128 audio normalization
  --enable-filter=ebur128        # Loudness measurement (loudnorm dependency)
  --enable-filter=atempo         # Audio tempo/pitch correction for speed-ramped playback (1.5x/2x)
  --enable-filter=overlay        # Bitmap subtitle compositing (PGS/VOBSUB)
  --enable-filter=volume         # Audio volume adjustment
  --enable-filter=anull          # Audio null filter (filter graph support)
  --enable-filter=null           # Video null filter (filter graph support)

  # === RESAMPLING & CONVERSION ===
  --enable-swscale               # Video scaling/pixel format conversion
  --enable-swresample            # Audio resampling/format conversion

  # === SYSTEM LIBRARIES ===
  --enable-zlib                  # MKV compressed headers, some codecs

  # =========================================================================
  # EXPLICIT DISABLES (clarity — autodetect is off, but be explicit)
  # =========================================================================
  --enable-videotoolbox          # FFmpeg VT hwaccel for HEVC/H.264 decode (PathDVideoDecoder)
  --enable-hwaccel=hevc_videotoolbox      # HEVC: display-order PTS via FFmpeg DPB (PathDVideoDecoder)
  --enable-hwaccel=h264_videotoolbox      # H.264: available, currently unused (ASBDL handles h264)
  --enable-hwaccel=mpeg2_videotoolbox     # MPEG-2: hardware VT decode (broadcast/MPEG-TS content)
  --enable-hwaccel=mpeg4_videotoolbox     # MPEG-4 Part 2: hardware VT decode (older Jellyfin libraries)
  --enable-hwaccel=prores_videotoolbox    # ProRes: hardware VT decode (professional/MXF content)
  --enable-hwaccel=vp9_videotoolbox       # VP9: VT hwaccel (M4+ hardware; M2 falls back to software)
  --disable-audiotoolbox         # App handles audio via AVAudioEngine
  --disable-schannel             # Windows TLS (not applicable)
  --disable-gnutls               # We use SecureTransport instead
  --disable-openssl              # We use SecureTransport instead
  --disable-mbedtls              # We use SecureTransport instead
  --disable-gmp                  # Not needed without GnuTLS
  --disable-lcms2                # Color management (visionOS handles tone mapping)
  --enable-libdav1d              # External AV1 decoder (2-3x faster than built-in)
  --disable-libuavs3d            # No AVS3 decoder
  --disable-libxml2              # No DASH manifest parsing needed
)

clean() {
  rm -rf "${FFMPEG_SRC}" "${BUILD_DIR}" \
    "${DAV1D_SRC}" "${DAV1D_PREFIX_XROS}" "${DAV1D_PREFIX_XRSIM}"
}

fetch_src() {
  mkdir -p "${BUILD_DIR}"
  if [ ! -d "${FFMPEG_SRC}" ]; then
    echo "   Cloning FFmpeg from git.ffmpeg.org..."
    git clone --depth 1 --branch "${FFMPEG_TAG}" https://git.ffmpeg.org/ffmpeg.git "${FFMPEG_SRC}"
  fi
  # PATCH: visionOS has no OpenGL ES — guard both OpenGL CVPixelBuffer keys.
  # kCVPixelBufferOpenGLESCompatibilityKey (TARGET_OS_IPHONE branch) and
  # kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey (macOS else branch) are both
  # unavailable on xros. The correct fix is to skip the GLES key on visionOS only.
  python3 - "${FFMPEG_SRC}/libavcodec/videotoolbox.c" <<'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old = (
    '#if TARGET_OS_IPHONE\n'
    '    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);\n'
    '#else\n'
    '    CFDictionarySetValue(buffer_attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey, kCFBooleanTrue);\n'
    '#endif'
)
new = (
    '#if TARGET_OS_IPHONE\n'
    '#if !TARGET_OS_VISION\n'
    '    /* kCVPixelBufferOpenGLESCompatibilityKey unavailable on visionOS (no OpenGL ES) */\n'
    '    CFDictionarySetValue(buffer_attributes, kCVPixelBufferOpenGLESCompatibilityKey, kCFBooleanTrue);\n'
    '#endif\n'
    '#else\n'
    '    CFDictionarySetValue(buffer_attributes, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey, kCFBooleanTrue);\n'
    '#endif'
)
if old in src:
    src = src.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(src)
    print("videotoolbox.c: visionOS OpenGL ES patch applied")
elif new in src:
    print("videotoolbox.c: visionOS OpenGL ES patch already present")
else:
    print("WARNING: videotoolbox.c: expected pattern not found — patch skipped")
PYEOF
  # PATCH: defect #23 (2026-06-10 crash triplet) — SSLClose on an interrupt-aborted
  # handshake NULL-derefs inside SecureTransport (SSLSendAlert ← tls_handshake_close
  # ← SSLClose). The 5s interrupt aborts SSLHandshake mid-flight on a starved server;
  # tls_close then calls SSLClose on the half-negotiated context → EXC_BAD_ACCESS 0x0
  # on com.jellylens.ffmpeg.read. Guard: only send close_notify (SSLClose) when the
  # handshake actually completed; CFRelease alone is safe on any context state.
  python3 - "${FFMPEG_SRC}/libavformat/tls_securetransport.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
patches = [
    # 1. Track handshake completion in TLSContext (priv_data is zero-initialized).
    ("    int lastErr;\n} TLSContext;",
     "    int lastErr;\n    int handshake_done;\n} TLSContext;"),
    # 2. Never SSLClose a context whose handshake did not complete.
    ("    if (c->ssl_context) {\n        SSLClose(c->ssl_context);\n        CFRelease(c->ssl_context);\n    }",
     "    if (c->ssl_context) {\n        /* JellyLens #23: SSLClose on an aborted handshake NULL-derefs in\n         * SecureTransport (tls_handshake_close -> SSLSendAlert). Skip close_notify\n         * unless the handshake completed; releasing the context is always safe. */\n        if (c->handshake_done)\n            SSLClose(c->ssl_context);\n        CFRelease(c->ssl_context);\n    }"),
    # 3. Mark completion at the single handshake-success exit.
    ("        if (status == noErr) {\n            break;",
     "        if (status == noErr) {\n            c->handshake_done = 1;\n            break;"),
]
applied = 0
for old, new in patches:
    if new in src:
        applied += 1
        continue
    if old not in src:
        print(f"ERROR: tls_securetransport.c: anchor not found for patch {applied + 1} — ABORTING")
        sys.exit(1)
    src = src.replace(old, new, 1)
    applied += 1
with open(path, 'w') as f:
    f.write(src)
print(f"tls_securetransport.c: handshake-guard patch OK ({applied}/3 hunks)")
PYEOF
}

fetch_dav1d_src() {
  mkdir -p "$(dirname "${DAV1D_SRC}")"
  if [ ! -d "${DAV1D_SRC}" ]; then
    echo "   Cloning dav1d ${DAV1D_TAG}..."
    git clone --depth 1 --branch "${DAV1D_TAG}" https://code.videolan.org/videolan/dav1d.git "${DAV1D_SRC}"
  fi
}

# Build static libdav1d for the given visionOS SDK so FFmpeg's configure link test passes.
build_dav1d_for_sdk() {
  local sdk="$1"
  local prefix="$2"
  local target_triple=""
  if [[ "${sdk}" == "xros" ]]; then
    target_triple="arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}"
  elif [[ "${sdk}" == "xrsimulator" ]]; then
    target_triple="arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}-simulator"
  else
    echo "ERROR: unknown SDK ${sdk}"
    return 1
  fi

  local sysroot
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"
  local build_dir="${DAV1D_SRC}/build-${sdk}"
  local cross_ini="${DAV1D_SRC}/cross-${sdk}.ini"

  echo "   Building dav1d for ${sdk} -> ${prefix}"

  cat > "${cross_ini}" <<CROSSINI
[binaries]
c = ['xcrun', '--sdk', '${sdk}', 'clang']
cpp = ['xcrun', '--sdk', '${sdk}', 'clang++']
ar = ['xcrun', '--sdk', '${sdk}', 'ar']
strip = ['xcrun', '--sdk', '${sdk}', 'strip']
pkg-config = ['pkg-config']

[properties]
needs_exe_wrapper = false
sys_root = '${sysroot}'
c_args = ['-target', '${target_triple}', '-isysroot', '${sysroot}']
cpp_args = ['-target', '${target_triple}', '-isysroot', '${sysroot}']
c_link_args = ['-target', '${target_triple}', '-isysroot', '${sysroot}']
cpp_link_args = ['-target', '${target_triple}', '-isysroot', '${sysroot}']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
CROSSINI

  pushd "${DAV1D_SRC}" >/dev/null
  rm -rf "${build_dir}"
  meson setup "${build_dir}" \
    --prefix="${prefix}" \
    --default-library=static \
    --buildtype=release \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_docs=false \
    --cross-file="${cross_ini}"

  local num_cores
  num_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  ninja -C "${build_dir}" -j"${num_cores}"
  ninja -C "${build_dir}" install
  popd >/dev/null

  if [ ! -f "${prefix}/lib/pkgconfig/dav1d.pc" ]; then
    echo "ERROR: dav1d install missing ${prefix}/lib/pkgconfig/dav1d.pc"
    return 1
  fi
}

build_target() {
  local arch="$1"
  local sdk="$2"       # xros or xrsimulator
  local out_dir="$3"

  mkdir -p "${out_dir}"
  pushd "${FFMPEG_SRC}" >/dev/null

  # Clean previous build
  make distclean 2>/dev/null || true

  # Both device and simulator use arm64 on Apple Silicon
  local target_triple=""
  local arch_flag=""
  if [[ "${sdk}" == "xros" ]]; then
    target_triple="arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}"
    arch_flag="--arch=arm64 --cpu=armv8 --enable-neon"
  elif [[ "${sdk}" == "xrsimulator" ]]; then
    target_triple="arm64-apple-xros${VISIONOS_DEPLOYMENT_TARGET}-simulator"
    arch_flag="--arch=arm64 --cpu=armv8 --enable-neon"
  fi

  echo "   Target: ${target_triple} (${sdk})"

  local sysroot
  sysroot="$(xcrun --sdk "${sdk}" --show-sdk-path)"

  # visionOS-built dav1d (static .a); Homebrew dav1d is macOS and breaks the link test.
  local dav1d_pc=""
  if [[ "${sdk}" == "xros" ]]; then
    dav1d_pc="${DAV1D_PREFIX_XROS}/lib/pkgconfig"
  else
    dav1d_pc="${DAV1D_PREFIX_XRSIM}/lib/pkgconfig"
  fi

  # Optional: Homebrew pkg-config for zlib and other host helpers
  local hb_pc=""
  if [ -d "/opt/homebrew/lib/pkgconfig" ]; then
    hb_pc="/opt/homebrew/lib/pkgconfig"
  elif [ -d "/usr/local/lib/pkgconfig" ]; then
    hb_pc="/usr/local/lib/pkgconfig"
  fi

  local pkg_config_path="${dav1d_pc}"
  if [ -n "${hb_pc}" ]; then
    pkg_config_path="${dav1d_pc}:${hb_pc}"
  fi

  # Configure FFmpeg for visionOS
  PKG_CONFIG_PATH="${pkg_config_path}" \
  CC="xcrun --sdk ${sdk} clang" \
  CXX="xcrun --sdk ${sdk} clang++" \
  LD="xcrun --sdk ${sdk} clang" \
  ./configure \
    --sysroot="${sysroot}" \
    --prefix="${out_dir}" \
    --extra-cflags="-target ${target_triple} -isysroot ${sysroot} -O3 -march=armv8-a+simd -mcpu=apple-m2 -ffast-math" \
    --extra-ldflags="-target ${target_triple} -isysroot ${sysroot}" \
    ${arch_flag} \
    "${COMMON_FLAGS[@]}"

  # Build with all cores
  local num_cores
  num_cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
  echo "   Compiling with ${num_cores} cores..."

  if ! make -j"${num_cores}"; then
    echo "Build failed for ${sdk}"
    echo "   Check ${FFMPEG_SRC}/ffbuild/config.log for details"
    popd >/dev/null
    return 1
  fi

  make install
  popd >/dev/null
}

fix_install_names() {
  # Rewrite versioned sonames to unversioned for XCFramework compatibility.
  # FFmpeg embeds e.g. @rpath/libavcodec.62.dylib but XCFramework packages
  # the file as libavcodec.dylib. Without this fix, dyld crashes at launch:
  #   "Library not loaded: @rpath/libavcodec.62.dylib"
  local dylib="$1"

  # Versioned:Unversioned pairs for our 6 libraries (bash 3.2 compatible)
  local pairs="libavcodec.62:libavcodec libavformat.62:libavformat libavutil.60:libavutil libswresample.6:libswresample libswscale.9:libswscale libavfilter.11:libavfilter"

  # Fix self install name (the -id)
  local current_id
  current_id=$(otool -D "${dylib}" 2>/dev/null | tail -1)
  for pair in ${pairs}; do
    local versioned="${pair%%:*}"
    local unversioned="${pair##*:}"
    if echo "${current_id}" | grep -q "${versioned}.dylib"; then
      install_name_tool -id "@rpath/${unversioned}.dylib" "${dylib}" 2>/dev/null || true
      break
    fi
  done

  # Fix all cross-library references
  for pair in ${pairs}; do
    local versioned="${pair%%:*}"
    local unversioned="${pair##*:}"
    install_name_tool -change \
      "@rpath/${versioned}.dylib" \
      "@rpath/${unversioned}.dylib" \
      "${dylib}" 2>/dev/null || true
  done
}

create_xcframeworks() {
  local device_lib="${BUILD_DIR}/visionos/lib"
  local sim_lib="${BUILD_DIR}/simulator/lib"
  local device_headers="${BUILD_DIR}/visionos/include"
  local sim_headers="${BUILD_DIR}/simulator/include"
  local output_dir="${ROOT_DIR}/Jelly_ffmpeg"

  # All 6 libraries including libavfilter
  local libs=("libavcodec" "libavformat" "libavutil" "libswresample" "libswscale" "libavfilter")

  echo "Creating XCFrameworks (dynamic libraries)..."

  # Detect simulator availability
  local has_simulator=false
  if [ -f "${sim_lib}/libavcodec.dylib" ]; then
    has_simulator=true
    echo "   Device + Simulator (universal)"
  else
    echo "   Device-only (simulator build unavailable)"
  fi

  # Create per-library header directories to avoid "Multiple commands produce" Xcode errors.
  # Each XCFramework gets only its own library's headers. Cross-library includes
  # (e.g. libavformat including libavutil) resolve because Xcode combines header
  # search paths from all linked XCFrameworks.
  local per_lib_headers="${BUILD_DIR}/per-lib-headers"
  rm -rf "${per_lib_headers}"
  for lib in "${libs[@]}"; do
    local device_hdr_dir="${per_lib_headers}/${lib}/device/${lib}"
    local sim_hdr_dir="${per_lib_headers}/${lib}/sim/${lib}"
    mkdir -p "${device_hdr_dir}"
    if [ -d "${device_headers}/${lib}" ]; then
      cp "${device_headers}/${lib}"/*.h "${device_hdr_dir}/"
    fi
    if [ "$has_simulator" = true ]; then
      mkdir -p "${sim_hdr_dir}"
      if [ -d "${sim_headers}/${lib}" ]; then
        cp "${sim_headers}/${lib}"/*.h "${sim_hdr_dir}/"
      fi
    fi
  done

  for lib in "${libs[@]}"; do
    local device_dylib="${device_lib}/${lib}.dylib"
    local sim_dylib="${sim_lib}/${lib}.dylib"
    local xcfw_path="${output_dir}/${lib}.xcframework"
    local lib_device_headers="${per_lib_headers}/${lib}/device"
    local lib_sim_headers="${per_lib_headers}/${lib}/sim"

    # Remove old framework
    if [ -d "${xcfw_path}" ]; then
      rm -rf "${xcfw_path}"
    fi

    # Verify device library exists
    if [ ! -f "${device_dylib}" ]; then
      echo "ERROR: Missing ${device_dylib}"
      exit 1
    fi

    # Stage dereferenced dylibs (FFmpeg installs versioned dylibs with symlinks;
    # xcodebuild -create-xcframework copies only the symlink, leaving a dangling ref)
    local staging="${BUILD_DIR}/staging/${lib}"
    rm -rf "${staging}"
    mkdir -p "${staging}/device" "${staging}/sim"
    cp -L "${device_dylib}" "${staging}/device/${lib}.dylib"

    # CRITICAL: Fix versioned install names for XCFramework compatibility.
    # FFmpeg embeds soname versions (e.g. @rpath/libavcodec.62.dylib) but
    # XCFrameworks package files as libavcodec.dylib (unversioned). At runtime,
    # dyld searches for the versioned name and crashes: "Library not loaded".
    # Fix: rewrite all install names and cross-references to unversioned form.
    fix_install_names "${staging}/device/${lib}.dylib"

    # Create XCFramework with per-library headers and dereferenced dylibs
    echo "   ${lib}.xcframework..."
    if [ "$has_simulator" = true ] && [ -f "${sim_dylib}" ]; then
      cp -L "${sim_dylib}" "${staging}/sim/${lib}.dylib"
      fix_install_names "${staging}/sim/${lib}.dylib"
      xcodebuild -create-xcframework \
        -library "${staging}/device/${lib}.dylib" \
        -headers "${lib_device_headers}" \
        -library "${staging}/sim/${lib}.dylib" \
        -headers "${lib_sim_headers}" \
        -output "${xcfw_path}"
    else
      xcodebuild -create-xcframework \
        -library "${staging}/device/${lib}.dylib" \
        -headers "${lib_device_headers}" \
        -output "${xcfw_path}"
    fi

    if [ -d "${xcfw_path}" ]; then
      local size
      size=$(du -sh "${xcfw_path}" | awk '{print $1}')
      echo "   OK ${lib}.xcframework (${size})"
    else
      echo "   FAILED to create ${lib}.xcframework"
      exit 1
    fi
  done

  echo "All XCFrameworks created"
}

copy_headers() {
  local headers_src="${BUILD_DIR}/visionos/include"
  local headers_dst="${ROOT_DIR}/Jelly_ffmpeg/headers"

  echo "Updating header files..."

  if [ ! -d "${headers_src}" ]; then
    echo "   No headers found in build output - skipping"
    return
  fi

  # Remove old headers and copy fresh ones
  rm -rf "${headers_dst}"
  cp -R "${headers_src}" "${headers_dst}"

  # Count headers
  local count
  count=$(find "${headers_dst}" -name "*.h" | wc -l | tr -d ' ')
  echo "   ${count} header files copied to Jelly_ffmpeg/headers/"

  # Verify critical headers
  local critical_headers=(
    "libavfilter/avfilter.h"
    "libavformat/avformat.h"
    "libavcodec/avcodec.h"
  )
  for hdr in "${critical_headers[@]}"; do
    if [ -f "${headers_dst}/${hdr}" ]; then
      echo "   OK ${hdr}"
    else
      echo "   MISSING ${hdr}"
    fi
  done
}

verify_https() {
  # Verify SecureTransport and HTTPS protocol are compiled in
  local device_lib="${BUILD_DIR}/visionos/lib/libavformat.dylib"
  if [ -f "${device_lib}" ]; then
    echo "Verifying HTTPS support..."
    # NOTE: use -E. macOS uses BSD grep where `\|` in a BASIC regex is a literal
    # pipe, NOT alternation — `grep "A\|B"` searched for the literal "A|B" and
    # never matched, producing a false "symbols not found" warning even on a
    # correctly-linked dylib (2026-06-03 false alarm). `_SSLCreateContext` is an
    # UNDEFINED import (`U _SSLCreateContext` in nm output) — that's the correct
    # signal that FFmpeg's SecureTransport TLS impl is compiled in and references
    # the system framework.
    if nm -g "${device_lib}" 2>/dev/null | grep -qE "SSLCreateContext|_ff_tls_open"; then
      echo "   OK SecureTransport TLS linked"
    else
      echo "   WARNING: SecureTransport symbols not found in libavformat"
    fi
  fi
}

main() {
  echo "================================================================"
  echo "  FFmpeg Build for visionOS"
  echo "================================================================"
  echo "  FFmpeg:     ${FFMPEG_TAG}"
  echo "  Target:     visionOS ${VISIONOS_DEPLOYMENT_TARGET} (arm64 device + simulator)"
  echo "  Libraries:  6 XCFrameworks (dynamic, LGPL 2.1+)"
  echo "  License:    LGPL 2.1+ (no --enable-gpl)"
  echo "  TLS:        SecureTransport (Apple Security.framework)"
  echo "  Network:    Native HTTPS + custom AVIO (dual path)"
  echo "================================================================"
  echo ""

  echo "Cleaning old builds..."
  clean || true

  echo "Fetching FFmpeg ${FFMPEG_TAG}..."
  fetch_src

  echo ""
  echo "Building dav1d ${DAV1D_TAG} for visionOS (required for --enable-libdav1d)..."
  fetch_dav1d_src
  if ! build_dav1d_for_sdk "xros" "${DAV1D_PREFIX_XROS}"; then
    echo "Device dav1d build failed"
    exit 1
  fi

  local sim_dav1d_ok=0
  if build_dav1d_for_sdk "xrsimulator" "${DAV1D_PREFIX_XRSIM}"; then
    sim_dav1d_ok=1
  else
    echo "   Simulator dav1d build failed - will build device-only FFmpeg XCFrameworks"
  fi

  echo ""
  echo "Building for visionOS device (arm64)..."
  if ! build_target "arm64" "xros" "${BUILD_DIR}/visionos"; then
    echo "Device build failed"
    exit 1
  fi
  echo "Device build complete"

  echo ""
  if [ "${sim_dav1d_ok}" -eq 1 ]; then
    echo "Building for visionOS simulator (arm64)..."
    if ! build_target "arm64" "xrsimulator" "${BUILD_DIR}/simulator"; then
      echo "Simulator build failed - continuing with device-only"
    fi
  else
    echo "Skipping visionOS simulator FFmpeg (dav1d for simulator unavailable)"
  fi

  echo ""
  echo "Creating XCFrameworks..."
  create_xcframeworks

  echo ""
  copy_headers

  echo ""
  verify_https

  # Verify
  echo ""
  echo "Final Verification..."
  local output_dir="${ROOT_DIR}/Jelly_ffmpeg"
  local libs=("libavcodec" "libavformat" "libavutil" "libswresample" "libswscale" "libavfilter")
  local all_valid=true

  for lib in "${libs[@]}"; do
    local xcfw_path="${output_dir}/${lib}.xcframework"
    if [ -d "${xcfw_path}" ] && [ -f "${xcfw_path}/Info.plist" ]; then
      echo "   OK ${lib}.xcframework"
    else
      echo "   MISSING ${lib}.xcframework"
      all_valid=false
    fi
  done

  if [ "$all_valid" = true ]; then
    echo ""
    echo "================================================================"
    echo "  BUILD SUCCEEDED"
    echo "================================================================"
    echo "  Video:      H.264, HEVC, VP9, AV1 (libdav1d), ProRes, DNxHD, VC-1"
    echo "  Audio:      AAC, AC3/EAC3, FLAC, TrueHD, DTS, Opus, Vorbis, WMA"
    echo "  Subtitles:  ASS/SSA, SRT, WebVTT, PGS, VOBSUB, DVB"
    echo "  Containers: MKV, WebM, TS, MP4, MOV, MXF, AVI, FLV, OGG, HLS"
    echo "  Filters:    cropdetect, yadif, bwdif, loudnorm, overlay, volume"
    echo "  Network:    HTTPS (SecureTransport TLS), HTTP; HLS via demuxer (no hls:// protocol in 8.1+)"
    echo "  Output:     ${output_dir}/"
    echo "================================================================"
  else
    echo "Build verification failed"
    exit 1
  fi
}

main "$@"
