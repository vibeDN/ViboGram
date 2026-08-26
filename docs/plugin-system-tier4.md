# Tier 4: Python plugin system

Status as of 2026-08-26: `//Swiftgram/SGPython` is now wired into
`//submodules/TelegramUI` (via `sgdeps`), so it's part of a real
`//Telegram:Telegram` build for the first time -- but this has **not been
through an actual build yet** (CI is out of free Actions minutes until
2026-09-01; see the project memory/README for why). Items 1-3 below, listed
as "genuinely unresolved" as of 2026-08-25, now have a concrete implemented
design (resource bundling done via `apple_resource_bundle`, confirmed against
rules_apple's own docs; the vendored `Python.xcframework` itself turned out
to be carrying ~65MB of non-payload cruft, now cleaned up -- see "Vendoring
cleanup" below). Treat all of it as "confirmed feasible on paper and now
actually implemented, still unverified against a real build" until it's
actually been through a device/simulator build.

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
  now (see "Vendoring cleanup" below) **only** the compiled runtime
  (`Python.framework/Python`, a **dynamic** library -- confirmed via `file`,
  not static) + C headers, i.e. exactly what `Info.plist`'s
  `AvailableLibraries` actually declares per slice. It does **not** include
  the pure-Python standard library source or the compiled extension modules
  -- both are vendored and bundled separately, below.
  - The framework ships its own `Headers/module.modulemap` (`module Python { umbrella header "Python.h" ... }`), so `import Python` works directly from
    Swift with zero hand-written bridging header -- confirmed by inspecting
    the shipped modulemap, not yet confirmed by an actual Swift build.
  - Wrapped in `third-party/python/BUILD` via `apple_dynamic_xcframework_import`, mirroring the existing `third-party/recaptcha/BUILD` precedent in this repo (same rule family, that one uses the static variant since
    RecaptchaEnterprise ships static). Per rules_apple's own
    `doc/frameworks.md`, a dynamic xcframework/framework import is added via
    a **library's `deps`** (already how `SGPython/BUILD` references it) --
    it then propagates automatically to whatever `ios_application` links
    that library, landing in the bundle's `Frameworks/` directory with no
    separate `frameworks = [...]` entry needed at the app target level. An
    earlier revision of this doc assumed the opposite (that it'd need
    explicit `frameworks = [...]` wiring like the first-party
    `SwiftSignalKitFramework`-style targets) -- that assumption was wrong,
    confirmed against rules_apple's docs directly, not tested against a real
    build.
- `stdlib/lib/python3.14/` -- CPython 3.14.6's pure-Python standard library,
  fetched from `python.org/ftp/python/3.14.6/Python-3.14.6.tgz`'s `Lib/`
  directory (matching the xcframework's exact build version, confirmed via
  its `build-details.json`). Pruned from the original 52MB down to 12MB by
  removing `test/` (CPython's own 36MB regression suite, never needed at
  runtime), `idlelib`/`tkinter`/`turtledemo` (all require Tk, which isn't
  bundled and can't function on iOS regardless), and `ensurepip` (bundles
  pip wheels for bootstrapping `pip install`, irrelevant with no on-device
  package installation planned). Bundled into the app via
  `apple_resource_bundle(name = "PythonStdlib", bundle_name = "python", ...)`
  in `third-party/python/BUILD` -- lands at `<bundle>/python.bundle/stdlib/lib/python3.14/...`
  (see "Resource bundling" below for why the extra `stdlib/` path segment is
  there and why that's fine).
- `lib-dynload/ios-arm64/` and `lib-dynload/ios-sim-arm64/` -- CPython's
  compiled stdlib extension modules (`_socket`, `_ssl`, `_asyncio`, 70 `.so`
  files each), extracted from BeeWare's release archive (they shipped nested
  inside `Python.xcframework/<slice>/lib-arm64/python3.14/lib-dynload/`,
  which is **not** part of the xcframework's declared payload -- see below).
  Only the `arm64` host-arch variant is vendored for the simulator slice;
  there is no `lib-x86_64` (Intel-Mac-simulator is treated as unsupported,
  per the already-made call further down this doc -- virtually all current
  Macs are Apple Silicon). Each also carries its `_sysconfigdata__*.py` /
  `_sysconfig_vars__*.json` / `build-details.json` (kept, in case anything in
  the stdlib calls into `sysconfig` at runtime -- small, low-risk to keep).
  Bundled via two `apple_resource_bundle` targets sharing one `bundle_name`
  (`"python-lib-dynload"`) so exactly one is ever present in a given build --
  `select()`-ed in `SGPython/BUILD`'s `data` attribute between
  `@build_bazel_rules_apple//apple:ios_arm64` (device) and
  `//build-system:ios_sim_arm64` (simulator), the same config_setting labels
  `submodules/TelegramUI/BUILD`'s own `sgdeps` select already uses.

Total vendored size: ~72MB (`Python.xcframework` ~23MB + stdlib ~12MB +
lib-dynload ~19MB device + ~18MB simulator) -- down from ~199MB before the
2026-08-26 cleanup (see below). Committed directly to git, matching this
repo's existing convention for vendored native SDKs
(`third-party/recaptcha/RecaptchaEnterprise.xcframework` is committed the
same way, no LFS).

## Vendoring cleanup (2026-08-26)

While designing the actual resource-bundling wiring (item 1 below), reading
`Python.xcframework/Info.plist` directly turned up something the original
vendoring pass had gotten wrong: BeeWare's release archive extracts a lot
more than the real XCFramework payload into the same directory tree, and all
of it had been swept up by `glob(["Python.xcframework/**"])` along with the
real thing. `Info.plist`'s `AvailableLibraries` only declares
`<Identifier>/Python.framework` per slice -- everything else sitting
alongside it (`lib/` at the xcframework root -- a full **unpruned** 53MB
copy of the same stdlib already vendored separately and pruned; each slice's
own `bin/` -- host cross-compilation toolchain wrapper scripts; `include/` --
C headers for building extensions *from source*, not needed since no
on-device compilation is planned; `platform-config/` -- `sysconfig`/build
backend metadata for cross-compiling wheels for this platform; a
`lib -> Python.framework/Python` symlink) is leftover cruft from BeeWare's
own support-package archive layout, not something Xcode's own
xcframework-consuming tooling or `apple_dynamic_xcframework_import` treats as
meaningful. All of it has been deleted. `lib-dynload/` (the one genuinely
necessary thing that had been sitting in the wrong place, nested inside each
slice's now-deleted `lib-arm64/`/`lib-x86_64/`) was relocated out to its own
top-level `third-party/python/lib-dynload/` first, before the deletion pass,
and is now bundled as a resource rather than living inside the framework
import's glob (see above -- it's not something the linker needs, it's Python
extension modules loaded by CPython's own import machinery at runtime).

Net effect: ~127MB removed (~199MB -> ~72MB), and the xcframework import's
glob now only contains what `Info.plist` actually declares -- lower risk of
`apple_dynamic_xcframework_import` tripping on unexpected top-level content,
though whether it would have actually done so was never confirmed (no real
build to test it against either way).

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

## Resource bundling and framework embedding (implemented 2026-08-26, unverified against a real build)

These were listed as "genuinely unresolved, needs a real Bazel build to get
right" as of 2026-08-25. They now have a concrete implementation, reasoned
through from rules_apple's own documentation (fetched and read directly, not
guessed from memory) rather than from an actual build's output -- that
confirmation still doesn't exist. Recorded here so the next session (or the
first real build attempt) isn't starting from scratch, and so it's clear
exactly what's confirmed-by-docs vs. confirmed-by-build (still nothing in
the latter category).

