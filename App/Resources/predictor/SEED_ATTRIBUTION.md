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

# Predictor dictionaries (v2)

`english_v2.bin` (GDIC) holds derived English word and word-pair frequency scores.
`commands_v2.bin` (GCMT) holds a derived command, subcommand and flag tree with scores.
Neither contains verbatim source text. Build details and source hashes are in
`english_v2.provenance.txt` and `commands_v2.provenance.txt`.

## Google Books Ngram Viewer data (Google LLC): CC-BY-3.0
https://storage.googleapis.com/books/ngrams/books/20200217/eng/ ("Google Books Ngram
Viewer", http://books.google.com/ngrams). Licensed under the Creative Commons Attribution
3.0 Unported License (https://creativecommons.org/licenses/by/3.0/). Changes were made:
1-gram and 2-gram counts from 1990 onward were filtered and reduced to 1-byte scores.

## wordfreq (Robyn Speer and contributors): CC-BY-SA-4.0
https://github.com/rspeer/wordfreq, version 3.1.1 data. Licensed under the Creative
Commons Attribution-ShareAlike 4.0 International License
(https://creativecommons.org/licenses/by-sa/4.0/). Changes were made: word frequencies
were blended into the English scores. Because of this, `english_v2.bin` is distributed
under CC-BY-SA-4.0.

## Wikipedia page titles (Wikipedia contributors): CC-BY-SA-4.0
https://dumps.wikimedia.org/enwiki/20261001/ (all-titles-in-ns0). Licensed under the
Creative Commons Attribution-ShareAlike 4.0 International License. Changes were made:
titles were used only to decide the capitalised form of proper nouns.

## SCOWL (Kevin Atkinson and contributors): SCOWL copyright notice
http://wordlist.aspell.net/, SCOWL 2020.12.07. Used to confirm dictionary words. The full
copyright and permission notice, including the notices of the lists SCOWL is built from,
ships verbatim as `SCOWL_COPYRIGHT.txt`.

## tldr-pages and Fig autocomplete
`commands_v2.bin` takes its structure from Fig autocomplete specs (MIT, notice above and
in `commands_v2.bin.license`) and its ranking from tldr-pages examples (CC-BY-4.0, above).
Changes were made: reduced to command, subcommand and flag frequency scores.
