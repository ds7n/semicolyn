# SPDX-FileCopyrightText: 2026 True Positive LLC
# SPDX-License-Identifier: GPL-3.0-only
"""Export a wordfreq cBpack (e.g. large_en.msgpack.gz) as word<TAB>frequency lines.

A cBpack is a msgpack list: element 0 is a header ({"format": "cB", "version": 1}),
and element 1 + j lists the words whose frequency is 10 ** (-j / 100) (j centibels
below 1), the same reading as wordfreq.read_cBpack / get_frequency_dict. Run with
`python3 -I` from a venv that has msgpack installed.
"""

import argparse
import gzip
import sys

import msgpack


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("-i", "--input", required=True, help="cBpack file (.msgpack.gz)")
    parser.add_argument("-o", "--output", required=True, help="output TSV path")
    return parser.parse_args()


def _read_cbpack(path: str) -> list:
    """Decode the cBpack and validate its header; returns the frequency buckets."""
    with gzip.open(path, "rb") as handle:
        data = msgpack.load(handle, raw=False)
    if not isinstance(data, list) or not data:
        raise ValueError(f"{path}: not a cBpack list")
    header = data[0]
    if not isinstance(header, dict) or header.get("format") != "cB" or header.get("version") != 1:
        raise ValueError(f"{path}: unexpected cBpack header {header!r}")
    return data[1:]


def main() -> int:
    """Write every word with its frequency; prints a one-line count summary to stderr."""
    args = _parse_args()
    buckets = _read_cbpack(args.input)
    written = 0
    skipped = 0
    with open(args.output, "w", encoding="utf-8", newline="\n") as out:
        for index, bucket in enumerate(buckets):
            freq = 10 ** (-index / 100)
            for word in bucket:
                if not isinstance(word, str) or not word or "\t" in word or "\n" in word or "\r" in word:
                    skipped += 1
                    continue
                out.write(f"{word}\t{freq:.6e}\n")
                written += 1
    print(f"wordfreq export: buckets {len(buckets)}, words {written}, skipped {skipped}", file=sys.stderr)
    return 0 if written > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
