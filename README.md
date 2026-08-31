<div align="center">

<img src="assets/banner.jpg" alt="Vibogram" width="640">

**A personal iOS Telegram client fork.**
Built from [Swiftgram/Telegram-iOS](https://github.com/Swiftgram/Telegram-iOS) with a curated set of features ported from two Android forks, [AyuGram4A](https://github.com/AyuGram/AyuGram4A) and [Margelet](https://github.com/narezany/Margelet).

[![channel](https://img.shields.io/badge/channel-ViboGramNews-8DD1B0?style=flat-square)](https://t.me/ViboGramNews)
[![chat](https://img.shields.io/badge/chat-ViboGramChat-8DD1B0?style=flat-square)](https://t.me/ViboGramChat)
[![status](https://img.shields.io/badge/status-experimental-8DD1B0?style=flat-square)](#what-this-is-and-isnt)

</div>

---

No fixed bundle id — you generate a random one yourself at build time (see
*Building it yourself*), so it installs **next to** the official Telegram, not
over it. Built for my own daily use, not a commercial product or an attempt to
compete with anything. It's public mostly so I don't lose it, and in case it's
useful to someone else with the same itch.

Each shipped feature/fix gets a tagged pre-release on the [Releases
page](https://github.com/vibeDN/ViboGram/releases) (`MAJOR.TIER.COUNTER`, e.g.
`0.4.0` — `MAJOR` flips to `1` once every tier on the roadmap below is done).
When CI can actually build, the release carries a real device IPA, signed
with a free-tier Apple ID cert (expires after 7 days — re-signing it yourself
via LiveContainer/AltStore/SideStore/`ldid` still works after that, same as
any expired ad-hoc signature). When CI can't run, the release still goes
out — just source-only, with notes on what changed, until the next build.

## What this is (and isn't)

- Not affiliated with, endorsed by, or connected to Telegram FZ-LLC or Apple
  Inc. in any way.
- Not affiliated with the Swiftgram, AyuGram4A, or Margelet projects — this
  fork borrows ideas (and, where noted below, actual ported logic) from them.
- An experimental, personal-use build. Expect rough edges, half-finished
  features, and long gaps between updates.
- Upstream Telegram-iOS ships with no top-level LICENSE file (unlike Telegram
  Desktop/Android, which are GPL) — the source is public for review, but no
  explicit open-source license is granted for the iOS client. This fork
  inherits that same ambiguity; see *Licence* at the bottom.

## What it adds

<details>
<summary><b>Ghost mode (idea from AyuGram4A)</b></summary>

Two independent switches: skip sending read receipts, and skip sending
online/last-seen presence updates. Upstream Swiftgram already had a hidden
debug flag for the read-receipt half; this exposes both as real settings-row
toggles.
</details>

<details>
<summary><b>Deleted and edited messages stick around (idea from AyuGram4A)</b></summary>

Behind one settings toggle (secret chats excluded, on purpose). A message
someone else deletes in a cloud chat or channel is kept — tagged, not removed
— instead of vanishing: it renders semi-transparent with a 🗑 where the
"edited" label would sit. It's permanently protected from ever actually being
purged; a repeated delete request for the same message no longer un-keeps it
(an earlier build of this had exactly that bug).

Kept messages are also backed up to their own local JSON store
(`Swiftgram/SGMessageArchive`, in the app's shared App Group container),
independent of the app's own database/cache lifecycle — so a cache clear or a
Postbox rebuild doesn't lose them. Edited messages get their prior text
versions archived the same way, in a separate file next to it. There's no
viewer for those versions yet — the long-press **История** (history) menu
entry that's supposed to show them isn't built.

The visual treatment (🗑 + transparency) currently only applies to plain text
messages; media, polls, and stickers get archived correctly but don't look any
different yet.

An earlier design also mirrored deleted cloud-chat messages into Saved
Messages, for reading them from another device. That's been dropped in favour
of the local-file approach above — cross-device sync isn't a goal here, and
purely local was the simpler, more honest thing to build.
</details>

<details>
<summary><b>Streamer mode (idea from Margelet)</b></summary>

Your own phone number is covered with dots everywhere the app shows it.
There's no tap-to-reveal on purpose — the whole point is that an accidental
screen touch mid-stream shouldn't undo it. It only turns off from the switch
in settings.
</details>

<details>
<summary><b>Everything unlocked, no paywall</b></summary>

The separate "Swiftgram Pro" settings screen upstream ships with is merged
into the regular settings screen here, with the paywall check removed. Every
row underneath — including the message-filter and text-formatting features
below — works for everyone building this fork, nothing gated behind a
purchase.
</details>

<details>
<summary><b>No in-app ads</b></summary>

Sponsored messages and the free-proxy sponsor-channel prompts are hidden.
Telegram's own PSA messages stay — those aren't ads, they're official
notices — only the proxy-sponsor kind is removed.
</details>

<details>
<summary><b>No client-side App Store content filtering</b></summary>

Not on the original feature list, added on request. The stock client does a
purely cosmetic `platform == "ios"` string check to hide some content from
Apple's review. The content was always reachable server-side; this just stops
the client from hiding it from you.
</details>

<details>
<summary><b>A message field that grows as far as you want (idea from Margelet)</b></summary>

Pick 12, 15, 20, 30 lines, or unlimited — independent of the input font size,
which is also adjustable on its own. The 4096-character-per-message limit is
the server's, not the client's, and stays either way.
</details>

<details>
<summary><b>Text formatting: Size, Dim, Rainbow (mechanism ported from Margelet)</b></summary>

Select text and the formatting menu gains three entries next to bold and
italic, wired into the same toolbar the unlocked Pro screen already had.
Telegram's list of formatting types is closed and lives on the server, so
nothing can really be *added* to it — Margelet's own trick is encoding the
style as invisible Unicode markers inside the message text itself; this fork
ports that same mechanism and decodes it the same way. Copy the text
elsewhere in this app (or another build of it, or Margelet itself) and the
formatting survives; without either fork you just see plain text.

"Copy with formatting" comes along for free from the same mechanism. There's
no live preview while composing — the effect only renders after you send.
Margelet's own self-promotion watermark, which rides along with this feature
there, was deliberately not ported.
</details>

<details>
<summary><b>Screenshots and saving in secret chats</b></summary>

Also covers one-time-view / TTL media, which wasn't on the original request
but fell out of the same change. Stops the screenshot-notification sent to
the other side, and restores the Save/Copy options for that media.
</details>

<details>
<summary><b>Expire-now button for self-destructing media</b></summary>

For secret-chat TTL photos/videos this is genuinely two-sided — it's a
protocol-level delete, the other side's copy actually goes too. For
one-time-view media in normal chats, there's honestly no server API to force
the other side's copy early, so this is "delete for me, right now" only. The
UI doesn't pretend otherwise.
</details>

<details>
<summary><b>Message filters</b></summary>

Dims messages matching a keyword list — useful for the sponsored/ad posts
some channels post as regular messages. The UI and matching logic already
existed upstream in Swiftgram, just still gated behind the old Pro paywall
check that unlocking everything (above) had missed; that gate is removed, so
it actually runs now. Substring matching, not regex; dims opacity rather than
hiding the message outright.
</details>

<details>
<summary><b>Keep chat history after being kicked or banned</b></summary>

Behind a settings toggle. Voluntarily leaving a chat still hides it as
before — this only changes what happens when someone else removes you.
Doesn't retroactively un-hide chats that were already hidden before the
toggle was turned on; only applies going forward.
</details>

<details>
<summary><b>Restore deleted gifts (idea from Margelet)</b></summary>

Telegram's servers still hold limited-edition gifts that aged out of the live
catalog (last year's holiday gift, say) — the stock client redirects a tap on
one straight to a read-only info screen. This reaches the real send flow
instead, behind a toggle.

It only bypasses the "no longer in the catalog" gate specifically — not
per-person purchase limits, and not unique/collectible gifts whose supply is
genuinely exhausted (those correctly stay blocked). The server independently
re-checks on send either way, so this can only let you *attempt* it, never
force through a sale Telegram has actually closed.
</details>

<details>
<summary><b>Local Telegram Premium unlock</b></summary>

Ported from AyuGram4A's `AyuConfig.localPremium` design. A settings toggle
ORs `true` into the single chokepoint (`Peer.isPremium`) every Premium-gated
UI surface already reads — scoped to your own logged-in account(s) only;
other people's Premium badges and status stay accurate, this never fakes
anyone else's.

It only affects purely cosmetic client-side gates: extra reactions, animated
emoji status, expanded folder limits, and the like. Anything the server
independently validates — real upload limits, actually sending Premium-only
content — is still rejected server-side regardless of this toggle.
</details>

<details>
<summary><b>Music tag editing (concept from Margelet, implementation our own)</b></summary>

Title, artist, and cover, for tracks already on your own profile (Saved
Music). An edit button next to the existing add button in the overlay music
player prompts for the new tags, then re-uploads the already-cached audio as
a fresh document — `account.saveMusic` has no tag-editing parameters of its
own, so replacing the file is the only way. The old track is removed and the
new one takes its place; exact list position isn't preserved, kept simple on
purpose.
</details>

<details>
<summary><b>Badges</b></summary>

Owner-curated: a name in profiles, chat lists, and headers can carry a small
badge next to it, sourced from a JSON list published as a GitHub release
asset by CI, plus Margelet's own public `badges.json` for interop — install
this fork and you can see who has a Margelet badge too, and vice versa if
Margelet ever reads ours.

The badge certifies nothing and asks no server: whoever builds their own fork
picks their own people. Currently a first cut only — a plain colored marker
next to the name, tap opens a plain title/about popup. The badge *image*
(`img_url` in the JSON) isn't rendered yet, and there's no tap-to-spin-in-3D
like Margelet's version; the closest existing component in this codebase
(`CubeAnimationView`, a full 6-face gift-crafting cube) is overbuilt for this,
so it needs a small purpose-built gesture-driven view, tuned live once there's
real device access.
</details>

<details>
<summary><b>Profile banner and gradient</b></summary>

Two more Margelet interop pieces, in progress. Both use the same trick as
badges but taken further: instead of a file someone publishes, the "database"
is Margelet's own live public group (`@margy_underground`) — by explicit
arrangement between this fork and Margelet's author, not just reading their
data format. Set a banner or gradient here and it shows up in Margelet too,
and vice versa.

A banner is a photo behind the avatar; a gradient is two colors instead of
Telegram's own profile-header look, with text/button/card colors derived from
it (perceived-brightness math matched to this app's own light/dark-button
threshold, so a gradient choice never disagrees with it). Setting either is
just sending a tagged message to the group; clearing is deleting your own
message there — doable by hand, in the group itself, with no dependency on
this app at all. Data layer only so far (finding, setting, clearing all work)
— actually painting a banner/gradient onto the profile screen is a separate
UI pass, not done yet.

Margelet also has a "Wall" (others write about you there, you can't remove
it, built on the same group) — data layer ported too (finding/posting/
display-stripping all work), same "not on the profile screen yet" state as
banner/gradient. A wall is a live feed from many different authors rather
than a single value though, so it needs its own screen (plus tap-through
from a tagged message in the group, and composer auto-tagging) before it's
actually usable — a bigger UI lift than the other two, not attempted yet.
</details>

<details>
<summary><b>Python plugins</b></summary>

In progress, not wired into any app target yet. The idea is the same one
AyuGram4A and exteraGram's Android plugin systems use (both Chaquopy/Python
based) — there's no iOS-equivalent runtime to build on, so this is a
significant project of its own. CPython embedding (BeeWare's
Python-Apple-support `Python.xcframework` + a pruned stdlib) is vendored and
its interpreter-lifecycle wrapper is validated for correctness against a
standalone Linux Swift+CPython test — see
[`docs/plugin-system-tier4.md`](docs/plugin-system-tier4.md) for exactly
what's confirmed versus still open (resource bundling and dynamic-framework
signing are the open questions blocking a real build).

Will ship in a separate "Vibogram: BETA" app alongside a JIT-unlock mechanism
for experimental features, not the main app.
</details>

<details>
<summary><b>Log in from a session file</b></summary>

Partial. `.session` (Telethon/Pyrogram) file parsing is implemented and
validated (`Swiftgram/SGSessionImport`) — reads the auth_key straight out of
either format's SQLite schema, cross-checked against synthetic fixture files
with a standalone Linux build the same way the plugin system's CPython code
was. The actual login half — injecting that key into MTProtoKit's
`MTContext` and getting `TelegramCore` to treat the result as a normal
logged-in account without a real `auth.signIn` — is researched and designed
(exact API calls identified, including the `auth_key_id` derivation pulled
straight from this project's own key-generation code) but deliberately not
implemented yet: unlike the parsing half, it can only be verified against a
real account over the real network, and a mistake there risks that account,
not just a broken feature. Full writeup in
[`docs/session-import.md`](docs/session-import.md). TData and a generic
`.json` export remain untouched, per the original ordering. Deferred to the
same "Vibogram: BETA" work as the plugin system for the actual injection
step.
</details>

## Building it yourself

Build steps are unchanged from upstream Swiftgram / Telegram-iOS — this fork
doesn't touch the build system itself. Full detail is in the [Swiftgram
README](https://github.com/Swiftgram/Telegram-iOS#readme) and the official
[Telegram iOS compilation
guide](https://github.com/TelegramMessenger/Telegram-iOS); the summary below
is enough to get going.

Before you start:

1. [Get your own `api_id` /
   `api_hash`](https://core.telegram.org/api/obtaining_api_id) from
   my.telegram.org. Every non-official client needs its own.
2. Don't call your build "Telegram" or use Telegram's logo — make it obvious
   to anyone using it that it's unofficial.
3. Read Telegram's [security
   guidelines](https://core.telegram.org/mtproto/security_guidelines) before
   handling real accounts/data with this.

```bash
git clone --recursive -j8 https://github.com/vibeDN/ViboGram.git
```

You'll need Xcode, and Bazel invoked indirectly through the `Make.py` wrapper
(you don't need to call `bazel` directly). For a simulator build:

```bash
openssl rand -hex 8   # a random identifier for step 2
```

Create a new Xcode project with `ViboGram` (or whatever) as the Product Name
and `org.<identifier from above>` as the Organization Identifier, find your
Team ID under the `Organizational Unit` field of your `Apple Development`
certificate in Keychain Access, then fill those plus your own `api_id` /
`api_hash` into `build-system/template_minimal_development_configuration.json`
and run:

```bash
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    generateProject \
    --configurationPath=build-system/template_minimal_development_configuration.json \
    --xcodeManagedCodesigning
```

Add `--disableProvisioningProfiles` to skip codesigning entirely for a
simulator-only build. For a device/release build, use
`build-system/appstore-configuration.json` with a real codesigning setup
instead, and the `build` action in place of `generateProject` — see the
upstream README for the full advanced walkthrough (IPA export, Xcode version
pinning, the usual Bazel/Xcode troubleshooting).

## What this repository does not contain

- **`api_id` / `api_hash`.** The build owner's own keys. Get yours at
  my.telegram.org — never committed here.
- **A code-signing certificate or provisioning profile.** CI holds its own
  (free-tier, 7-day) cert as a repo secret, not committed here; a source-only
  release (see *Development builds* above) has nothing signed at all, and
  anything you distribute yourself beyond your own device is on you to sign.

## Files here

| | |
|---|---|
| `Swiftgram/` | this fork's own feature modules, one per feature (`SGMessageArchive`, `SGBadges`, `SGPython`, …) |
| `submodules/` | upstream Telegram-iOS libraries, patched in place where a feature needed it |
| `third-party/python/` | vendored CPython xcframework + pruned stdlib for the plugin system |
| `docs/` | design/status notes for the larger in-progress features |
| `README.md` | this file — also the feature roadmap and its status |

## Licence

Upstream Telegram-iOS ships with no top-level LICENSE file — the source is
public for review, but Telegram doesn't grant an explicit open-source license
for the iOS client the way it does for Desktop/Android (GPL). This fork
inherits that same ambiguity rather than resolving it. Treat any build or
redistribution of this code accordingly — it's not something a README can
settle on your behalf.