1. **Resource bundling structure -- resolved via `apple_resource_bundle`,
   not `structured_resources` on the app target directly.** The earlier
   worry was a multi-hundred-file glob rooted outside the app's own package
   (`third-party/python/stdlib/**` vs. `Telegram/BUILD`'s package) --
   framed as if the resource declaration itself would need to live in (or
   relative to) `Telegram/BUILD`'s package. It doesn't have to: rules_apple's
   `doc/resources.md` documents `structured_resources` preserving each
   file's path *relative to the package that declares the resource rule*,
   not the consuming app target. So `PythonStdlib`/`PythonLibDynloadDevice`/
   `PythonLibDynloadSimulator` (`apple_resource_bundle` targets) are declared
   directly in `third-party/python/BUILD`, right next to the vendored files
   -- an exact match for every example in rules_apple's own docs, no
   cross-package ambiguity. They're referenced via `SGPython/BUILD`'s
   `data` attribute (rules_apple: resources attach to a library's `data`,
   not `deps`), and propagate up automatically from there. Landing paths:
   `<bundle>/python.bundle/stdlib/lib/python3.14/...` and
   `<bundle>/python-lib-dynload.bundle/lib-dynload/<ios-arm64|ios-sim-arm64>/...`
   -- `SGPythonRuntime.swift`'s search paths were updated to match. **Still
   unverified**: that rules_apple's actual path-preservation behavior really
   matches what the docs describe for this specific multi-hundred-file glob
   case -- the docs' own examples are all single-file, not "glob a whole
   pruned stdlib tree." First real build should unzip the `.app` and confirm
   `python.bundle/stdlib/lib/python3.14/os.py` actually exists at that exact
   path before debugging anything else Python-related.

2. **Dynamic framework embedding + signing -- resolved, and turned out to be
   simpler than assumed.** The 2026-08-25 revision of this doc assumed
   `Python.framework` would need explicit `frameworks = [...]` wiring on the
   app target, the same way first-party `ios_framework` targets like
   `SwiftSignalKitFramework` are. That's wrong for an *imported* dynamic
   framework specifically: rules_apple's `doc/frameworks.md` states plainly
   that `apple_dynamic_framework_import`/`apple_dynamic_xcframework_import`
   targets are added via a **library's `deps`** (already true here --
   `SGPython/BUILD` has depended on `//third-party/python:Python` since it
   was first written) and "are propagated downstream to the top-level
   bundling rule" automatically, with no `frameworks = [...]` entry needed
   at all. Codesigning of the embedded dylib is therefore also just
   rules_apple's completely standard, well-trodden handling for any embedded
   dynamic framework dependency -- not something needing the watch app's
   bespoke separate-process signing workaround (that one exists because the
   watch app is compiled by a *different tool*, `xcodebuild` outside Bazel
   entirely; Python.xcframework is a normal Bazel-tracked dependency).
   **Still unverified**: that the app actually launches with this embedded
   before `Py_Initialize()` is ever called (step 3 in "suggested order of
   attack" below) -- a bad embed or signature would crash on launch
   regardless of anything Python-specific.

3. **`lib-dynload` architecture selection -- implemented via `select()`,
   simulator scope narrowed to arm64-only.** Device gets one `.so` set
   (`ios-arm64`); simulator gets two host-arch variants upstream
   (`lib-arm64`, Apple Silicon Mac host, vs. `lib-x86_64`, Intel Mac host --
   not merged into a universal directory the way `Python.framework/Python`
   itself is). Only `lib-arm64` was vendored (see "Vendoring cleanup" above)
   -- Intel-Mac-simulator is out of scope, matching the already-made
   pragmatic call that virtually all current Macs are Apple Silicon.
   `SGPython/BUILD`'s `data` attribute `select()`s between
   `PythonLibDynloadDevice`/`PythonLibDynloadSimulator` on the same
   `@build_bazel_rules_apple//apple:ios_arm64` /
   `//build-system:ios_sim_arm64` config settings `submodules/TelegramUI/BUILD`'s own `sgdeps` select already uses, and
   `SGPythonRuntime.swift` picks the matching literal bundle sub-path via
   `#if targetEnvironment(simulator)`. **Still unverified**: that this
   actually links/bundles/resolves correctly end to end -- no build has run
   with either variant selected.

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

## Linux smoke test (2026-08-25): the PyConfig code itself is now validated

Xcode/iOS-specific integration aside, the actual *Swift ↔ CPython C API*
code in `SGPythonRuntime.swift` no longer needs to be trusted on faith. Since
this repo's own environment can't run Swift or build for iOS, a standalone
Swift toolchain (6.3.3, official Linux release from swift.org) was installed
into the scratch/session environment, paired with the system's native
CPython 3.14.6 (`/usr/include/python3.14`, `/usr/lib64/libpython3.14.so`) via
a hand-written Clang module map, to compile and run the *exact same*
`PyPreConfig`/`PyConfig`/`Py_InitializeFromConfig` sequence as a standalone
program.

This caught one real bug immediately: `PyConfig_SetString(&config,
&config.home, homeWide)` is a Swift **exclusivity violation** (two
overlapping `inout` accesses to the same `config` value in a single call —
the whole struct, and one of its own fields) and fails to compile at all.
Fixed by routing both pointers through a single `withUnsafeMutablePointer(to:
&config)` closure instead — now applied in the real file too. After that
fix, the program compiled and ran successfully end to end (with the search
paths pointed at this Linux system's own stdlib location, `/usr/lib/python3.14`, standing in for the iOS resource-bundle path): `Py_InitializeFromConfig`
succeeded, `Py_IsInitialized()` returned 1, and `PyRun_SimpleString("import
sys; ...")` executed and printed a real `sys.path`.

This does **not** validate anything iOS-specific (resource bundling into the
actual app bundle, the xcframework's dynamic linking/codesigning, or
`lib-dynload` architecture selection — all still open, see above). But the
single biggest previously-"unverified" risk — whether the hand-translated
Swift/C-interop code even compiles and does the right thing — is now
resolved. `SGPythonRuntime.swift` also gained a `lastError: String?`
property (populated from `PyStatus.err_msg`/`.func`, confirmed to carry a
real, specific message like `"Failed to import encodings module"` rather
than just a bare failure) for actually-useful diagnostics once this runs on
a real device/simulator.

## Suggested order of attack once there's real build access

Steps 1-4 below are now implemented (2026-08-26) as far as they can be
without a real build -- what's left for each is verification, not design.

1. ~~Get `//Swiftgram/SGPython` to actually compile as part of a real Bazel
   build~~ **Done**: added to `submodules/TelegramUI/BUILD`'s `sgdeps`. Not
   yet confirmed to actually compile/link -- no build has run since this was
   added.
2. ~~Solve resource bundling for the stdlib~~ **Done, on paper** -- see
   "Resource bundling and framework embedding" above. First real build
   should unzip the `.app` and confirm `python.bundle/stdlib/lib/python3.14/os.py`
   lands where expected before debugging anything else.
3. ~~Wire `Python.xcframework` into the app target's embedding~~ **Turned
   out to already be correct** -- no `frameworks = [...]` entry needed for
   an *imported* dynamic framework, see above. Still needs confirming the
   app actually launches with it embedded, before ever calling
   `Py_Initialize()`.
4. ~~Call `SGPythonRuntime.runSmokeTest()` from a debug-only settings
   row~~ **Done**: `Swiftgram/SGDebugUI`'s debug menu has a "Python Smoke
   Test" row (`SGDebugUI.swift`, `.pythonSmokeTest` action) that calls it and
   surfaces the result (or `SGPythonRuntime.lastError` on failure) via the
   same `UndoOverlayController` toast this menu already uses elsewhere.
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
