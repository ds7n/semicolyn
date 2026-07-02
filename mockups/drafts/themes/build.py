# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
"""Theme build pipeline for the semicolyn gallery.

Source of truth = a standard palette per theme (iTerm2 ``.itermcolors`` or base16
YAML) + a thin ``index.json`` of metadata (accent slot, warning slot, chrome
overrides, blurb). This script parses the palette, DERIVES the app-chrome fields
(surfaces / text ramp / accent / highlight) with the calibrated rules, honours any
per-theme overrides, and emits the gallery config JS.

    uv run python build.py --init     # one-time: write .itermcolors + index.json from embedded data
    uv run python build.py            # normal: palettes + index.json -> gallery config

The same ``parse_itermcolors`` / ``parse_base16`` + ``derive_ui`` path is what
Piece 3 (theme import) and the eventual Swift codegen will reuse.
"""

from __future__ import annotations

import argparse
import colorsys
import json
import pathlib
import plistlib

THEMES_DIR = pathlib.Path(__file__).parent
INDEX_PATH = THEMES_DIR / "index.json"
CONFIG_OUT = THEMES_DIR.parent / "2026-07-01-theme-gallery.config.js"

# The 13 UI keys the gallery renderer consumes, and the ANSI slot names.
_UI_KEYS = ["accent", "highlight", "success", "warning", "broken", "bg", "panel",
            "panelHi", "line", "term", "text", "termfg", "muted"]


# --------------------------------------------------------------------------- #
# color helpers (standard HSL, hex <-> 0..1 rgb)                               #
# --------------------------------------------------------------------------- #
def _hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    """Return the 0-255 RGB tuple for a ``#rrggbb`` string."""
    h = hex_color.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))  # type: ignore[return-value]


def _rgb_to_hex(rgb: tuple[float, float, float]) -> str:
    """Return an upper-case ``#RRGGBB`` string, clamping each channel to 0-255."""
    return "#" + "".join(f"{max(0, min(255, round(c))):02X}" for c in rgb)


def _to_hsl(hex_color: str) -> tuple[float, float, float]:
    """Return ``(hue_deg, sat_pct, light_pct)`` for a hex color."""
    r, g, b = (c / 255 for c in _hex_to_rgb(hex_color))
    hue, light, sat = colorsys.rgb_to_hls(r, g, b)
    return hue * 360, sat * 100, light * 100


def _from_hsl(hue: float, sat: float, light: float) -> str:
    """Inverse of :func:`_to_hsl`; clamps S/L into range."""
    r, g, b = colorsys.hls_to_rgb((hue % 360) / 360,
                                  max(0.0, min(100.0, light)) / 100,
                                  max(0.0, min(100.0, sat)) / 100)
    return _rgb_to_hex((r * 255, g * 255, b * 255))


def _adjust_l(hex_color: str, d_light: float, d_sat: float = 0.0) -> str:
    """Shift a color's lightness (and optionally saturation), preserving hue."""
    hue, sat, light = _to_hsl(hex_color)
    return _from_hsl(hue, sat + d_sat, light + d_light)


def _lighten(hex_color: str, d_light: float, sat_mul: float = 1.0) -> str:
    """Lighten a color and scale its saturation (used for highlight)."""
    hue, sat, light = _to_hsl(hex_color)
    return _from_hsl(hue, sat * sat_mul, light + d_light)


def _mix(a: str, b: str, t: float) -> str:
    """Linear RGB blend: ``t`` of ``b`` into ``a``."""
    ra, rb = _hex_to_rgb(a), _hex_to_rgb(b)
    return _rgb_to_hex(tuple(ra[i] * (1 - t) + rb[i] * t for i in range(3)))


# --------------------------------------------------------------------------- #
# palette IO — iTerm2 .itermcolors and base16 YAML                            #
# --------------------------------------------------------------------------- #
def _iterm_component(hex_color: str) -> dict[str, object]:
    """Return an iTerm2 sRGB color dict (0..1 float components) for a hex color."""
    r, g, b = (c / 255 for c in _hex_to_rgb(hex_color))
    return {"Color Space": "sRGB", "Red Component": r,
            "Green Component": g, "Blue Component": b, "Alpha Component": 1.0}


def _component_to_hex(comp: dict[str, object]) -> str:
    """Inverse of :func:`_iterm_component`."""
    return _rgb_to_hex((float(comp["Red Component"]) * 255,   # type: ignore[arg-type]
                        float(comp["Green Component"]) * 255,
                        float(comp["Blue Component"]) * 255))


