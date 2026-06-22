# JellyLens — FFmpeg Source (LGPL v2.1+)

This repository provides the **complete corresponding source code** for the
FFmpeg libraries distributed inside the JellyLens visionOS app, as required by
the GNU Lesser General Public License, version 2.1.

## What ships in the app

- FFmpeg **n8.1.1** (`libavcodec`, `libavformat`, `libavutil`, `libswresample`,
  `libswscale`, `libavfilter`), built as **dynamic** XCFrameworks
  (`--enable-shared --disable-static`) so the libraries can be replaced by the
  user (LGPL §6).
- Configured **LGPL-only**: no `--enable-gpl`, no `--enable-nonfree`, no GPL
  external libraries (no x264/x265). Decoder-only build.
- One external codec library is statically linked into the FFmpeg dylib:
  **dav1d 1.5.3** (AV1 decoder, **BSD-2-Clause**,
  https://code.videolan.org/videolan/dav1d, tag `1.5.3`), enabled via
  `--enable-libdav1d`. It is permissively licensed (no copyleft); its notice
  ships in the app's third-party license list. VP8/VP9 use FFmpeg's own
  built-in native decoders — no external `libvpx`.

## Source

The full source is attached to the [**v8.1** release](https://github.com/jellylens/ffmpeg/releases/tag/v8.1)
as `jellylens-ffmpeg-8.1.1-source.tar.gz` (FFmpeg n8.1.1, base commit `239f2c7`).

### JellyLens modifications to upstream

Two files are modified relative to upstream n8.1.1. The exact diff is in
[`jellylens-ffmpeg-8.1.1-modifications.patch`](jellylens-ffmpeg-8.1.1-modifications.patch):

- `libavcodec/videotoolbox.c`
- `libavformat/tls_securetransport.c`

The modified files are included in the source tarball above.

## Building

The exact configure flags and XCFramework packaging are in
[`build_ffmpeg_visionos.sh`](build_ffmpeg_visionos.sh) — the script used to
control compilation and installation.

## License

LGPL v2.1+ — see [`COPYING.LGPLv2.1`](COPYING.LGPLv2.1).
