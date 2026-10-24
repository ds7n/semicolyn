// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// One credited project on the About > Acknowledgements screen.
public struct Acknowledgement: Equatable, Sendable {
    public let name: String
    /// What semicolyn uses it for.
    public let usedFor: String
    /// The SPDX licence expression, e.g. `CC-BY-SA-4.0`.
    public let spdx: String
    /// The licence as shown, e.g. "CC BY-SA 4.0".
    public let licenseName: String
    public let copyright: String
    public let url: String
    /// How the work was changed, for licences that require saying so (CC BY, CC BY-SA).
    public let changes: String?

    public init(name: String, usedFor: String, spdx: String, licenseName: String,
                copyright: String, url: String, changes: String? = nil) {
        self.name = name; self.usedFor = usedFor; self.spdx = spdx
        self.licenseName = licenseName; self.copyright = copyright; self.url = url
        self.changes = changes
    }
}

/// A headed group of acknowledgements.
public struct AcknowledgementGroup: Equatable, Sendable {
    public let header: String
    public let items: [Acknowledgement]
    public init(header: String, items: [Acknowledgement]) {
        self.header = header
        self.items = items
    }
}

/// The About screen: source link, licence and the credits for everything semicolyn
/// ships. Mirrors the repo's licence files (`App/Resources/predictor/SEED_ATTRIBUTION.md`,
/// the `.license` sidecars and the vendored libraries' own licences).
public enum About {
    public static let sourceCodeURL = "https://github.com/ds7n/semicolyn"
    public static let license = "GPL-3.0"

    /// "Version 0.1.0 (12)". A missing or blank build drops the parenthesis; a missing
    /// version reads "Unknown".
    public static func versionLabel(version: String?, build: String?) -> String {
        let v = version?.trimmingCharacters(in: .whitespaces) ?? ""
        let b = build?.trimmingCharacters(in: .whitespaces) ?? ""
        let shown = v.isEmpty ? "Unknown" : v
        return b.isEmpty ? "Version \(shown)" : "Version \(shown) (\(b))"
    }