def write_itermcolors(path: pathlib.Path, palette: dict) -> None:
    """Write a palette dict (``ansi`` list + ``bg``/``fg``/``cursor``/…) to ``.itermcolors``."""
    doc: dict[str, object] = {}
    for i, color in enumerate(palette["ansi"]):
        doc[f"Ansi {i} Color"] = _iterm_component(color)
    doc["Background Color"] = _iterm_component(palette["bg"])
    doc["Foreground Color"] = _iterm_component(palette["fg"])
    if palette.get("cursor"):
        doc["Cursor Color"] = _iterm_component(palette["cursor"])
        doc["Cursor Text Color"] = _iterm_component(palette.get("cursorText", palette["bg"]))
    with path.open("wb") as fh:
        plistlib.dump(doc, fh)


def parse_itermcolors(path: pathlib.Path) -> dict:
    """Parse an ``.itermcolors`` file into ``{ansi:[16], bg, fg, cursor?, ...}``.

    Returns None-free keys only; missing optional colors (cursor/selection) are
    simply absent so the caller can derive them.
    """
    with path.open("rb") as fh:
        doc = plistlib.load(fh)
    ansi = [_component_to_hex(doc[f"Ansi {i} Color"]) for i in range(16)]
    out = {"ansi": ansi,
           "bg": _component_to_hex(doc["Background Color"]),
           "fg": _component_to_hex(doc["Foreground Color"])}
    for key, dst in (("Cursor Color", "cursor"), ("Cursor Text Color", "cursorText"),
                     ("Selection Color", "selection")):
        if key in doc:
            out[dst] = _component_to_hex(doc[key])
    return out


# base16 base0X -> ANSI slot index (standard base16 shell mapping; brights = normals).
_BASE16_ANSI = {0: "base00", 1: "base08", 2: "base0B", 3: "base0A", 4: "base0D",
                5: "base0E", 6: "base0C", 7: "base05", 8: "base03", 9: "base08",
                10: "base0B", 11: "base0A", 12: "base0D", 13: "base0E",
                14: "base0C", 15: "base07"}


def parse_base16(path: pathlib.Path) -> dict:
    """Parse a flat base16 YAML scheme into the same palette dict shape.

    Handles the common flat ``base00: "1d1f21"`` form (with or without ``#``);
    base16's 8 ANSI + greyscale expand to 16 via the standard mapping (brights
    reuse the normal hues).
    """
    values: dict[str, str] = {}
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line.startswith("base"):
            continue
        key, _, val = line.partition(":")
        val = val.strip().strip('"').strip("'").lstrip("#")
        if len(val) == 6:
            values[key.strip()] = "#" + val
    ansi = [values[_BASE16_ANSI[i]] for i in range(16)]
    return {"ansi": ansi, "bg": values["base00"], "fg": values["base05"]}


# --------------------------------------------------------------------------- #
# derivation — palette + meta -> the 13 UI fields                             #
# --------------------------------------------------------------------------- #
def derive_ui(palette: dict, meta: dict) -> dict[str, str]:
    """Derive the full UI palette from a raw palette + theme metadata.

    Rules (calibrated so our own themes round-trip):
      surfaces  = bg tint-steps  (ground +2 / panel +5 / panelHi +11 / line +18 L, +2 S)
      termfg    = palette fg;  text = lighten(termfg,+8);  muted = mix(text->bg,.42)
      status    = red/green slots (1/2) + warning slot (meta.warningSlot, default 3)
      accent    = meta.accent override else ansi[meta.accentSlot]
      highlight = meta.highlight override else lighten(accent,+14,x.82)
    Any key present in ``meta['overrides']`` wins over the derived value.
    """
    ansi, bg, fg = palette["ansi"], palette["bg"], palette["fg"]
    accent = meta.get("accent") or ansi[meta["accentSlot"]]
    text = _lighten(fg, 8)
    derived = {
        "term": bg,
        "termfg": fg,
        "text": text,
        "muted": _mix(text, bg, 0.42),
        "bg": _adjust_l(bg, 2, 2),
        "panel": _adjust_l(bg, 5, 2),
        "panelHi": _adjust_l(bg, 11, 2),
        "line": _adjust_l(bg, 18, 2),
        "accent": accent,
        "highlight": meta.get("highlight") or _lighten(accent, 14, 0.82),
        "success": ansi[2],
        "broken": ansi[1],
        "warning": ansi[meta.get("warningSlot", 3)],
    }
    derived.update(meta.get("overrides", {}))
    return derived


