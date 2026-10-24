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
                            copyright: "Copyright (c) 2019-2026 Miguel de Icaza; Copyright (c) 2017-2019 The xterm.js authors; Copyright (c) 2014-2016 SourceLair Private Company; Copyright (c) 2012-2013 Christopher Jeffrey",
                            url: "https://github.com/migueldeicaza/SwiftTerm"),
            Acknowledgement(name: "Mosh", usedFor: "Mosh connections",
                            spdx: "GPL-3.0-or-later AND ISC",
                            licenseName: "GPL-3.0 or later, with the Mosh App Store notice; OCB code under ISC",
                            copyright: "Copyright 2012 Keith Winstein and the Mosh authors; OCB code Copyright (c) 2012 Ted Krovetz, Copyright 2022 Google LLC",
                            url: "https://mosh.org"),
            Acknowledgement(name: "Eternal Terminal", usedFor: "Eternal Terminal connections",
                            spdx: "Apache-2.0", licenseName: "Apache 2.0",
                            copyright: "Copyright the Eternal Terminal authors (lead author Jason Gauci)",
                            url: "https://github.com/MisterTea/EternalTerminal"),
            Acknowledgement(name: "Easylogging++", usedFor: "Eternal Terminal logging", spdx: "MIT",
                            licenseName: "MIT",
                            copyright: "Copyright (c) 2012-2018 Amrayn Web Services; Copyright (c) 2012-2018 @abumusamq",
                            url: "https://github.com/amrayn/easyloggingpp"),
            Acknowledgement(name: "PlatformFolders", usedFor: "Eternal Terminal file locations", spdx: "MIT",
                            licenseName: "MIT", copyright: "Copyright (c) 2015 Poul Sander",
                            url: "https://github.com/sago007/PlatformFolders"),
            Acknowledgement(name: "UniversalStacktrace", usedFor: "Eternal Terminal error reports",
                            spdx: "Apache-2.0", licenseName: "Apache 2.0",
                            copyright: "Copyright Jason Gauci",
                            url: "https://github.com/MisterTea/UniversalStacktrace"),
            Acknowledgement(name: "base64 (C++)", usedFor: "Eternal Terminal key exchange encoding",
                            spdx: "MIT", licenseName: "MIT",
                            copyright: "Copyright (C) 2013 Tomas Kislan; Copyright (C) 2013 Adam Rudd",
                            url: "https://github.com/tkislan/base64"),
            Acknowledgement(name: "ThreadPool", usedFor: "Eternal Terminal internals", spdx: "Zlib",
                            licenseName: "zlib",
                            copyright: "Copyright (c) 2012 Jakob Progsch, Václav Zeman",
                            url: "https://github.com/progschj/ThreadPool"),
            Acknowledgement(name: "sole", usedFor: "Eternal Terminal internals", spdx: "Zlib",
                            licenseName: "zlib", copyright: "Copyright (c) 2015 r-lyeh",
                            url: "https://github.com/r-lyeh-archived/sole"),
            Acknowledgement(name: "russh", usedFor: "SSH protocol", spdx: "Apache-2.0",
                            licenseName: "Apache 2.0",
                            copyright: "Copyright 2016 Pierre-Étienne Meunier and the russh contributors",
                            url: "https://github.com/warp-tech/russh"),
            Acknowledgement(name: "ssh-key", usedFor: "SSH key generation and parsing",
                            spdx: "Apache-2.0 OR MIT", licenseName: "Apache 2.0 or MIT",
                            copyright: "Copyright (c) 2021-2026 The RustCrypto Project Developers",
                            url: "https://github.com/RustCrypto/SSH"),
            Acknowledgement(name: "AWS-LC", usedFor: "Cryptography",
                            spdx: "ISC AND (Apache-2.0 OR ISC) AND Apache-2.0 AND MIT AND BSD-3-Clause AND (Apache-2.0 OR ISC OR MIT) AND (Apache-2.0 OR ISC OR MIT-0)",
                            licenseName: "ISC, Apache 2.0, MIT and BSD 3-Clause",
                            copyright: "Copyright Amazon.com, Inc. or its affiliates; Copyright (c) 2014-2024 Google Inc.; Copyright (c) 2025-2026 Google Inc.; Copyright (c) 1998-2011 The OpenSSL Project; Copyright (c) 1995-1998 Eric Young; Copyright (c) 2015-2020 the fiat-crypto authors; Copyright (C) 2017-2025 Stephan Mueller; Copyright (c) The mlkem-native project authors; Copyright (c) The mldsa-native project authors; with contributions from Brian Smith, Robert Nagy, Arm Ltd, Sun Microsystems, Inc., Nokia and Intel Corporation",
                            url: "https://github.com/aws/aws-lc-rs"),
            Acknowledgement(name: "Tokio", usedFor: "Async runtime", spdx: "MIT",
                            licenseName: "MIT", copyright: "Copyright (c) Tokio Contributors",
                            url: "https://tokio.rs"),
            Acknowledgement(name: "UniFFI", usedFor: "Rust and Swift bridge", spdx: "MPL-2.0",
                            licenseName: "MPL 2.0", copyright: "Copyright the UniFFI authors (Mozilla)",
                            url: "https://github.com/mozilla/uniffi-rs"),
            Acknowledgement(name: "Protocol Buffers", usedFor: "Mosh and Eternal Terminal messages",
                            spdx: "BSD-3-Clause", licenseName: "BSD 3-Clause",
                            copyright: "Copyright 2008 Google Inc.",
                            url: "https://github.com/protocolbuffers/protobuf"),
            Acknowledgement(name: "ncurses", usedFor: "Terminal capabilities for Mosh",
                            spdx: "X11-distribute-modifications-variant",
                            licenseName: "MIT (X11 style, ncurses variant)",
                            copyright: "Copyright 2018-2023,2024 Thomas E. Dickey; Copyright 1998-2017,2018 Free Software Foundation, Inc.",
                            url: "https://invisible-island.net/ncurses/"),
            Acknowledgement(name: "libsodium", usedFor: "Eternal Terminal encryption (prebuilt by swift-sodium)",
                            spdx: "ISC", licenseName: "ISC",
                            copyright: "Copyright (c) 2013-2026 Frank Denis",
                            url: "https://github.com/jedisct1/libsodium"),
        ]),
        AcknowledgementGroup(header: "Fonts", items: [
            Acknowledgement(name: "Nerd Fonts", usedFor: "Icon glyphs in the bundled fonts",
                            spdx: "MIT AND CC-BY-4.0 AND OFL-1.1 AND Apache-2.0 AND Unlicense",
                            licenseName: "MIT, with icon sets under CC BY 4.0, SIL OFL 1.1, Apache 2.0 and the Unlicense",
                            copyright: "Copyright (c) 2014 Ryan L McIntyre; icon glyphs from Codicons, Font Awesome, Font Awesome Extension, Devicons, Font Logos, IEC Power Symbols, Material Design Icons, Octicons, Pomicons, Powerline Symbols, Powerline Extra Symbols, Seti-UI and Weather Icons, each under its own licence",
                            url: "https://github.com/ryanoasis/nerd-fonts",
                            changes: "Nerd Fonts 3.4.0 scaled and merged the icon glyphs into Hack and JetBrains Mono."),
            Acknowledgement(name: "Hack", usedFor: "Default terminal font", spdx: "MIT AND Bitstream-Vera",
                            licenseName: "MIT, with the Bitstream Vera License",
                            copyright: "Copyright 2018 Source Foundry Authors; Bitstream Vera Sans Mono Copyright 2003 Bitstream, Inc.; DejaVu changes are in the public domain",
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
                            copyright: "Copyright 2022 Robyn Speer and contributors. The data includes Google Books Ngrams, the Leeds Internet Corpus, Wikipedia, ParaCrawl, OPUS OpenSubtitles 2018 (from OpenSubtitles.org) and the SUBTLEX word lists by Marc Brysbaert et al., which are freely available data",
                            url: "https://github.com/rspeer/wordfreq",
                            changes: "Word frequencies (version 3.1.1 data) were blended into the English scores, so the English dictionary is shared under CC BY-SA 4.0."),
            Acknowledgement(name: "Wikipedia page titles", usedFor: "Capitalizing proper nouns",
                            spdx: "CC-BY-SA-4.0", licenseName: "CC BY-SA 4.0",
                            copyright: "Wikipedia contributors",
                            url: "https://dumps.wikimedia.org/enwiki/",
                            changes: "Titles were used only to decide the capitalised form of proper nouns."),
            Acknowledgement(name: "SCOWL", usedFor: "Confirming dictionary words",
                            spdx: "LicenseRef-SCOWL", licenseName: "SCOWL copyright notice",
                            copyright: "Copyright 2000-2018 Kevin Atkinson, and the copyrights of the word lists SCOWL is built from (full notice below)",
                            url: "http://wordlist.aspell.net/"),
            Acknowledgement(name: "tldr-pages", usedFor: "Command suggestion ranking",
                            spdx: "CC-BY-4.0", licenseName: "CC BY 4.0",
                            copyright: "Copyright 2014-present the tldr-pages team and contributors",
                            url: "https://github.com/tldr-pages/tldr",
                            changes: "Command, subcommand and flag usage was extracted from the example pages and reduced to frequency scores."),
            Acknowledgement(name: "Fig autocomplete", usedFor: "Command, subcommand and flag names",
                            spdx: "MIT", licenseName: "MIT",
                            copyright: "Copyright (c) 2021 Hercules Labs Inc. (Fig)",
                            url: "https://github.com/withfig/autocomplete"),
            Acknowledgement(name: "words/cuss", usedFor: "Keeping offensive words out of suggestions",
                            spdx: "MIT", licenseName: "MIT",
                            copyright: "Copyright (c) 2016 Titus Wormer",
                            url: "https://github.com/words/cuss"),
        ]),
    ]
}
