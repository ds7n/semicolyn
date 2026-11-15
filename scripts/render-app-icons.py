# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# /// script
# requires-python = ">=3.11"
# dependencies = ["resvg-py", "pillow", "typer", "loguru"]
# ///
"""Render the alternate app icons and picker thumbnails from the flat vector mark.

The colour table below is the source of truth. Each variant recolours the two fills of
``assets/semicolon-mark.svg`` (chevron ``#FF6F5E``, comma ``#CFD6E4``) over a solid
background, flat with no glow. Writes into the asset catalog:

  AppIcon-<Name>.appiconset/      1024px opaque icon (every variant but MidnightDark,
                                  which is the primary AppIcon and is not regenerated)
  IconPreview-<Name>.imageset/    180px thumbnail for the in-app picker (all variants)

The names must match ``AppIconVariant.catalog`` in SemicolynKit. Run::

    uv run scripts/render-app-icons.py            # (re)write the assets
    uv run scripts/render-app-icons.py -c         # CI: fail if assets drift from the table
"""

from __future__ import annotations

import io
import json
import pathlib
import re
import sys

import resvg_py
import typer
from loguru import logger
from PIL import Image

app = typer.Typer(add_completion=False, help=__doc__)

_SRC_CHEVRON = "#FF6F5E"
_SRC_COMMA = "#CFD6E4"
_ICON_SIZE = 1024
_PREVIEW_SIZE = 180
_PRIMARY = "MidnightDark"

# name: (background, chevron, comma). Verbatim from the design spec.
VARIANTS: dict[str, tuple[str, str, str]] = {
    "MidnightDark": ("#12151F", "#FF6F5E", "#CFD6E4"),
    "MidnightLight": ("#F7F3EF", "#E8513F", "#1C2230"),
    "BronzeDark": ("#0E1116", "#D49A5C", "#E8EBF0"),
    "BronzeLight": ("#F6EFE4", "#B0743A", "#1F2530"),
    "CobaltDark": ("#050713", "#5A6EFF", "#C6CEF0"),
    "CobaltLight": ("#EEF0FF", "#3B4DE6", "#0E1438"),
    "GlacierDark": ("#151B29", "#7FA0F0", "#E4E9F2"),
    "GlacierLight": ("#E6EBF4", "#5876C8", "#27334F"),
}

_XCODE_INFO = {"author": "xcode", "version": 1}
_APPICON_CONTENTS = {
    "images": [
        {"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    ],
    "info": _XCODE_INFO,
}
_IMAGESET_CONTENTS = {
    "images": [{"filename": "icon.png", "idiom": "universal", "scale": "1x"}],
    "info": _XCODE_INFO,
}


def render_icon(svg: str, bg: str, chevron: str, comma: str) -> Image.Image:
    """Recolour both fills, rasterise at 1024 and flatten onto the opaque background."""
    svg = re.sub(re.escape(_SRC_CHEVRON), chevron, svg, flags=re.I)
    svg = re.sub(re.escape(_SRC_COMMA), comma, svg, flags=re.I)
    png = resvg_py.svg_to_bytes(svg_string=svg, width=_ICON_SIZE, height=_ICON_SIZE)
    glyph = Image.open(io.BytesIO(bytes(png))).convert("RGBA")
    base = Image.new("RGBA", glyph.size, bg)
    return Image.alpha_composite(base, glyph).convert("RGB")


def planned_outputs(svg: str) -> dict[pathlib.Path, Image.Image]:
    """Every PNG this script owns, keyed by path relative to the asset catalog."""
    out: dict[pathlib.Path, Image.Image] = {}
    for name, (bg, chevron, comma) in VARIANTS.items():
        icon = render_icon(svg, bg, chevron, comma)
        if name != _PRIMARY:
            out[pathlib.Path(f"AppIcon-{name}.appiconset/icon.png")] = icon
        preview = icon.resize((_PREVIEW_SIZE, _PREVIEW_SIZE), Image.LANCZOS)
        out[pathlib.Path(f"IconPreview-{name}.imageset/icon.png")] = preview
    return out


def _write_contents(directory: pathlib.Path) -> None:
    """Write the asset's Contents.json (appiconset or imageset by suffix)."""
    contents = _APPICON_CONTENTS if directory.suffix == ".appiconset" else _IMAGESET_CONTENTS
    (directory / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


def _differs(path: pathlib.Path, expected: Image.Image) -> bool:
    """Compare decoded pixels, not bytes, so zlib differences between hosts don't count."""
    if not path.exists():
        return True
    with Image.open(path) as committed:
        return committed.convert("RGB").tobytes() != expected.tobytes() or committed.size != expected.size


@app.command()
def main(
    svg_path: pathlib.Path = typer.Option(
        pathlib.Path("assets/semicolon-mark.svg"), "--svg", "-s", exists=True, readable=True,
        help="Flat vector master.",
    ),
    out: pathlib.Path = typer.Option(
        pathlib.Path("App/Assets.xcassets"), "--out", "-o", help="Asset catalog directory."
    ),
    check: bool = typer.Option(
        False, "--check", "-c", help="Verify committed assets match the table; write nothing."
    ),
) -> None:
    """Render (or, with --check, verify) the alternate icons and picker thumbnails."""
    outputs = planned_outputs(svg_path.read_text())
    if check:
        stale = [str(rel) for rel, img in outputs.items() if _differs(out / rel, img)]
        if stale:
            logger.error("icon assets differ from the render table: {}", ", ".join(stale))
            logger.error("rerun: uv run scripts/render-app-icons.py")
            sys.exit(1)
        logger.info("all {} icon assets match the render table", len(outputs))
        return
    for rel, img in outputs.items():
        dest = out / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest, optimize=True)
        _write_contents(dest.parent)
        logger.info("wrote {}", dest)


if __name__ == "__main__":
    app()