def _sem_harm(meta: dict) -> tuple[dict, dict]:
    """Return the gallery ``sem`` (status pins) and ``harm`` (accent slot) maps."""
    sem = {1: "failure", 2: "success", meta.get("warningSlot", 3): "warning"}
    harm = {} if meta.get("accent") else {meta["accentSlot"]: "accent"}
    return sem, harm


# --------------------------------------------------------------------------- #
# emit the gallery config JS                                                   #
# --------------------------------------------------------------------------- #
def emit_config(themes: list[dict]) -> str:
    """Render the ``GALLERY_THEMES`` config JS from built theme dicts."""
    header = ("// SPDX-FileCopyrightText: 2026 True Positive LLC\n"
              "// SPDX-License-Identifier: GPL-3.0-only\n"
              "//\n// GENERATED by themes/build.py — do not edit by hand.\n"
              "// Edit themes/*.itermcolors + themes/index.json, then rerun build.py.\n\n"
              "const GALLERY_THEMES = [\n")
    blocks = []
    for t in themes:
        flag = "ref:true" if t.get("ref") else f"pro:{str(t['pro']).lower()}"
        ui = ", ".join(f'{k}:"{t["ui"][k]}"' for k in _UI_KEYS)
        ansi = ",".join(f'"{c}"' for c in t["ansi"])
        sem = json.dumps({str(k): v for k, v in t["sem"].items()})
        harm = json.dumps({str(k): v for k, v in t["harm"].items()})
        blocks.append(
            f'  {{ name:"{t["name"]}", {flag}, status:{json.dumps(t["status"])},\n'
            f'    recipe:{json.dumps(t["recipe"])},\n'
            f"    ui:{{ {ui} }},\n"
            f"    ansi:[{ansi}],\n"
            f"    sem:{sem}, harm:{harm} }},")
    footer = ("\n];\n\nif (typeof window !== \"undefined\") "
              "window.GALLERY_THEMES = GALLERY_THEMES;\n")
    return header + "\n".join(blocks) + footer


# ANSISlot enum case names, indexed by palette slot (matches Sources/.../ANSIPalette.swift).
_SLOT_SWIFT = [".black", ".red", ".green", ".yellow", ".blue", ".magenta", ".cyan", ".white",
               ".brightBlack", ".brightRed", ".brightGreen", ".brightYellow",
               ".brightBlue", ".brightMagenta", ".brightCyan", ".brightWhite"]


def emit_swift(meta: dict, palette: dict, ui: dict) -> str:
    """Render a Swift ``Theme`` extension via ``Theme.fromANSI`` for one theme.

    Surfaces/text/highlight are the DERIVED values baked in as literals, so the Swift
    side needs no derivation logic — it matches the hand-authored sibling files
    (NeonMidnightTheme.swift / BellBronzeTheme.swift) exactly in shape.
    """
    var = meta["id"]
    accent_slot = _SLOT_SWIFT[meta["accentSlot"]]
    warn_slot = _SLOT_SWIFT[meta.get("warningSlot", 3)]
    cursor = palette.get("cursor", ui["accent"])
    cursor_text = palette.get("cursorText", ui["term"])
    ansi_lines = "\n        ".join(
        ", ".join(f'ThemeColor("{c}")' for c in palette["ansi"][i:i + 4]) + ","
        for i in range(0, 16, 4))
    return f'''// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only

// GENERATED from themes/{meta["file"]} by themes/build.py — chrome derived from the
// palette (surfaces/text/highlight), status + accent pinned to ANSI slots. Regenerate
// with `uv run python build.py --swift`; safe to keep in the tree once reviewed.

private let {var}ANSI = ANSIPalette([
        {ansi_lines}
])

extension Theme {{
    public static let {var} = Theme.fromANSI(
        ansi: {var}ANSI,
        roles: ANSIRoleMap(accentPrimary: {accent_slot}, success: .green,
                           degraded: {warn_slot}, broken: .red, warning: {warn_slot}),
        highlight: ThemeColor("{ui["highlight"]}"),
        surface: .init(bg: ThemeColor("{ui["bg"]}"), panel: ThemeColor("{ui["panel"]}"),
                       panelHigh: ThemeColor("{ui["panelHi"]}"), line: ThemeColor("{ui["line"]}")),
        text: .init(primary: ThemeColor("{ui["text"]}"), secondary: ThemeColor("{ui["muted"]}"),
                    muted: ThemeColor("{ui["muted"]}"), inverse: ThemeColor("{ui["term"]}")),
        terminal: .init(bg: ThemeColor("{ui["term"]}"), fg: ThemeColor("{ui["termfg"]}"),
                        cursor: ThemeColor("{cursor}"), cursorText: ThemeColor("{cursor_text}"),
                        selection: ThemeColor("{ui["accent"]}").alpha(0.30))
    )
}}
'''


