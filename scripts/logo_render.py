# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
#
# /// script
# requires-python = ">=3.11"
# dependencies = ["resvg-py", "pillow", "typer", "loguru"]
# ///
"""Render the semicolyn semicolon mark from a flat vector master.

The pipeline keeps a single flat SVG as the source of truth and treats colour,
glow, and raster size as deterministic post-processing steps:

  flat SVG  --recolor-->  recoloured SVG  --resvg-->  crisp glyph (RGBA)
                                                          |
                                          optional uniform Gaussian glow
                                                          |
                                              composite over background
                                                          |
                                               downscale to each size -> PNG

Run it with uv (deps are declared inline, no venv needed)::

    uv run scripts/logo_render.py assets/semicolon-mark.svg -g
    uv run scripts/logo_render.py mark.svg -c '#D49A5C' -b '#0E1116' -g   # Bell Bronze
    uv run scripts/logo_render.py mark.svg --bg none --no-glow            # flat, transparent
"""

from __future__ import annotations

import io
import pathlib
import re

import resvg_py
import typer
from loguru import logger
from PIL import Image, ImageFilter

app = typer.Typer(add_completion=False, help=__doc__)

# Render the glyph large, do glow at this resolution, then downscale per size.
_HIRES = 2048

# Neon Midnight defaults (verbatim from the theme catalog).
_DEFAULT_MARK = "#FF6F5E"  # coral-red — what Recraft fills the glyph with
_DEFAULT_BG = "#07090E"  # midnight near-black


def _hex_to_rgb(value: str) -> tuple[int, int, int] | None:
    """Parse ``#RRGGBB`` (or ``none``) into an RGB triple.

    Returns None for ``none``/empty so callers can treat it as "transparent".
    """
    v = value.strip().lstrip("#").lower()
    if v in ("", "none", "transparent"):
        return None
    if len(v) != 6 or any(c not in "0123456789abcdef" for c in v):
        return None
    return (int(v[0:2], 16), int(v[2:4], 16), int(v[4:6], 16))


def _recolor(svg: str, src: tuple[int, int, int], dst: tuple[int, int, int]) -> str:
    """Replace every ``src`` fill (rgb() or hex form) in the SVG with ``dst``."""
    r, g, b = src
    rr, gg, bb = dst
    svg = re.sub(
        rf"rgb\(\s*{r}\s*,\s*{g}\s*,\s*{b}\s*\)", f"rgb({rr}, {gg}, {bb})", svg
    )
    svg = re.sub(
        rf"#{r:02x}{g:02x}{b:02x}", f"#{rr:02x}{gg:02x}{bb:02x}", svg, flags=re.I
    )
    return svg


def _drop_fill(svg: str, color: tuple[int, int, int]) -> str:
    """Make every path filled with ``color`` transparent (``fill="none"``).

    Used to strip a baked-in full-canvas background rect so the glyph renders on
    transparency — a prerequisite for building the glow from its alpha channel.
    """
    r, g, b = color
    svg = re.sub(rf'fill="rgb\(\s*{r}\s*,\s*{g}\s*,\s*{b}\s*\)"', 'fill="none"', svg)
    svg = re.sub(rf'fill="#{r:02x}{g:02x}{b:02x}"', 'fill="none"', svg, flags=re.I)
    return svg


