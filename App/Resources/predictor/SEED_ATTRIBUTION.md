<!--
SPDX-FileCopyrightText: 2026 True Positive LLC
SPDX-License-Identifier: GPL-3.0-only
-->

# Predictor seed attribution

The bundled command-prediction seed (`seed_v1.sketch`) is a derived token-frequency
fingerprint built from two open corpora. It contains extracted CLI command tokens and
their frequencies, not verbatim source text; argument placeholders are removed.

## tldr-pages (https://github.com/tldr-pages/tldr): CC-BY-4.0
Licensed under the Creative Commons Attribution 4.0 International License
(https://creativecommons.org/licenses/by/4.0/). Changes were made: command-token
sequences were extracted from the example pages and reduced to frequency counts.

## Fig autocomplete (https://github.com/withfig/autocomplete): MIT
The MIT License. Copyright (c) 2021 Hercules Labs Inc. (Fig).
Permission is hereby granted, free of charge, to any person obtaining a copy of this
software and associated documentation files (the "Software"), to deal in the Software
without restriction [...] THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

## words/cuss (https://github.com/words/cuss): MIT
The MIT License. The profanity/slur blocklist (`profanity_blocklist.txt`) is derived
from the cuss word-sureness map: single-token entries rated sureness>=2, plus a
hand-curated identity-slur set (`blocklist_extra.txt`, our own) covering slurs cuss
under-rates at sureness 1. The blocklist keeps offensive tokens out of predictor
suggestions; it is a word list, not verbatim source.