def build_swift() -> None:
    """Generate Swift theme files for our (non-reference) themes into ``generated/``."""
    index = json.loads(INDEX_PATH.read_text())
    out_dir = THEMES_DIR / "generated"
    out_dir.mkdir(exist_ok=True)
    count = 0
    for meta in index["themes"]:
        if meta.get("ref"):
            continue
        path = THEMES_DIR / meta["file"]
        palette = parse_base16(path) if path.suffix in (".yaml", ".yml") else parse_itermcolors(path)
        ui = derive_ui(palette, meta)
        swift_name = "".join(w.capitalize() for w in meta["id"].replace("neon", "Neon").split())
        fname = meta["id"][0].upper() + meta["id"][1:] + "Theme.swift"
        (out_dir / fname).write_text(emit_swift(meta, palette, ui))
        count += 1
    print(f"wrote {count} Swift theme files -> generated/")


def build() -> None:
    """Read index.json + palettes, derive, and write the gallery config."""
    index = json.loads(INDEX_PATH.read_text())
    themes = []
    for meta in index["themes"]:
        path = THEMES_DIR / meta["file"]
        palette = parse_base16(path) if path.suffix in (".yaml", ".yml") else parse_itermcolors(path)
        ui = derive_ui(palette, meta)
        sem, harm = _sem_harm(meta)
        themes.append({"name": meta["name"], "pro": meta.get("pro", False),
                       "ref": meta.get("ref", False), "status": meta["status"],
                       "recipe": meta["recipe"], "ui": ui, "ansi": palette["ansi"],
                       "sem": sem, "harm": harm})
    CONFIG_OUT.write_text(emit_config(themes))
    print(f"wrote {CONFIG_OUT.name} — {len(themes)} themes")


# --------------------------------------------------------------------------- #
# --init bootstrap: write .itermcolors + index.json from embedded sources      #
# --------------------------------------------------------------------------- #
def init() -> None:
    """One-time: materialize the ``.itermcolors`` palettes and ``index.json``."""
    index_themes = []
    for src in _SOURCES:
        write_itermcolors(THEMES_DIR / src["file"], src["palette"])
        meta = {k: v for k, v in src.items() if k != "palette"}
        index_themes.append(meta)
    INDEX_PATH.write_text(json.dumps({"themes": index_themes}, indent=2) + "\n")
    print(f"wrote {len(_SOURCES)} .itermcolors + index.json")


