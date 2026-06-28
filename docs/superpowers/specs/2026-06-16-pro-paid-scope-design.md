# Pro / paid scope — design

**Date:** 2026-06-16
**Status:** Locked (v1 scope) · Enterprise = explicitly deferred to v2+

## Goal

Set the policy for what (if anything) Semicolyn charges money for, so that
future feature ideas can be tested against a written rule instead of
re-litigated case by case.

## Posture

Semicolyn ships into a category with established competitors (Blink, Termius,
Prompt 3, Secure ShellFish, etc.). Monetization is **secondary to product
quality**. The product is for users; payment is for users who *want* to
support development. No feature that defines the product sits behind a
paywall.

## The qualification rule

> **A feature qualifies as Pro only if it is cosmetic, optional, or a
> thank-you. The moment "I need Pro to do X" is a real sentence, the
> feature is wrong for Pro.**

Apply this rule when any future feature is proposed. If gating it behind
Pro would make a free user feel locked out of something they need, it
belongs in free.

## v1 Pro tier

### Shape

- **One tier above free.**
- **One-time purchase**, not subscription. Single non-consumable in-app
  purchase via StoreKit.
- **Price band:** low, in the $5–10 USD range. Exact price decided
  pre-launch; not load-bearing on any design here.
- **No "trial" mode, no time-limited free Pro, no upsell modals, no
  "limited free" feature stripping.** The free product is complete on
  its own.
- **Family Sharing** enabled (Apple in-app purchase setting). Cheap, no
  product-design cost, removes a class of complaint.

### What Pro contains in v1

Purely cosmetic / vanity:

1. **Alternative app icons.** Variants of the bell-bronze mark — a few
   tasteful options (e.g., a verdigris-patina variant, a high-contrast
   monochrome variant). Apple's `UIApplication.setAlternateIconName`.
2. **Alternative color themes.** Once a second palette is *actually
   designed* (deferred — see Out of scope below), Pro unlocks the
   non-default themes. v1 ships bell-bronze for everyone; Pro themes
   light up the moment a second palette exists.
3. **"Supporter" badge in About & Help.** A small bronze chip next to
   the version row when Pro is active — visible only to the user, not
   surfaced anywhere else. Removes the worry that supporting the dev
   is invisible to the supporter themselves.

That's the entire v1 Pro inventory. Three items, all cosmetic / vanity.

### Where Pro lives in the UI

A single row inserted into the existing **About & Help** screen
(`docs/superpowers/specs/2026-06-16-settings-sub-screens-design.md`),
positioned at the top:

```
About & Help
─────────────────────────────────────
  ✦  Semicolyn Pro                        >    ← new top row when free
─────────────────────────────────────
  ?  Tips & Gestures                  >
─────────────────────────────────────
  Privacy statement                   >
  Open source                         >
─────────────────────────────────────
  Send feedback                       ↗
─────────────────────────────────────
  Semicolyn 1.0.0 (1234)
```

When Pro is active, the row changes to:

```
  ✦  Semicolyn Pro — thanks!             >
```

…and the row below the version becomes:

```
  Semicolyn 1.0.0 (1234)        Supporter ✦
```

(That's the Supporter badge described above — present only in About,
nowhere else in the app.)

Tapping the Pro row pushes to an **upgrade screen** described next.

### The upgrade screen

A single push from `About & Help → Semicolyn Pro`. No modal, no full-screen
takeover. Plain settings push.

Contents:

```
                  ✦
              Semicolyn Pro

  Semicolyn is, and will stay, free to use in full. Pro is
  for people who want to support development. Buy it
  once; that's it.

  What's included:
  ─────────────────────────────────────
   ◐  Alternative app icons
   ◐  Alternative color themes (when available)
   ✦  Supporter badge

  ─────────────────────────────────────

           [ Unlock Semicolyn Pro — $X.XX ]    ← StoreKit-styled CTA

       Restore purchase   ·   Family Sharing on
```

- **No urgency language.** No "limited time," no "save 50%," no countdown.
- **The list is exact.** No vague "and more!" — users see what they're
  buying.
- **The first sentence** anchors the deal: free stays free.
- **Restore purchase** is required by App Store guidelines and lives
  centered below the CTA, not buried.
- **Family Sharing on** is shown as a plain note, not a sales bullet.

When Pro is active, the screen replaces the CTA with a small "Thanks for
supporting Semicolyn" line and shows the active perks as checkmarks instead
of selling them.

