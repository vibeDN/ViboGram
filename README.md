# ViboGram-Telegram

A personal iOS Telegram client fork. It's [Swiftgram](https://github.com/Swiftgram/Telegram-iOS) (itself a "supercharged" fork of the official Telegram iOS client) with a specific goal bolted on: porting a curated set of features from two Android Telegram forks, [AyuGram4A](https://github.com/AyuGram/AyuGram4A) and [Margelet](https://github.com/narezany/Margelet), that have no existing iOS equivalent.

This is a hobby project built for my own daily use, not a commercial product or an attempt to compete with anything. It's public mostly so I don't lose it and in case it's useful to someone else with the same itch.

## What this is (and isn't)

- Not affiliated with, endorsed by, or connected to Telegram FZ-LLC or Apple Inc. in any way.
- Not affiliated with the Swiftgram, AyuGram4A, or Margelet projects — this fork just borrows ideas (and, eventually, ports actual logic) from them.
- An experimental, personal-use build. Expect rough edges, half-finished features, and long gaps between updates.
- Upstream Telegram-iOS ships with no top-level LICENSE file (unlike Telegram Desktop/Android, which are GPL) — the source is public for review, but no explicit open-source license is granted for the iOS client. This fork inherits that same ambiguity; treat it accordingly.

## Community

