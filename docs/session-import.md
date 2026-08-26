# Session-file login: research and design (2026-08-26)

Status: **parsing is implemented and validated; injection into a running
account is designed but NOT implemented.** This is the "log in via an
existing session file" long-term roadmap item from the README. Per that
item's own note, this is meaningfully riskier than everything else on the
roadmap -- it touches raw MTProto authentication material for a real,
already-logged-in account. Read the whole "Why this is scoped the way it is"
section before touching the injection half.

## What's implemented: `Swiftgram/SGSessionImport`

Parses a `.session` file (Telethon or Pyrogram; both are plain, unencrypted
SQLite databases) and extracts the one thing that matters: an existing
MTProto `auth_key`. Nothing else -- no MTProtoKit, no TelegramCore, no
account state. See `Sources/SGSessionImport.swift`'s own header comment for
the reasoning; the two real schemas (sourced directly from each project's
own code, not third-party docs) are recorded there too.

**Validated** the same way `SGPython`'s CPython embedding code was: a
standalone Swift 6.3.3 (Linux) program, linked against the system's
`libsqlite3` via a hand-written module map (sqlcipher and vanilla sqlite3
share an identical C API when no encryption key is set, which is exactly the
case for these files -- they're plain SQLite from the other client's
perspective). Ran against synthetic fixture `.session` files built with the
`sqlite3` CLI, matching each project's real schema exactly:

- Telethon (`telethon/sessions/sqlite.py`): `sessions(dc_id integer primary key, server_address text, port integer, auth_key blob, takeout_id integer, tmp_auth_key blob)`. No `user_id` column at all -- Telethon doesn't persist it.
- Pyrogram (`pyrogram/storage/sqlite_storage.py`): `sessions(dc_id INTEGER PRIMARY KEY, api_id INTEGER, test_mode INTEGER, auth_key BLOB, date INTEGER NOT NULL, user_id INTEGER, is_bot INTEGER)`. Carries `user_id`/`is_bot` directly.

Confirmed against both fixtures, plus a multi-row Telethon fixture (a second,
unauthenticated dc_id row with an empty `auth_key` blob, simulating a
session that once touched a media/CDN datacenter) to confirm the "skip empty
blobs, prefer the real key" row-selection logic. All three passed.