### Visibility rules

- **No upsell prompts anywhere else in the app.** Not in onboarding, not
  after the first connection, not after the Nth connection, not on
  preference changes.
- **No "Pro" lock icons next to non-Pro features.** There aren't any
  free features to lock; cosmetic items either are or aren't shown
  based on Pro state.
- **The About & Help row is the only entry point.** Discoverable by a
  curious user who wants to support; invisible to a user who doesn't
  care.

## Enterprise — explicitly deferred

**No enterprise scope in v1.** This section captures ideas without
committing to any of them, so future signal can be tested against a
written list instead of starting from scratch.

When enterprise is revisited, the qualification rule still applies —
even in an enterprise tier, gating fundamentals would feel like extortion
to teams who already need them to do their work. Enterprise should be
features that **only make sense in an org context** (centralized
control, multi-user coordination, audit), not features that solo users
also want but pay-walled.

### Candidate enterprise features (not designed, not committed)

- **Audit log** — already stubbed at the data layer in
  `2026-06-16-icloud-sync-scope-design.md`. Compliance use case:
  immutable record of connections, commands sent, identities used.
  Requires its own surface, retention policy, and probably an export
  path. Strongest "only-makes-sense-for-enterprise" candidate.
- **Team-shared host configs.** A team admin defines a set of hosts /
  identities; team members get them pushed via the admin's backend.
  Requires backend infrastructure — *real* recurring cost — so this is
  the most natural subscription candidate if there ever is one.
- **MDM-friendly configuration.** Semicolyn respects an MDM-pushed
  configuration profile (allowed hosts, forbidden hosts, enforced
  per-use Face ID on all identities, mandatory pattern-exclude list,
  iCloud sync off, etc.). Sells to companies that have an existing
  device-management story.
- **Centralized policy enforcement.** Admin-defined rules that override
  user toggles: "App lock is on, full stop." "Predictor is off, full
  stop." "These hosts require a specific identity." Composes with MDM
  but doesn't require it.
- **SSO into the app.** Org-managed identity for unlocking Semicolyn itself
  (in addition to or replacing app-level Face ID). Tightly coupled with
  MDM / centralized policy.
- **Sealed bundled-snippet packs.** Org-curated snippet libraries
  pushed to all members. Lower compliance value than audit log; more
  ergonomics-flavored.
- **Concurrent-device licensing / seat management.** The admin sees who
  on the team has Semicolyn active; can revoke or rotate. Requires backend.
- **Premium support.** Direct support channel (not just `Send
  feedback`), SLAs, etc. Pure service offering — no product code at all.

### Why these are *not* in v1

- Each requires infrastructure (backend, MDM integration, admin
  console) Semicolyn does not have.
- Designing them speculatively without a customer is a great way to
  build the wrong thing.
- The qualification rule already excludes anything that would feel
  required to solo users.

## Out of scope (v1)

- **Subscription tier of any kind.** Not freemium with monthly. Not Pro
  as subscription. Not "Pro+." If a feature has real recurring cost
  later (team sync infra), revisit then.
- **Multiple Pro tiers** ("Pro" vs "Pro+" vs "Ultimate"). One Pro SKU
  in v1.
- **Promo codes, gifting, referral programs.** Add only if there's a
  clear reason later.
- **A second color palette.** Pro unlocks alternate themes *when they
  exist*. v1 ships one palette; alternate themes are their own design
  exercise.
- **Donation-only tip jar (no perks).** The Supporter badge + alternate
  icons are minimal perks, but enough that the purchase is named "Pro"
  rather than "donation," which sets clearer expectations.
- **Localised pricing decisions.** Apple handles store-tier pricing;
  this spec only fixes the price band.

## Related specs and amendments

- `docs/superpowers/specs/2026-06-16-settings-sub-screens-design.md`
  gains a **Semicolyn Pro** row at the top of About & Help (when free),
  and a **Supporter** badge on the version row (when Pro). No
  re-litigation of the other About & Help contents.
- `docs/superpowers/specs/2026-06-16-icloud-sync-scope-design.md`
  already notes the audit-log stub as a "future Pro compliance
  feature" — confirmed here, now bound specifically to the enterprise
  candidate list, not the v1 Pro tier.
- The product's monetization README line (currently "free / one-time
  / subscription / pro tier — closely related to Pro scope above")
  is now resolved: **free + one-time Pro**, no subscription.