    public static let acknowledgements: [AcknowledgementGroup] = [
        AcknowledgementGroup(header: "Terminal and Connections", items: [
            Acknowledgement(name: "SwiftTerm", usedFor: "Terminal emulator", spdx: "MIT",
                            licenseName: "MIT",
                            copyright: "Copyright (c) 2019-2022 Miguel de Icaza; the xterm.js authors; SourceLair Private Company; Christopher Jeffrey",
                            url: "https://github.com/migueldeicaza/SwiftTerm"),
            Acknowledgement(name: "Mosh", usedFor: "Mosh connections", spdx: "GPL-3.0-or-later",
                            licenseName: "GPL-3.0 or later, with the Mosh App Store notice",
                            copyright: "Copyright 2012 Keith Winstein and the Mosh contributors",
                            url: "https://mosh.org"),
            Acknowledgement(name: "Eternal Terminal", usedFor: "Eternal Terminal connections",
                            spdx: "Apache-2.0", licenseName: "Apache 2.0",
                            copyright: "Copyright Jason Gauci and the Eternal Terminal contributors",
                            url: "https://github.com/MisterTea/EternalTerminal"),
            Acknowledgement(name: "russh", usedFor: "SSH protocol", spdx: "Apache-2.0",
                            licenseName: "Apache 2.0",
                            copyright: "Copyright Pierre-Étienne Meunier and the russh contributors",
                            url: "https://github.com/Eugeny/russh"),
            Acknowledgement(name: "ssh-key", usedFor: "SSH key generation and parsing",
                            spdx: "Apache-2.0 OR MIT", licenseName: "Apache 2.0 or MIT",
                            copyright: "Copyright the RustCrypto developers",
                            url: "https://github.com/RustCrypto/SSH"),
            Acknowledgement(name: "AWS-LC", usedFor: "Cryptography", spdx: "ISC AND Apache-2.0",
                            licenseName: "ISC and Apache 2.0",
                            copyright: "Copyright Amazon.com, Inc. or its affiliates",
                            url: "https://github.com/aws/aws-lc-rs"),
            Acknowledgement(name: "Tokio", usedFor: "Async runtime", spdx: "MIT",
                            licenseName: "MIT", copyright: "Copyright (c) Tokio Contributors",
                            url: "https://tokio.rs"),
            Acknowledgement(name: "UniFFI", usedFor: "Rust and Swift bridge", spdx: "MPL-2.0",
                            licenseName: "MPL 2.0", copyright: "Copyright Mozilla Foundation",
                            url: "https://github.com/mozilla/uniffi-rs"),
            Acknowledgement(name: "Protocol Buffers", usedFor: "Mosh and Eternal Terminal messages",
                            spdx: "BSD-3-Clause", licenseName: "BSD 3-Clause",
                            copyright: "Copyright 2008 Google Inc.",
                            url: "https://github.com/protocolbuffers/protobuf"),
            Acknowledgement(name: "ncurses", usedFor: "Terminal capabilities for Mosh", spdx: "X11",
                            licenseName: "MIT (X11 style)",
                            copyright: "Copyright 2018-2024 Thomas E. Dickey; Copyright 1998-2017 Free Software Foundation, Inc.",
                            url: "https://invisible-island.net/ncurses/"),
            Acknowledgement(name: "libsodium and swift-sodium", usedFor: "Eternal Terminal encryption",
                            spdx: "ISC", licenseName: "ISC",
                            copyright: "Copyright (c) Frank Denis",
                            url: "https://github.com/jedisct1/swift-sodium"),
        ]),
        AcknowledgementGroup(header: "Fonts", items: [
            Acknowledgement(name: "Nerd Fonts", usedFor: "Icon glyphs in the bundled fonts", spdx: "MIT",
                            licenseName: "MIT",
                            copyright: "Copyright (c) Ryan L. McIntyre and contributors",
                            url: "https://github.com/ryanoasis/nerd-fonts"),
            Acknowledgement(name: "Hack", usedFor: "Default terminal font", spdx: "MIT",
                            licenseName: "MIT, with the Bitstream Vera License",
                            copyright: "Copyright 2018 Source Foundry Authors; Bitstream Vera; DejaVu (public domain)",
                            url: "https://github.com/source-foundry/Hack"),
            Acknowledgement(name: "JetBrains Mono", usedFor: "Terminal font", spdx: "OFL-1.1",
                            licenseName: "SIL Open Font License 1.1",
                            copyright: "Copyright 2020 The JetBrains Mono Project Authors",
                            url: "https://github.com/JetBrains/JetBrainsMono"),
        ]),
        AcknowledgementGroup(header: "Word Suggestions", items: [
            Acknowledgement(name: "Google Books Ngram Viewer", usedFor: "English word scores",
                            spdx: "CC-BY-3.0", licenseName: "CC BY 3.0", copyright: "Google LLC",
                            url: "https://books.google.com/ngrams",
                            changes: "1-gram and 2-gram counts from 1990 onward were filtered and reduced to 1-byte scores."),
            Acknowledgement(name: "wordfreq", usedFor: "English word scores",
                            spdx: "CC-BY-SA-4.0", licenseName: "CC BY-SA 4.0",
                            copyright: "Robyn Speer and contributors",
                            url: "https://github.com/rspeer/wordfreq",
                            changes: "Word frequencies (version 3.1.1 data) were blended into the English scores, so the English dictionary is shared under CC BY-SA 4.0."),
            Acknowledgement(name: "Wikipedia page titles", usedFor: "Capitalizing proper nouns",
                            spdx: "CC-BY-SA-4.0", licenseName: "CC BY-SA 4.0",
                            copyright: "Wikipedia contributors",
                            url: "https://dumps.wikimedia.org/enwiki/",
                            changes: "Titles were used only to decide the capitalised form of proper nouns."),
            Acknowledgement(name: "SCOWL", usedFor: "Confirming dictionary words",
                            spdx: "LicenseRef-SCOWL", licenseName: "SCOWL copyright notice",
                            copyright: "Copyright 2000-2018 Kevin Atkinson and contributors",
                            url: "http://wordlist.aspell.net/"),
            Acknowledgement(name: "tldr-pages", usedFor: "Command suggestion ranking",
                            spdx: "CC-BY-4.0", licenseName: "CC BY 4.0",
                            copyright: "tldr-pages contributors",
                            url: "https://github.com/tldr-pages/tldr",
                            changes: "Command, subcommand and flag usage was extracted from the example pages and reduced to frequency scores."),
            Acknowledgement(name: "Fig autocomplete", usedFor: "Command, subcommand and flag names",
                            spdx: "MIT", licenseName: "MIT",
                            copyright: "Copyright (c) 2021 Hercules Labs Inc. (Fig)",
                            url: "https://github.com/withfig/autocomplete"),
            Acknowledgement(name: "words/cuss", usedFor: "Keeping offensive words out of suggestions",
                            spdx: "MIT", licenseName: "MIT",
                            copyright: "Copyright (c) Titus Wormer",
                            url: "https://github.com/words/cuss"),
        ]),
    ]
}
