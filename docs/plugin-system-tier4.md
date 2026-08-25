# Tier 4: Python plugin system

Status as of 2026-08-25: early scaffolding only. Nothing in this doc's scope
is wired into any app target yet -- `//Swiftgram/SGPython` builds in
isolation but nothing depends on it, so it isn't part of `//Telegram:Telegram`
today. Treat everything below as "confirmed feasible on paper, unverified
against a real build" until it's actually been through a device/simulator
build on the rented Mac.

## Why this is hard, and why it's still doable

AyuGram4A and exteraGram (the two Android forks this fork's roadmap is
porting ideas from) both use [Chaquopy](https://chaquo.com/chaquopy/), a
Java/Kotlin<->Python bridge. Chaquopy is JVM-specific -- there is no iOS
port, no direct equivalent, nothing to copy. iOS needs a completely
different embedding strategy from scratch.

The good news: CPython itself is a plain bytecode interpreter (no JIT by
default), which is exactly the execution model iOS's third-party-code
restrictions are fine with (the restriction is specifically about mapping
writable memory as executable at runtime -- interpreting bytecode in a
`switch` loop never does that). As of the 3.13/3.14 line, CPython upstream
added iOS as an officially supported (Tier 3) platform --
<https://docs.python.org/3/using/ios.html>. This isn't a hobby side-project
integration anymore.

**The "auto-JIT-er" idea is a misconception, not a requirement.** What's
actually useful is `.pyc` bytecode caching (compile plugin `.py` source once,
reuse the cached bytecode on subsequent launches) -- standard, safe, built
into CPython already (`__pycache__`), nothing exotic needed. A real JIT
(e.g. CPython 3.13+'s experimental JIT, or a ptrace-based JIT-unlock trick
like StikDebug/JitStreamer use for emulators) would only matter for
CPU-heavy workloads. Plugin hooks (message events, UI callbacks) are not
that -- skip this entirely unless a real performance problem shows up later.

**Restart-only plugin activation (the user's own stated constraint) is a
real simplification, not just a UX limitation to work around.**
`Py_Finalize()` followed by `Py_Initialize()` again in the same process is
documented as fragile in CPython itself. Since plugins only take effect
after a full app relaunch, that reinit path is never needed: `Py_Initialize()`
once at process start, run for the process lifetime, let process exit be the
finalize. Don't build any interpreter teardown/reinit machinery -- there's
no scenario in this design that calls for it.

## What's vendored (`third-party/python/`)

- `Python.xcframework/` -- BeeWare's
  [Python-Apple-support](https://github.com/beeware/Python-Apple-support)
  release `3.14-b10`, iOS artifact only (CPython 3.14.6 final). Device
  (`ios-arm64`) and simulator (`ios-arm64_x86_64-simulator`) slices. This is
  the compiled runtime (`Python.framework/Python`, a **dynamic** library --
  confirmed via `file`, not static) + C headers + compiled stdlib extension
  modules (`lib-dynload/*.so`). It does **not** include the pure-Python
  standard library source.
  - The framework ships its own `Headers/module.modulemap` (`module Python { umbrella header "Python.h" ... }`), so `import Python` works directly from
    Swift with zero hand-written bridging header -- confirmed by inspecting
    the shipped modulemap, not yet confirmed by an actual Swift build.
  - Wrapped in `third-party/python/BUILD` via `apple_dynamic_xcframework_import`, mirroring the existing `third-party/recaptcha/BUILD` precedent in this repo (same rule family, that one uses the static variant since
    RecaptchaEnterprise ships static).
- `stdlib/lib/python3.14/` -- CPython 3.14.6's pure-Python standard library,
  fetched from `python.org/ftp/python/3.14.6/Python-3.14.6.tgz`'s `Lib/`
  directory (matching the xcframework's exact build version, confirmed via
  its `build-details.json`). Pruned from the original 52MB down to 12MB by
  removing `test/` (CPython's own 36MB regression suite, never needed at
  runtime), `idlelib`/`tkinter`/`turtledemo` (all require Tk, which isn't
  bundled and can't function on iOS regardless), and `ensurepip` (bundles
  pip wheels for bootstrapping `pip install`, irrelevant with no on-device
  package installation planned).

Total vendored size: ~145MB (`Python.xcframework` ~133MB + stdlib ~12MB).
Committed directly to git, matching this repo's existing convention for
vendored native SDKs (`third-party/recaptcha/RecaptchaEnterprise.xcframework`
is committed the same way, no LFS).

## What's built (`Swiftgram/SGPython/`)

`SGPythonRuntime.swift` -- a thin wrapper around the embedding C API. Uses
`PyPreConfig`/`PyConfig` with `module_search_paths_set = 1` and explicit
paths (`lib/python3.14`, `lib/python3.14/lib-dynload`, `app`), matching what
`briefcase-iOS-Xcode-template` actually does -- **not** the simpler
`setenv(PYTHONHOME)` + `Py_Initialize()` snippet from USAGE.md, which is
confirmed broken on Apple platforms (see point 4 below). Also sets
`write_bytecode = 0` since the app bundle is read-only at runtime.

`start()` no-ops safely (returns `false`) if the `python` resource folder
isn't present in the bundle -- which today it never is, since resource
bundling isn't wired up (see below). `runSmokeTest()` calls `Py_GetVersion()`
and runs a trivial `PyRun_SimpleString` as a first real signal once resource
bundling exists. Neither is called from anywhere yet.

## What's genuinely unresolved (needs a real Bazel build to get right)

These are the reasons the actual app-target wiring wasn't attempted blind
this session -- each is a real unknown, not just unfinished busywork:

1. **Resource bundling structure.** `PYTHONHOME` needs to resolve to
   `<bundle>/python/lib/python3.14/...` at runtime with directory structure
   intact. rules_apple's `resources` attribute on `ios_application` is
   expected to preserve relative paths (vs. flattening), but this hasn't
   been confirmed against this repo's exact rules_apple/rules_swift version
   for a multi-hundred-file glob rooted outside the app's own package
   (`third-party/python/stdlib/**` vs. `Telegram/BUILD`'s package). May need
   `structured_resources` instead of `resources`, or a dedicated
   `apple_resource_bundle`/filegroup wrapper -- needs iteration with real
   build output inspection (unzip the built `.app` and check where the `.py`
   files actually landed), not something to guess correctly from reading
   `.bzl` sources alone.

2. **Dynamic framework embedding + signing.** `Python.framework` is dynamic,
   so it needs to go in the app target's `frameworks = [...]` list (like
   `MtProtoKitFramework`/`SwiftSignalKitFramework` etc. already are in
   `Telegram/BUILD:1958-1963`), not just as a `swift_library` dep -- a dep
   alone would link against it without embedding the dylib into the app
   bundle, and it would fail to load at runtime. There is in-repo precedent
   for signing a nested embedded framework (the watch app's
   `TDLibFramework.framework`, see this repo's root `CLAUDE.md` "Embedded
   watch app" section), so this is solvable, but needs to be threaded
   through the existing codesigning pipeline (`Make.py`/`BuildConfiguration.py`) the same way.

3. **`lib-dynload` architecture selection is a real per-build AND
   per-runtime-host problem, not just per-platform.** The device slice has
   one `lib-dynload` (arm64). The **simulator** slice has two --
   `ios-arm64_x86_64-simulator/lib-arm64/python3.14/lib-dynload/` (Apple
   Silicon Mac host) and `.../lib-x86_64/python3.14/lib-dynload/` (Intel Mac
   host) -- as separate directories with likely-identically-named `.so`
   files (not merged into universal binaries the way `Python.framework/Python`
   itself is). Picking the right one for the *device build* is a normal
   Bazel `select()` on the existing `@build_bazel_rules_apple//apple:ios_arm64` / `//build-system:ios_sim_arm64` config settings (same pattern already
   used in `submodules/TelegramUI/BUILD`'s `sgdeps` select, fixed earlier
   this Tier). But for the *simulator build specifically*, the correct
   choice additionally depends on which Mac the simulator is actually
   running on -- not knowable at Bazel build time. Given virtually all
   current Macs are Apple Silicon, defaulting to `lib-arm64` for the
   simulator slice and treating Intel-Mac-simulator as unsupported is the
   pragmatic call, but this hasn't been implemented or tested.

4. **RESOLVED (as of research, not yet as of an actual build): naive
   `PYTHONHOME` auto-derivation is confirmed broken, `PyConfig` with
   explicit paths is the fix.** `SGPythonRuntime.start()` originally used
   the "bare minimum" `setenv("PYTHONHOME", ...)` + `Py_Initialize()`
   sequence from Python-Apple-support's own USAGE.md. That's confirmed
   unreliable on Apple platforms: **beeware/Python-Apple-support#142** hit
   exactly this pattern and got exactly the classic failure symptom
   (`ModuleNotFoundError: No module named 'encodings'`), and the
   maintainers' response was that only what Briefcase's own generated
   template does is actually supported. Fetched that template
   (`briefcase-iOS-Xcode-template`'s `main.m`) directly: it uses
   `PyPreConfig`/`PyConfig` with **`config.module_search_paths_set = 1`**,
   which disables `getpath`'s automatic home-based search entirely, and
   appends `lib/python3.14`, `lib/python3.14/lib-dynload`, and the app path
   to `config.module_search_paths` by hand. It also sets
   `config.write_bytecode = 0` (the app bundle is code-signed and read-only
   at runtime -- CPython must not try to write `.pyc` caches into it, no
   `PYTHONPYCACHEPREFIX` needed, just disable writing). `SGPythonRuntime.swift`
   has been rewritten to match this. **Still unverified**: the exact Swift
   translation of the C struct-field-pointer idioms (`&config.home`,
   `PyWideStringList_Append(&config.module_search_paths, ...)`) and
   `Py_DecodeLocale`-based wide-string conversion -- this is hand-translated
   from Objective-C reference code and has never been compiled. Confirming
   it compiles as written is step 1 below, not something to trust yet.

## Suggested order of attack once there's real build access

1. Get `//Swiftgram/SGPython` to actually compile as part of a real Bazel
   build (add it to some target's deps temporarily, confirm `import Python`
   resolves and links).
2. Solve resource bundling for the stdlib -- unzip a built `.app` and
   confirm `python/lib/python3.14/os.py` (or similar) actually lands where
   expected.
3. Wire `Python.xcframework` into `Telegram/BUILD`'s `frameworks = [...]`,
   confirm the app launches at all with it embedded (before ever calling
   `Py_Initialize()` -- a bad embed/signature would crash on launch
   regardless of Python-specific code).
4. Call `SGPythonRuntime.runSmokeTest()` from a debug-only settings row
   (`SGDebugUI`, matching this project's existing convention for
   experimental/risky entry points) and confirm `Py_Initialize()` actually
   succeeds and can import `sys`/`encodings`.
5. Only then design the actual plugin-facing API (hook points, host
   callbacks) -- no point finalizing that surface before the runtime is
   confirmed to boot at all.

## Plugin-facing API design, ported from exteraGram

exteraGram (an Android Telegram fork, Chaquopy-based) has official docs at
<https://plugins.exteragram.app/docs> covering exactly this surface. Since
its plugin API design is independent of the Python-embedding mechanism
(Chaquopy vs. our own CPython.xcframework), it ports conceptually even
though nothing about *how Python runs* carries over. Recorded here ahead of
actually needing it, per the note in step 5 above -- this is reference
material for that future design pass, not a committed API yet.

**Plugin file shape** -- one Python file, metadata as plain top-level
constants (parsed statically via AST on their side, so no dynamic
construction), one class subclassing a base plugin class:

```python
from base_plugin import BasePlugin, HookResult, HookStrategy
from ui.settings import Header, Input, Text

__id__ = "hello_world"          # required: 2-32 chars, starts with a letter, [a-zA-Z0-9_-]
__name__ = "Hello World"        # required
__description__ = "..."
__author__ = "Your Name"
__version__ = "1.0.0"           # defaults to "1.0" if omitted
__icon__ = "exteraPlugins/1"
__app_version__ = ">=12.5.1"    # supports >=, <=, ==, >, <
__sdk_version__ = ">=1.4.4.3"
__requirements__ = ["mpmath"]   # PIP packages to install

DEFAULT_TEMPLATE = "Hello, {name}!"

class HelloWorldPlugin(BasePlugin):
    def on_plugin_load(self):
        self.add_on_send_message_hook()   # hooks must be explicitly registered
        self.log("Hello World plugin loaded")

    def create_settings(self) -> list:
        return [
            Header(text="Hello World"),
            Input(key="template", text="Greeting template", default=DEFAULT_TEMPLATE),
        ]

    def on_send_message_hook(self, account: int, params) -> HookResult:
        if not isinstance(getattr(params, "message", None), str):
            return HookResult()
        if not params.message.strip().startswith(".hello"):
            return HookResult()
        name = params.message.strip().split(" ", 1)[1] if " " in params.message else ""
        template = self.get_setting("template", DEFAULT_TEMPLATE)
        params.message = template.format(name=name)
        return HookResult(strategy=HookStrategy.MODIFY, params=params)
```

**Lifecycle**: `on_plugin_load` / `on_plugin_unload` (enable/disable or app
start/shutdown), `on_app_event(event_type: AppEvent)` with
`START`/`STOP`/`PAUSE`/`RESUME`.

**Event hooks** -- explicitly registered (`self.add_hook(name)`,
`self.add_on_send_message_hook()`), then dispatched to one of these
methods, each returning `HookResult(strategy=..., <field>=...)`:
- `pre_request_hook(request_name, account, request)` / `post_request_hook(request_name, account, response, error)` -- intercept any Telegram API TL request/response by name (e.g. `"TL_messages_setTyping"`)
- `on_update_hook(update_name, account, update)` / `on_updates_hook(container_name, account, updates)` -- intercept incoming updates
- `on_send_message_hook(account, params)` -- intercept/rewrite outgoing messages before send

`HookStrategy`: `DEFAULT` (no-op), `CANCEL` (stop the operation -- e.g. a
real "ghost mode" that blocks `TL_messages_setTyping`/`TL_account_updateStatus`
requests entirely, not just a client-side visual toggle), `MODIFY` (return
an edited object), `MODIFY_FINAL` (edited + stop further plugin
processing). Every hook fires per-`account` (multi-account apps), and the
account a hook fires for is often not the one currently shown in the UI --
worth remembering since this fork also has multi-account support.

**Menu items**: `self.add_menu_item(MenuItemData(menu_type=MenuItemType.MESSAGE_CONTEXT_MENU, text=..., on_click=..., icon=..., priority=...))`.
`MenuItemType`: `MESSAGE_CONTEXT_MENU`, `DRAWER_MENU`, `MAIN_MENU`,
`CHAT_ACTION_MENU`, `PROFILE_ACTION_MENU`. The click callback receives a
context dict (`account`, `message`/`user`/`chat` depending on menu type).
Auto-removed on plugin unload.

**Settings UI**: `create_settings(self) -> List[Any]` returns a list of
dataclasses from a `ui.settings`-equivalent: `Header`, `Divider`, `Switch`,
`Selector`, `Input`, `Text` (can nest a sub-page via `create_sub_fragment`),
`EditText` (multiline), `Custom` (escape hatch for a fully custom row).
Persisted via `self.get_setting(key, default)` / `self.set_setting(key,
value, reload_settings=False)`, plus `export_settings()`/`import_settings()`
for backup/restore. This maps fairly directly onto this fork's own
`SGSettingsUI`/`ItemListUI` item-row system -- likely the most portable
piece of the whole design, conceptually.

**Host APIs exposed to plugins** (their `client_utils` module): background
queue dispatch (`run_on_queue`), raw TL request sending (`send_request`),
high-level send helpers (`send_text`/`send_photo`/`send_document`/`send_video`/`send_audio`,
all take `parse_mode="HTML"|"Markdown"`), `edit_message`, and
account-scoped accessors for the various Telegram internals controllers.
Plus `ui.bulletin.BulletinHelper.show_info(...)` for toast-style
notifications. The iOS equivalents for a comparable host-API surface would
route through `AccountContext`/`TelegramEngine` (message send/edit already
exist as engine calls used throughout this fork) and a bulletin-equivalent
(`UndoOverlayController`, already used elsewhere in this fork, e.g. the
Saved Music add/remove toasts).

**Not portable, or not needed**: their `hook_utils`/"Xposed Method
Hooking" page is Java reflection-based low-level method hooking
(LSPosed/Xposed-style) -- an Android-specific concept with no iOS
equivalent and no clear need here, since our plugins would call into a
deliberately-exposed Swift API surface rather than hook into arbitrary
compiled app internals. `Class Proxy` (generating Java proxy classes from
Python) is likewise Java-interop-specific machinery, not something a
CPython-on-iOS embed needs an equivalent of.

**Distribution**: plugins are `.py` files shared via community
repositories/catalogs (e.g. `github.com/0niel/exteraStore`) and Telegram
channels (`@exteraplugins`), not an in-app "store" backed by their own
infrastructure -- worth keeping in mind as the simpler bar to clear for a
v1 (a folder the user drops `.py` files into, matching the "app" resource
folder already planned for `PYTHONPATH`, rather than building a full
in-app plugin browser/marketplace from day one).

## Two-app-target plan (Vibogram vs. "Vibogram: BETA")

Separately decided (2026-08-25): plugin system + the JIT-unlock question
ship in a second, separate installable app ("Vibogram: BETA"), not the main
one -- keeps the stable app's blast radius at zero while this is being
iterated on. That split is its own substantial scope (new bundle id, new App
Group/provisioning profile registered on Apple's side by the project owner
-- a new bundle id is expected within a couple of days of 2026-08-25 -- plus
the currently-nonexistent variant mechanism in `Telegram/BUILD`) -- tracked
separately, not detailed further in this doc.

Progress so far: `CFBundleDisplayName`/`CFBundleName` in `Telegram/BUILD`'s
`TelegramInfoPlist` are de-hardcoded to `{telegram_app_name}` (defaulted to
`"ViboGram"` via the same `.format()` call as `telegram_bundle_id`, zero
behavior change today) -- see that commit for why the *other* mechanism
(`plist_fragment.bzl`'s own `ctx.var.get()`/`defaults` fallback) doesn't
actually apply here, since Starlark's `.format()` already resolves every
`{placeholder}` before the rule implementation ever sees the template
string. A real second `ios_application` target (and a way to pass it a
different `telegram_app_name`/`telegram_bundle_id` pair) still doesn't
exist -- this only removes one blocker on the way there.

The user supplied a BETA app icon (a flat, fully-composed PNG -- code
brackets + a sparkle, purple/magenta gradient, small "β" badge). Staged as
`Telegram/Telegram-iOS/SwiftgramBeta.icon.source/beta-icon-source.jpg` --
deliberately named with a `.icon.source` suffix (not `.icon`) so it can't be
accidentally picked up by `composer_icon_folders`'s glob. The real app icon
format this repo uses is an Xcode 26 Icon Composer bundle (`icon.json` +
vector layer assets under `Assets/`, with gradient/glass/translucency
effects described in JSON -- see the existing `Swiftgram.icon/icon.json` for
the shape), not a plain PNG. Converting this flat image into that layered
format blind (without being able to open Icon Composer to preview it) risks
producing something that looks wrong -- do that conversion once there's
real Mac/Icon-Composer access, using the staged source image.
