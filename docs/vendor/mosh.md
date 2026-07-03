<!-- SPDX-FileCopyrightText: 2026 True Positive LLC -->
<!-- SPDX-License-Identifier: GPL-3.0-only -->

# Vendored dependency: blinksh/mosh

## Source

- **Repository:** <https://github.com/blinksh/mosh>
- **Submodule path:** `extern/mosh`
- **Pinned commit:** `3640d36678dc415ba24f03d7f6fb20a0dac1fa6b`
- **Tracks branch:** `mosh+blink` (follow this branch for future bumps)
- **Tag at pin:** `mosh-1.4.0+blink-18.4.5` (mosh 1.4.0 / blink 18.4.5, dated 2026-03-14)

## License

Mosh upstream is **GPLv3+**; Blink's fork is **GPLv3**. Semicolyn is **GPL-3.0-only** — all compatible.

The vendored tree retains its **upstream copyright and license headers unchanged**. It is **NOT relicensed to True Positive LLC**. No first-party SPDX headers are added to any files under `extern/mosh`.

## App Store distribution

App Store distribution relies on the upstream **`COPYING.iOS`** App Store exception included in the blinksh/mosh repository. The semicolyn repo mirrors this precedent via the root **`LICENSE.IOS`** file.

## REUSE compliance note

This repo uses per-file SPDX headers only (no `.reuse/dep5`, no `REUSE.toml`, no `LICENSES/` directory, and REUSE is not enforced in CI). A git submodule's files are tracked only as a gitlink (commit pointer + `.gitmodules` entry) — upstream files are not tracked in our repository. Therefore upstream headers stand as-is and no first-party REUSE entries are required for the vendored tree.

## Files used by M1 build tasks

- `src/frontend/moshiosbridge.h` — iOS bridge header
- `src/frontend/moshiosbridge.cc` — iOS bridge implementation
- `src/frontend/mosh-ios-controller.cc` — iOS controller frontend
- `configure.ac` — autotools, exposes `--enable-ios-controller`

## How to bump the pin

```bash
cd extern/mosh
git fetch origin mosh+blink
git checkout <new-sha>
cd ../..
git add extern/mosh
git commit -m "vendor(mosh): bump blinksh/mosh to <new-sha>"
```

Then update **Pinned commit** and **Tag at pin** in this document.