**Not implemented**: TData (Telegram Desktop's own local storage format).
Per the README's own ordering this comes after `.session` support, and it
isn't SQLite at all -- a completely different parser, out of scope for this
pass.

## Why this is scoped the way it is

Everything past "parse the file" needs to inject a real, already-valid
MTProto `auth_key` into this app's own MTContext and get TelegramCore to
treat the result as a normal logged-in account -- without ever calling
`auth.signIn`. That's real MTProto-authentication-internals territory, and
critically, **it can only be verified against a real Telegram account over
the real network** -- there is no offline/Linux-side way to validate this
the way the parsing logic or SGPython's CPython code could be checked. A
mistake here risks a real account (session gets logged out, flagged, or
worse), which is a categorically different risk than "the plugin runtime
doesn't boot" or "the anti-delete feature has a bug." Designing this
carefully now and implementing it later, on a real device, with a disposable
test account, is the right call -- not shipping unverified code that touches
live auth material.

## The design, researched against this repo's actual code

### 1. Constructing the auth info

`MTDatacenterAuthInfo` (`submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTDatacenterAuthInfo.h`) has a public initializer taking a raw key directly:

```objc
- (instancetype)initWithAuthKey:(NSData *)authKey
                       authKeyId:(int64_t)authKeyId
             validUntilTimestamp:(int32_t)validUntilTimestamp
                         saltSet:(NSArray *)saltSet
               authKeyAttributes:(NSDictionary *)authKeyAttributes;
```

`authKeyId` isn't stored in a `.session` file -- it has to be derived from
the raw key. The exact algorithm, taken directly from this project's own
`MTDatacenterAuthMessageService.m:692-695` (real key-generation code, not an
external spec reading):

```objc
NSData *authKeyHash = MTSha1(authKey);
int64_t authKeyId = 0;
memcpy(&authKeyId, (((uint8_t *)authKeyHash.bytes) + authKeyHash.length - 8), 8);
```

i.e. SHA1 the 256-byte key, take the last 8 bytes, `memcpy` them directly
into an `int64_t` (host byte order -- no explicit endianness conversion in
the reference code, so none should be added here either). `saltSet` can
start as an empty array (`MTContext` / `MTDatacenterAuthMessageService`
populate it from `future_salts` server responses as needed once the key is
in use); `authKeyAttributes` likewise starts empty; `validUntilTimestamp`
should be `0` (permanent key, matching how a normal persistent login's key
behaves -- not a temporary/ephemeral key, which is what
`MTDatacenterAuthInfoSelectorEphemeralMain`/`...Media` are for).

### 2. Registering it with the context

`MTContext.updateAuthInfoForDatacenterWithId:authInfo:selector:` (public,
`MTContext.h:117`) is the exact chokepoint -- called with the imported
`dc_id`, the constructed `MTDatacenterAuthInfo`, and
`MTDatacenterAuthInfoSelectorPersistent`. This is the same method the normal
login flow itself calls once its own `auth.signIn`-derived key is ready, so
there's real precedent for this exact call succeeding with a freshly-built
`MTDatacenterAuthInfo` -- the only difference is where the key came from.

The account's `masterDatacenterId` also needs to be set to the imported
`dc_id` (an `UnauthorizedAccountState`/`AuthorizedAccountState` field, see
below) so the rest of the stack knows which datacenter this account's home
is.

### 3. Confirming identity -- do NOT trust the file blindly

Pyrogram's schema carries `user_id` directly; Telethon's doesn't store it at
all. Even where the file does carry a `user_id`, it's better *not* to trust
it as the sole source of truth for constructing `AuthorizedAccountState` --
the file could be stale (the account may have since been logged out
elsewhere, banned, or the number changed). The right design is: **inject the
key first, then make one real authenticated API call over that connection**
(e.g. `users.getUsers` for `inputUserSelf`) to fetch the actual current
`TelegramUser` from Telegram's own servers. If the key is genuinely still
valid, this succeeds and returns ground-truth data; if the key has been
revoked/logged out elsewhere, this fails cleanly (an `AUTH_KEY_UNREGISTERED`
or similar RPC error) *before* anything's been committed to Postbox as a
fake logged-in state. This is meaningfully more robust than constructing
`AuthorizedAccountState` from file-stored/guessed data and hoping it's still
current -- it's really "resume a session and verify it's alive," not "fake
a login."

### 4. Finishing the transition

Once a real `TelegramUser` is in hand (from step 3), the exact pattern
already used by the normal login flow (`Account.swift:150-163`, the
`sentCodeSuccess`/`.authorization` case) applies directly:

```swift
let state = AuthorizedAccountState(isTestingEnvironment: testingEnvironment, masterDatacenterId: masterDatacenterId, peerId: user.id, state: nil, invalidatedChannels: [])
transaction.setState(state)  // postbox.transaction
// ...then, in a separate accountManager.transaction:
switchToAuthorizedAccount(transaction: transaction, account: self, isSupportUser: isSupportUser)
```

`initializedAppSettingsAfterLogin` is also called at this point in the real
flow (contacts sync etc.) -- worth deciding deliberately whether an imported
session should trigger the same first-login side effects or skip them
(arguably it should skip most of them, since this isn't a fresh account).

## Open questions, not yet decided

- **Where does the user actually pick the file from?** A `.session` file
  needs to reach the app somehow -- `UIDocumentPickerViewController` is the
  obvious choice (matches how this app already handles file imports
  elsewhere), but the exact entry point (a new settings row? part of the
  existing add-account flow?) hasn't been designed.
- **What happens to multi-account state if the imported account is already
  logged in on this device under a real phone-number login?** Needs a
  decision on de-duplication (same underlying Telegram account, two
  different local `Account` entries) before this ships, not after.
- **Should the original `.session` file be left untouched (read-only, as
  implemented) forever, or should there be a "detach"/"this device now owns
  the session" step?** Leaving it untouched means the other client (Python
  script, bot, whatever created it) and this app both stay logged in
  simultaneously on the same key -- which is normal, expected MTProto
  multi-session behavior, not a conflict, but worth stating explicitly
  rather than assuming.