- Channel: [@ViboGramNews](https://t.me/ViboGramNews)
- Chat: [@ViboGramChat](https://t.me/ViboGramChat)

## Credit

All the actual client engineering is upstream. This fork exists to add a thin layer on top:

- **[Swiftgram/Telegram-iOS](https://github.com/Swiftgram/Telegram-iOS)** — the base this fork is built on. Handles the vast majority of the app; without it this project doesn't exist.
- **[AyuGram/AyuGram4A](https://github.com/AyuGram/AyuGram4A)** — Android Telegram fork, source of most of the "ghost mode" / anti-delete / privacy-oriented feature ideas being ported here.
- **[narezany/Margelet](https://github.com/narezany/Margelet)** — Android Telegram fork, source of several of the UI/UX tweaks (input field behavior, formatting effects, streamer mode, etc.) being ported here.

If a feature below turns out to already exist upstream in Swiftgram, this README will be corrected — no point reinventing it.

## Feature roadmap

This is a living plan, not a fixed spec. Tiers are roughly in priority order — quick/self-contained wins first, riskier persistence-layer work later, the plugin system last because it's a project in its own right.

Status legend: `[ ]` not started, `[x]` done. GitHub doesn't render a third checkbox state, so partial items stay unchecked with a note.

### Tier 1 — quick wins

- [x] Ghost mode: skip read receipts (exposed as a real toggle; upstream's own hidden debug flag stays as a separate override)
- [x] Ghost mode: skip online/last-seen presence updates
- [ ] Customizable "edited" / "deleted" message marks (partial: edited label done; deleted half waits on Tier 3 anti-delete)
- [x] Streamer mode (mask your own phone number in the UI)
- [x] Show User ID in profile (already existed upstream in Swiftgram, nothing to build)
- [x] Trimmed shipped extensions to Notification (Content + Service) and Broadcast Upload only — dropped Share, Siri Intents, and Widget
- [x] Merged the separate "Swiftgram Pro" settings screen into the regular Swiftgram one, unlocked for everyone (no more paywall)
- [x] Remove in-app ads (sponsored messages, free-proxy sponsor-channel prompts — PSA messages stay, only proxy-sponsor kind is hidden)
- [x] Bypass client-side iOS/App Store content restrictions (not on the original list — added on request). Purely cosmetic filtering (`platform == "ios"` string checks); the content was always reachable, this just stops the client from hiding it.

### Tier 2 — medium

- [x] Expandable message input field (default 12 / 15 / 20 / 30 / unlimited lines) + adjustable input font size (independent of the chat text size setting)
- [x] Custom text formatting effects (Size / Dim / Rainbow), integrated into the existing Swiftgram Pro input toolbar. "Copy with formatting" comes for free — the style lives as invisible Unicode markers directly in the message text, so any copy/paste preserves it. No live preview while composing (effect renders after send); Margelet's own self-promo watermark was intentionally not ported.
- [x] Allow screenshots in secret chats (expanded to cover one-time-view/TTL media too, per request) — stops the screenshot-notification-to-peer, and restores Save/Copy for that media
- [ ] TTL expire-now button for self-destructing photos/videos

### Tier 3 — heavier (touches persistence/state)

- [ ] Local anti-delete (keep local history of deleted/edited messages)
- [ ] Message filters (hide sponsored/ad posts in channels)
- [ ] Keep chat history after being banned/kicked from a chat
- [ ] Restore deleted gifts
- [ ] Local Telegram Premium UI unlock
- [ ] Music file tag editing (title/artist/cover) — re-upload semantics still being worked out

### Long-term / separate track

- [ ] Python plugin system, merging the approaches used by AyuGram4A's and exteraGram's Android plugin systems (both Chaquopy/Python-based). This has no direct iOS-equivalent runtime, so it's a significant standalone effort on its own — tackled last, after everything above is stable.

## Development builds

Every CI run publishes an **unsigned** device IPA to the [Releases page](https://github.com/vibeDN/ViboGram/releases), tagged `v0.0.<build number>` and marked as a pre-release. It is not signed with any certificate — you'll need to resign it yourself (LiveContainer, AltStore/SideStore, `ldid`, etc.) before installing on a real device. Once every feature on the roadmap above is done, a proper signed `v1.0.0` replaces this scheme.

## Building

Build steps are unchanged from upstream Swiftgram / Telegram-iOS — this fork doesn't touch the build system. Full detail is in the [Swiftgram README](https://github.com/Swiftgram/Telegram-iOS#readme) and the official [Telegram iOS compilation guide](https://github.com/TelegramMessenger/Telegram-iOS); the summary below should be enough to get going.

### Before you start

1. [Obtain your own `api_id` / `api_hash`](https://core.telegram.org/api/obtaining_api_id) from my.telegram.org. Every non-official Telegram client needs its own.
2. Don't call your build "Telegram" or use Telegram's logo — make sure anyone using it understands it's unofficial.
3. Read Telegram's [security guidelines](https://core.telegram.org/mtproto/security_guidelines) if you're going to be handling real accounts/data with this.
4. There's no explicit upstream license granting redistribution rights for the iOS client source (see the note above) — if you plan to distribute a build beyond personal use, that's on you to reason about, not something this README can settle.

### Get the code

```
git clone --recursive -j8 https://github.com/vibeDN/ViboGram-Telegram.git
```

### Requirements

- Xcode (from the App Store or https://developer.apple.com/download/applications)
- Bazel, invoked indirectly through the `Make.py` wrapper — you don't need to call `bazel` directly for normal use

### Quick build (simulator / local dev)

1. Generate a random identifier:
   ```
   openssl rand -hex 8
   ```
2. Create a new Xcode project using `ViboGram` (or whatever) as the Product Name, and `org.{identifier from step 1}` as the Organization Identifier.
3. In Keychain Access → Certificates, find `Apple Development: your@email.address (XXXXXXXXXX)`, open it, and note the `Organizational Unit` under Details — that's your Team ID.
4. Edit `build-system/template_minimal_development_configuration.json` with the values from the steps above (including your own `api_id`/`api_hash`).
5. Generate the Xcode project:
   ```
   python3 build-system/Make/Make.py \
       --cacheDir="$HOME/telegram-bazel-cache" \
       generateProject \
       --configurationPath=build-system/template_minimal_development_configuration.json \
       --xcodeManagedCodesigning
   ```

For a simulator-only build you can skip codesigning entirely by adding `--disableProvisioningProfiles` to the `generateProject` invocation.

### Device / release builds

Same idea, but using `build-system/appstore-configuration.json` and a real codesigning setup (`build-system/fake-codesigning` as a reference for provisioning profiles / entitlements), then running the `build` action instead of `generateProject`, e.g.:

```
python3 build-system/Make/Make.py \
    --cacheDir="$HOME/telegram-bazel-cache" \
    build \
    --configurationPath=your-configuration.json \
    --codesigningInformationPath=your-codesigning-directory \
    --buildNumber=100001 \
    --configuration=release_arm64
```

See the upstream README for the full advanced-build walkthrough, IPA export steps, Xcode version pinning (`versions.json` / `--overrideXcodeVersion`), and troubleshooting for the usual Bazel/Xcode gremlins (stuck `build-request.json`, dangling `Telegram_xcodeproj` package errors after a restart, etc.) — none of that differs here.

## Contributing

This is a personal fork built around a specific feature list, so it's not really looking for scope creep. That said, if you're working from the same AyuGram4A/Margelet feature list and want to compare notes or send a fix, issues and PRs are welcome — just keep in mind priorities follow the tier list above.
