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

`SGPythonRuntime.swift` -- a thin wrapper around the embedding C API,
following BeeWare's own documented Swift init snippet
(`Python-Apple-support/USAGE.md`) exactly:

```swift
guard let pythonHome = Bundle.main.path(forResource: "python", ofType: nil) else { return }
let appPath = Bundle.main.path(forResource: "app", ofType: nil)
setenv("PYTHONHOME", pythonHome, 1)
setenv("PYTHONPATH", appPath, 1)
Py_Initialize()
```

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

4. **iOS-specific `sys.path`/`getpath` behavior is unverified.** The
   xcframework's `_sysconfigdata__ios_arm64-iphoneos.py` bakes in the CI
   runner's *build-time* paths (`/Users/runner/work/...`), which are not
   meant to be read directly -- CPython's runtime path resolution
   (`getpath.c`) is supposed to relocate relative to `PYTHONHOME` at
   startup, same as on desktop Unix, but this hasn't been confirmed
   empirically for the iOS build specifically. If `Py_Initialize()` can't
   locate/import `encodings` (the classic embedding failure mode), that's
   the first thing to check.

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

## Two-app-target plan (Vibogram vs. "Vibogram: BETA")

Separately decided (2026-08-25): plugin system + the JIT-unlock question
ship in a second, separate installable app ("Vibogram: BETA"), not the main
one -- keeps the stable app's blast radius at zero while this is being
iterated on. That split is its own substantial scope (new bundle id, new App
Group/provisioning profile registered on Apple's side by the project owner,
a currently-nonexistent variant mechanism in `Telegram/BUILD` since the app
display name is hardcoded there today) -- tracked separately, not detailed
further in this doc.