# Embedded source palettes + metadata (only used by --init to bootstrap the files).
_SOURCES = [
    {"id": "neonMidnight", "name": "Neon Midnight", "file": "neon-midnight.itermcolors",
     "pro": False, "accentSlot": 9, "warningSlot": 3,
     "status": "shipped · default · warm-vivid",
     "recipe": "the <b>warm-vivid</b> one. neo → <b>neon</b> (neon gas glows orange-red) on a midnight blue-near-black night — coral accent, saturated warm palette. Chrome derived.",
     "palette": {"bg": "#05070B", "fg": "#CFD6E4", "cursor": "#FF6F5E", "cursorText": "#05070B",
                 "ansi": ["#0B0E14", "#E5455E", "#5FB0A2", "#F5A524", "#5B8CFF", "#B98CFF", "#4FC7D6", "#C9D1E0",
                          "#2A3346", "#FF6F5E", "#7CE0C4", "#FFC860", "#8AA6FF", "#D0B0FF", "#86ECF7", "#F2F5FA"]}},
    {"id": "bellBronze", "name": "Bell Bronze", "file": "bell-bronze.itermcolors",
     "pro": True, "accentSlot": 3, "warningSlot": 11,
     "status": "shipped · Pro · warm-muted · hand-tuned",
     "recipe": "the <b>warm-muted</b> one. earthy bronze on a <b>warm charcoal</b> base — the one theme whose chrome stays <b>hand-authored</b> (overrides), not derived.",
     "overrides": {"bg": "#17130D", "panel": "#1F1A12", "panelHi": "#29231A", "line": "#3A3225",
                   "text": "#ECE4D5", "muted": "#9E9382", "highlight": "#F2C58A"},
     "palette": {"bg": "#120F09", "fg": "#D8CFBE", "cursor": "#D49A5C", "cursorText": "#120F09",
                 "ansi": ["#1A150E", "#E06B6B", "#5FA89C", "#D49A5C", "#5E86C7", "#A98BC7", "#5FA8B5", "#D8CFBE",
                          "#3A3324", "#F08A8A", "#7FC4B7", "#F5A524", "#8AAAE0", "#C8ADE0", "#8FCDD9", "#F2ECDE"]}},
    {"id": "neonCobalt", "name": "Neon Cobalt", "file": "neon-cobalt.itermcolors",
     "pro": True, "accentSlot": 4, "warningSlot": 3,
     "status": "NEW · electric",
     "recipe": "the <b>loud</b> one. <b>max-saturation electric</b> cobalt on a deep near-black navy, high contrast. Its whole 16-color palette runs hot — so even terminal output reads unmistakably Cobalt. Chrome derived.",
     "palette": {"bg": "#03040B", "fg": "#C6CEF0", "cursor": "#5A6EFF", "cursorText": "#03040B",
                 "ansi": ["#0A0C1A", "#FD4E66", "#4EFDAC", "#FDCF4E", "#5A6EFF", "#E64EFD", "#4EECFD", "#C6CEF0",
                          "#29305A", "#F7929F", "#92F7C8", "#F7DC92", "#A3B0FF", "#E992F7", "#92EDF7", "#F0F3FF"]}},
    {"id": "glacier", "name": "Glacier", "file": "glacier.itermcolors",
     "pro": True, "accentSlot": 4, "warningSlot": 3,
     "status": "NEW · soft · name TBD",
     "recipe": "the <b>calm</b> one. <b>soft desaturated pastel</b> (Nord/Catppuccin family) on a distinctly <b>lighter slate</b> base — low contrast, powder-blue accent. Reads completely differently from Cobalt though both are blue. Chrome derived.",
     "palette": {"bg": "#151B29", "fg": "#B8BFCE", "cursor": "#8AA6E8", "cursorText": "#151B29",
                 "ansi": ["#202636", "#DD9DA1", "#9DDDB8", "#DDCC9D", "#8AA6E8", "#CC9DDD", "#9DD4DD", "#B8BFCE",
                          "#414B68", "#E7C5C7", "#C5E7D4", "#E7DEC5", "#C0CDEC", "#DEC5E7", "#C5E3E7", "#E4E9F2"]}},

    # ---- popular reference themes (real palettes) — imported to prove the pipeline ----
    {"id": "dracula", "name": "Dracula", "file": "dracula.itermcolors", "ref": True,
     "accentSlot": 4, "highlight": "#FF79C6", "warningSlot": 3, "status": "reference · imported",
     "recipe": "imported .itermcolors → chrome derived. Vivid pink/purple/cyan/green; still pins green=success · red=failure · yellow=warning.",
     "palette": {"bg": "#282A36", "fg": "#F8F8F2",
                 "ansi": ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
                          "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]}},
    {"id": "nord", "name": "Nord", "file": "nord.itermcolors", "ref": True,
     "accentSlot": 6, "warningSlot": 3, "status": "reference · imported",
     "recipe": "imported .itermcolors → chrome derived. Arctic, desaturated, low-contrast — the canonical calm palette; Glacier's family.",
     "palette": {"bg": "#2E3440", "fg": "#D8DEE9",
                 "ansi": ["#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
                          "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4"]}},
    {"id": "gruvboxDark", "name": "Gruvbox Dark", "file": "gruvbox-dark.itermcolors", "ref": True,
     "accentSlot": 11, "highlight": "#FE8019", "warningSlot": 3, "status": "reference · imported",
     "recipe": "imported .itermcolors → chrome derived. Warm retro earthy — the template Bronze reaches for.",
     "palette": {"bg": "#282828", "fg": "#EBDBB2",
                 "ansi": ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
                          "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]}},
    {"id": "catppuccinMocha", "name": "Catppuccin Mocha", "file": "catppuccin-mocha.itermcolors", "ref": True,
     "accent": "#CBA6F7", "highlight": "#F5C2E7", "warningSlot": 3, "status": "reference · imported",
     "recipe": "imported .itermcolors → chrome derived. Soft modern pastel; mauve accent isn't a palette slot, so it's an explicit accent override.",
     "palette": {"bg": "#1E1E2E", "fg": "#CDD6F4",
                 "ansi": ["#45475A", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#BAC2DE",
                          "#585B70", "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#A6ADC8"]}},
]


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="semicolyn theme build pipeline")
    parser.add_argument("--init", action="store_true",
                        help="bootstrap .itermcolors + index.json from embedded sources")
    parser.add_argument("--swift", action="store_true",
                        help="also emit Swift theme files into generated/")
    args = parser.parse_args()
    if args.init:
        init()
    build()
    if args.swift:
        build_swift()


if __name__ == "__main__":
    main()
