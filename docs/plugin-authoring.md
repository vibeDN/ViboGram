# Writing a plugin for ViboGram (Tier 4, early)

This is the practical companion to [`plugin-system-tier4.md`](plugin-system-tier4.md)
(architecture/status) and its "Plugin-facing API design, ported from exteraGram"
section (the eventual `BasePlugin`/hook surface — not built yet). This document
is about what actually runs *today*.

## The one thing to understand first

**There is no real plugin-loading API yet.** A plugin here is a single Python
file that gets executed and — for the handful of built-in examples — has one
function called with a JSON-serializable argument and its return value used.
There is no `BasePlugin` base class, no hook registration, no `margelet`/
`base_plugin` host object. If you bring a plugin written for exteraGram or
Margelet, **it will not run as-is** — see "What can never work" below before
spending time on anything.

## What actually runs

- **File format**: a single `.plugin` or `.py` file (plain Python source;
  `.plugin` is exteraGram's convention and is accepted for familiarity, but
  it is *not* their zip-based format — ours is always plain text).
- **Storage**: `Documents/Plugins/` inside the app's own sandbox, writable at
  runtime. Manage it from Settings → Plugins, or the `tg://sg/plugins` link.
- **Execution**: `SGPythonRuntime.run(fileAt:)` just executes a file's
  top-level code and reports whether it raised — good for "does this even
  parse and run," nothing else. `SGPythonRuntime.callFunction(scriptPath:
  functionName:argumentsJSON:)` is the real one: it runs the file, then calls
  a named top-level function with **one dict argument** (crossing as JSON —
  see below) and returns its string result.
- **The two built-in examples** (`animefy.plugin`, `ascii_art.plugin`,
  both under `Swiftgram/SGPython/Sources/SGPythonRuntime.swift` as embedded
  source, written out to `Documents/Plugins/` whenever the Plugins screen
  opens) are the actual reference for the shape a working plugin has today:
  a module-level `transform(args)` function, `args` a plain dict, return a
  plain string.

## Why JSON, not a real object bridge

Swift and the embedded CPython don't share objects. `callFunction` writes its
argument dict to a temp JSON file, appends a small wrapper to your plugin's
source that decodes it, calls your function, and JSON-encodes the result to a
second temp file, then Swift reads that back. This is deliberately the least
capable thing that could work: it was built on `PyRun_SimpleString` alone —
the only primitive already proven to compile and run through a real device
build — rather than the lower-level `PyObject`/`PyDict` C API, which hasn't
been exercised yet. Practical effect: **your function's argument and return
value must both be JSON-safe** (dicts, lists, strings, numbers, bools, `None`)
— no images, no host objects, no callbacks.

## What can never work, regardless of effort

If your plugin (or one you're trying to bring over) imports any of these, it
is tied to Android's live object graph and there is no path to running it
here — not "hard," structurally impossible on iOS:

- `java`, `java.*` (Chaquopy's Java bridge)
- `android.*` (Android UI/graphics/system APIs)
- `org.telegram.messenger`, `org.telegram.tgnet`, `org.telegram.ui.*`
  (Telegram-for-Android's own internal classes)
- `com.exteragram.messenger.*` (exteraGram's own Android-side plugin host)

We checked real examples this way: a plugin using only `margelet.*`/
`base_plugin` calls with no Java imports (an outgoing-text transform) ported
cleanly. One reaching into `org.telegram.tgnet.tl.TL_stars` and
`android.graphics.Bitmap` for gift statistics did not, and a UI-tweaks plugin
built directly on `org.telegram.ui.ActionBar`/`.Components` (600+
functions, explicitly dependent on another such plugin as a shared library)
is the same problem at much larger scale. Check your plugin's imports before
anything else.

## What crosses over well

- Deterministic text/data transforms: string in, string out, no host object
  access. `animefy.plugin`'s word-swap/stutter/kaomoji mechanism is this
  shape exactly.
- Anything where the *host platform* (not the plugin) does the
  platform-specific part, and the plugin only does the portable computation
  on primitive data. `ascii_art.plugin` is this shape: Swift decodes the
  image and computes a brightness grid (CoreGraphics has no Python
  equivalent bundled — there's no Pillow in this stdlib), and the plugin
  only turns that grid into characters.

## Practical checklist before porting something

1. `grep -n '^import\|^from' file.plugin` — if you see anything from the
   "never works" list, stop; it's not a matter of how it's written.
2. Otherwise, work out what the plugin actually computes as a pure function
   of its inputs and outputs, using your own words/vocabulary for anything
   distinctly the original author's (word lists, jokes, specific naming) —
   port the *technique*, not the file.
3. Write it as a module-level function taking one dict, returning a string
   (or design a new host-callable entry point if the shape genuinely
   doesn't fit — there's no fixed contract yet beyond "JSON in, string out").
4. Drop it in `Documents/Plugins/` via Settings → Plugins → Import, and use
   the Plugins screen's "Run" (or, for `ascii_art.plugin`, "Run on Photo…")
   to test it end to end.

## Known gaps (don't be surprised)

- No hook registration — nothing calls your plugin automatically on a
  message event unless something in the app was specifically wired to call
  it (as `animefy.plugin` is, via the "Anime-ify sent messages" setting).
  There's no generic way yet for a plugin to say "run me on every outgoing
  message" — that's the actual `BasePlugin`/hooks design work, still open.
- No manifest, no permissions, no versioning, no update mechanism. A plugin
  is just a file you drop in and re-drop in to update.
- No error surface beyond a boolean/console log — a raised exception inside
  `callFunction`'s wrapper currently makes the whole call return `nil`; you
  won't see the traceback without a device console attached.
