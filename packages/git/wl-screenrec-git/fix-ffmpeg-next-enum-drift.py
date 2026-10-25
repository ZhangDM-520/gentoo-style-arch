#!/usr/bin/env python3
"""Insert drift catch-all arms into ffmpeg-next 9.0.0's sys-enum From impls.

ffmpeg-next 9.0.0 (the latest release) matches the ffmpeg-9.0 sys enums
EXHAUSTIVELY in its `impl From<sys::X> for Y` conversions. The house
ffmpeg-git tracks upstream HEAD, whose enums keep growing variants
(AV_SAMPLE_FMT_DSD, AV_PIX_FMT_CUARRAY/XYZP12*, AV_CODEC_ID_ASTC/...,
*_GAIN_MAP_PARAMS, ...), so those matches fail E0004 on every new variant
until upstream cuts a release. This adds one catch-all arm per match:
  - Sample/Pixel/CodecId map unknown variants to their `None` sentinel
  - the two closed side-data Type enums fall to unreachable!() — loud if a
    decode-side mapping is ever handed a variant newer than the crate
Compile-only shim; wl-screenrec encodes via VA-API/Vulkan and never
consumes these mappings for the drifted variants.

Self-verifying: each insertion asserts it found its anchor, so a crate
layout change aborts the build loudly instead of silently skipping.
Usage: fix-ffmpeg-next-enum-drift.py <ffmpeg-next crate source dir>
"""
import os
import sys

FALLBACKS = [
    (
        "src/util/format/sample.rs",
        "impl From<AVSampleFormat> for Sample",
        "Sample::None",
    ),
    (
        "src/util/format/pixel.rs",
        "impl From<AVPixelFormat> for Pixel",
        "Pixel::None",
    ),
    (
        "src/util/frame/side_data.rs",
        "impl From<AVFrameSideDataType> for Type",
        'unreachable!("frame side-data variant newer than ffmpeg-next 9.0 '
        '(compile shim)")',
    ),
    (
        "src/codec/id.rs",
        "impl From<AVCodecID> for Id",
        "Id::None",
    ),
    (
        "src/codec/packet/side_data.rs",
        "impl From<AVPacketSideDataType> for Type",
        'unreachable!("packet side-data variant newer than ffmpeg-next 9.0 '
        '(compile shim)")',
    ),
]


def patch_file(root: str, rel: str, header: str, fallback: str) -> None:
    path = os.path.join(root, rel)
    text = open(path).read()
    h = text.find(header)
    if h < 0:
        sys.exit(f"fix-ffmpeg-next-enum-drift: anchor not found: {header} ({path})")
    m = text.find("match value {", h)
    if m < 0:
        sys.exit(f"fix-ffmpeg-next-enum-drift: no match after {header} ({path})")
    i = m + len("match value {")
    depth = 1
    while depth:
        if i >= len(text):
            sys.exit(f"fix-ffmpeg-next-enum-drift: unbalanced match ({path})")
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    close = i - 1
    text = text[:close] + f"            _ => {fallback},\n        " + text[close:]
    open(path, "w").write(text)
    print(f"fix-ffmpeg-next-enum-drift: catch-all added to {rel}")


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: fix-ffmpeg-next-enum-drift.py <ffmpeg-next crate dir>")
    root = sys.argv[1]
    if not os.path.isdir(root):
        sys.exit(f"fix-ffmpeg-next-enum-drift: no such crate dir: {root}")
    for rel, header, fallback in FALLBACKS:
        patch_file(root, rel, header, fallback)


if __name__ == "__main__":
    main()