def _render_svg(svg: str, size: int) -> Image.Image:
    """Rasterise an SVG string to an RGBA Pillow image at ``size`` square."""
    png = resvg_py.svg_to_bytes(svg_string=svg, width=size, height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def _build_glow(
    glyph: Image.Image, color: tuple[int, int, int], radius_px: float, strength: float
) -> Image.Image:
    """Build a uniform neon halo from the glyph's alpha channel.

    Two stacked Gaussian blurs (a tight bright core + a wide soft falloff) give a
    convincing even glow. Because it is a blur of the mark, the falloff is uniform
    by construction — no painterly blotches.
    """
    alpha = glyph.split()[3]
    canvas = Image.new("RGBA", glyph.size, (0, 0, 0, 0))
    for r_mul, s_mul in ((0.45, 1.0), (1.4, 0.55)):
        blurred = alpha.filter(ImageFilter.GaussianBlur(radius_px * r_mul))
        scale = strength * s_mul
        blurred = blurred.point(lambda a, _s=scale: int(min(255, a * _s)))
        layer = Image.new("RGBA", glyph.size, (*color, 0))
        layer.putalpha(blurred)
        canvas = Image.alpha_composite(canvas, layer)
    return canvas


@app.command()
def main(
    svg_path: pathlib.Path = typer.Argument(
        ..., exists=True, readable=True, help="Flat vector master (the semicolon)."
    ),
    out: pathlib.Path = typer.Option(
        pathlib.Path("mockups/drafts"), "--out", "-o", help="Output directory."
    ),
    color: str = typer.Option(
        _DEFAULT_MARK, "--color", "-c", help="Recolour the mark to this hex."
    ),
    src_color: str = typer.Option(
        _DEFAULT_MARK, "--src-color", help="Existing mark colour in the SVG."
    ),
    bg: str = typer.Option(
        _DEFAULT_BG, "--bg", "-b", help="Background hex, or 'none' for transparent."
    ),
    svg_bg: str = typer.Option(
        _DEFAULT_BG, "--svg-bg", help="Baked-in bg colour to strip ('none' to skip)."
    ),
    glow: bool = typer.Option(True, "--glow/--no-glow", "-g", help="Add a neon halo."),
    glow_color: str = typer.Option(
        "", "--glow-color", help="Halo hex (default: the mark colour)."
    ),
    glow_radius: float = typer.Option(
        0.05, "--glow-radius", help="Halo blur radius as a fraction of size."
    ),
    glow_strength: float = typer.Option(
        0.95, "--glow-strength", help="Halo intensity (0-1+)."
    ),
    sizes: str = typer.Option("1024,180,80", "--sizes", "-s", help="CSV of px sizes."),
    write_svg: bool = typer.Option(
        False, "--write-svg", help="Also write the recoloured flat SVG."
    ),
) -> None:
    """Render PNG icon assets (and optionally the recoloured SVG) from a master."""
    src_rgb = _hex_to_rgb(src_color)
    dst_rgb = _hex_to_rgb(color)
    if src_rgb is None or dst_rgb is None:
        raise typer.BadParameter("--color and --src-color must be #RRGGBB")
    bg_rgb = _hex_to_rgb(bg)
    glow_rgb = _hex_to_rgb(glow_color) or dst_rgb
    size_list = [int(s) for s in sizes.split(",") if s.strip()]
    if not size_list:
        raise typer.BadParameter("--sizes needs at least one value")

    svg = svg_path.read_text()
    if src_rgb != dst_rgb:
        svg = _recolor(svg, src_rgb, dst_rgb)
    svg_bg_rgb = _hex_to_rgb(svg_bg)
    if svg_bg_rgb is not None:
        svg = _drop_fill(svg, svg_bg_rgb)  # render glyph on transparency

    out.mkdir(parents=True, exist_ok=True)
    if write_svg:
        svg_out = out / f"{svg_path.stem}-{color.lstrip('#')}.svg"
        svg_out.write_text(svg)
        logger.info("wrote {}", svg_out)

    glyph = _render_svg(svg, _HIRES)
    composed = Image.new("RGBA", glyph.size, (*bg_rgb, 255) if bg_rgb else (0, 0, 0, 0))
    if glow:
        halo = _build_glow(glyph, glow_rgb, glow_radius * _HIRES, glow_strength)
        composed = Image.alpha_composite(composed, halo)
    composed = Image.alpha_composite(composed, glyph)

    tag = "glow" if glow else "flat"
    for size in size_list:
        img = composed.resize((size, size), Image.LANCZOS)
        if bg_rgb is not None:
            img = img.convert("RGB")  # opaque PNG for the App Store marketing icon
        dest = out / f"{svg_path.stem}-{color.lstrip('#')}-{tag}-{size}.png"
        img.save(dest)
        logger.info("wrote {} ({}px)", dest, size)


if __name__ == "__main__":
    app()
