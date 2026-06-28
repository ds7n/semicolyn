# Predictor seed ingestion — Fig autocomplete specs

**Date:** 2026-06-21
**Status:** Locked
**Phase:** 4k (predictor) — a second seed source feeding the same ``SeedBuilder``:
structured `(command, subcommand)` / `(command, flag)` pairs from the
MIT-licensed Fig (withfig/autocomplete) spec corpus. tldr examples
([[2026-06-21-predictor-seed-ingestion-design]]) under-represent the breadth of
subcommands/flags a tool *has*; Fig specs enumerate them declaratively. Extends
steps 1–6 of the seed pipeline in [[2026-06-13-predictor-design]].

## Why Fig, not carapace

The master spec named carapace, but its 400+ tools ship as **Go completers inside
a binary** — there is no clean structured export (only per-context JSON from
`carapace export`). Harvesting it means installing the binary and recursively
shelling out: heavy, slow, and reproducibility-tied to a binary version. The Fig
corpus is **declarative spec files in a pinnable git repo** (600+ CLIs, MIT), the
same script-fetch + SeedKit-parser shape tldr already uses. Decision recorded
after confirming carapace's data model; see this session's design fork.

## The parsing problem: structured data inside TypeScript

A Fig spec is a `.ts` module, not JSON:

```ts
import { filepaths } from "@fig/autocomplete-generators";   // ← braces that aren't data

const completionSpec: Fig.Spec = {
  name: "git",
  subcommands: [
    { name: "commit", options: [{ name: ["-m", "--message"], args: { name: "msg" } }] },
    { name: ["status", "st"], description: "Show status" },
  ],
  options: [{ name: "--version" }],
  args: { name: "path", generators: { script: (ctx) => { return `...`; } } },  // ← fn-body braces
};
export default completionSpec;
```

Three traps a naive `grep 'name:'` falls into:

1. **`args: { name: … }`** — `args.name` is a *placeholder* (`msg`, `path`), not a
   subcommand or flag. Must be excluded.
2. **Function/generator bodies and template literals** carry `{`/`}` and `${…}`
   that are not object structure. A frame-tracking parser must keep brace balance,
   so strings/templates/comments are consumed whole.
3. **`import { … }`** braces precede the spec object.

## FigSpecParser — tokenizer + frame stack

`invocations(fromSpec:command:) -> [[String]]` returns one `[command, member]`
pair per extracted name — the **same 2-element-sequence shape** ``TldrParser``
emits, so ``SeedBuilder/ingest`` consumes both identically (`[a, b]` → unigrams
`a`,`b` + bigram `(a, b)`). `command` is the caller-supplied filename stem
(`git.ts` → `git`) — far more robust than parsing the spec's own `name`.

**Tokenizer** reduces the source to the only tokens that matter — `{ } [ ] : ,`,
string literals, and identifiers — and *skips everything else*:

- `//` line and `/* */` block comments → dropped (a `{` in a comment must not push).
- `"…"` / `'…'` strings → one token, escapes handled; `` `…` `` templates → one
  opaque token flagged *template* (its `${…}` braces never reach the stack, and a
  templated name is not extracted).
- `import` → skip through its module-path string, swallowing import braces.
- numbers, operators, parens, `;`, `=>` → ignored; brace balance is preserved
  because every `{`/`}` and `[`/`]` outside a string/comment is still tracked.

**Frame stack** classifies each `{`/`[`. A `name:` is extracted **only** when its
immediately enclosing object is a *top-level member* — a `{ }` that is a direct
element of the spec's own top-level `subcommands:` or `options:` array:

- An array is *top-level* when pushed with the spec (bottom) object as its
  enclosing frame; a member is *top-level* when its enclosing array is.
- This excludes: the spec's own `name` (enclosing is the root object, not a
  member), every `args.name` (enclosing is an `args` object, not a sub/opt array),
  and **nested** subcommands/options (enclosing array is not top-level).

**Extraction.** For a top-level member's `name`: a string → one member; a `[ … ]`
of string aliases → each alias (`["-m","--message"]` → both `-m` and `--message`).
Template-literal names are skipped.

### Deliberate scope: top-level only

Nested `(subcommand, flag)` / `(subcommand, sub-subcommand)` structure is **not**
extracted — attributing a deeply-nested flag to the top command would teach
`(git, --abbrev-commit)`, and threading correct parent context through arbitrary
TS is where the fragility lives. tldr already supplies real nested-usage pairs
from examples; Fig's job here is breadth of *top-level* subcommands and flags.
A precise nested extractor is a future option, not this slice.

### Robustness posture

This is a heuristic over a foreign language, by design. Worst case on exotic TS
is a missed or spurious `(command, X)` pair in a **seed** — low weight,
per-prefix gated, overwhelmed by user data. The parser never crashes
(bounded scans, fail-soft) and is tested against comments, template literals,
function bodies, import braces, `args.name`, name-alias arrays, nesting,
**regex literals** (consumed opaquely, with a last-significant-char heuristic
separating `/regex/` from division so an unbalanced `/]/` can't desync the
frame stack), and division.

Accepted clean misses (no desync, just `[]` or a stray pair — fine for a seed):
a spec wrapped in an array or returned from a function (extra brace depth hides
the top level), and a helper object before the spec that happens to carry a
`subcommands:`/`options:` key (a spurious pair).

### Per-file command attribution: top-level specs only

The command is the file stem, which is correct **only for the top-level
`src/*.ts`** specs (`git.ts` → `git`). The Fig repo also keeps ~750 nested
fragments (`src/aws/s3.ts`, `src/shopify/3.0.0.ts`) — full `Fig.Spec` objects
mounted as *subcommands* of a parent, whose stems (`s3`, `3.0.0`) are not real
commands. So `semicolyn-seedbuild` walks the Fig source **non-recursively**: the
top-level `aws.ts` already lists `{ name: "s3" }` as a subcommand, giving the
correct `(aws, s3)` pair, while the deeper `aws s3 ls` structure is left to tldr
(consistent with this slice's top-level-only scope).

## Wiring

- ``SeedBuilder`` is unchanged — both parsers emit `[[String]]` and share `ingest`.
- `semicolyn-seedbuild` gains `--tldr <dir>` / `--fig <dir>` / `--out <dir>` (at least
  one source required); the Fig walk derives each file's command from its stem.
- `scripts/build-seed.sh` also clones withfig/autocomplete (pinnable via
  `FIG_REF`) and passes `--fig`.

## Out of scope (later slices)

- **Nested-context Fig extraction** — `(subcommand, flag)` with correct parent.
- **Curated dotfiles frequency** — the third master-spec source.
- **Runtime first-launch load into `seed_pinned`** — the consumer of these blobs.
