# Writing a plugin for ViboGram

A quick guide to what you can actually build today, with a working example
first and the fine print after. For the longer architecture writeup (how the
Python runtime is embedded, what's still unverified), see
[`plugin-system-tier4.md`](plugin-system-tier4.md).

## Quick start

Create a file, `hello.vibo`:

```python
def transform(args):
    name = args.get("name", "world")
    return f"Hello, {name}!"
```

Open **Settings → Plugins → Import from Files…** and pick it. Tap the plugin
in the list, choose **Run** — it calls `transform({})` and shows you the
result. That's the whole loop: one file, one function, one JSON dict in, one
string out.

## The plugin contract

- **File**: a single `.vibo` file, plain Python — our own extension. (`.plugin`
  and `.py` are still accepted on import, for anything brought over from
  exteraGram or elsewhere; new plugins, including both built-ins, ship as
  `.vibo`.)
- **Entry point**: a module-level function. The name doesn't have to be
  `transform` — whatever calls your plugin picks the name; the two built-in
  examples both happen to use `transform`.
- **Argument**: one Python `dict`, built from JSON on the Swift side. Only
  JSON-safe values in and out — strings, numbers, booleans, `None`, lists,
  and nested dicts. No images, no host objects, no callbacks.
- **Return value**: a single string.
- **Where it lives**: `Settings → Plugins` manages your installed plugins
  (stored in the app's own Documents folder, so they survive updates). The
  same screen is reachable directly via the `tg://sg/plugins` link.

## Two real examples

**`animefy.vibo`** — text in, text out. Takes `{"text": ..., "intensity":
..., "options": {...}}`, returns the decorated string. Wired up for real:
turning on **Settings → Anime-ify sent messages** calls this plugin on every
outgoing message. This is the shape most plugins should aim for — pure
function of JSON-safe input to a JSON-safe output, no platform access needed
inside the plugin at all.

**`ascii_art.vibo`** — a plugin that needs something Python alone can't
do (decode an image). The **app** decodes the photo and computes a
brightness value per output cell — that part happens in Swift because our
bundled Python has no image codec. The **plugin** only receives the
already-computed grid of numbers and turns it into text art. If your idea
needs a capability like this, the pattern is: do the platform-specific part
in the app, hand the plugin only the primitive data it needs to do its part.

## What can't run here, full stop

If a plugin (yours, or one you're porting from somewhere else) imports any
of these, it's calling into Android's live app internals, and there's no
version of that on iOS — not a matter of rewriting it, the target objects
just don't exist on this platform:

```
java, java.*                          # the Java bridge itself
android.*                             # Android UI/graphics/system APIs
org.telegram.messenger, org.telegram.tgnet, org.telegram.ui.*
com.exteragram.messenger.*
```

Check a plugin's imports before doing anything else with it. A plugin built
only on plain Python plus its own host's declarative helpers (settings UI,
simple send/log calls) usually ports fine, rewritten against our contract
above; one reaching into the classes above doesn't, regardless of how much
time you put into it.

## The `vibo` host object

Every plugin run through **Run** in the Plugins screen, or through an
`on_send` hook (below), gets a global `vibo` with:

- `vibo.log(message)` / `vibo.toast(text)` -- shown as an overlay notice
  after your plugin finishes.
- `vibo.alert(text, title=None)` -- shown as a real dialog after your
  plugin finishes.
- `vibo.get_setting(key, default=None)` / `vibo.set_setting(key, value)` --
  your plugin's own small persistent JSON store, keyed by your plugin's
  filename. Survives between runs; nothing else can read it.

None of these fire *while* your code is running -- there's no live channel
back into a running script, so calls are queued and replayed once your
`transform` returns. Call them as many times as you like; order among
themselves is preserved.

`transform` itself can now return anything JSON-safe, not just a string --
a number, a list, a dict, `None`. A plain string is shown as-is; anything
else is shown as its JSON form. Returning `None` and using `vibo.toast`/
`vibo.alert` instead is completely fine if a plugin's real output is a
side effect, not a value.

## Automatic hooks

Give your plugin's file a first line of exactly:

```python
# vibo-hook: on_send
```

and its `transform` runs automatically on every outgoing plain-text
message, chained with any other installed hook plugin (alphabetical by
filename) -- each one sees the previous one's output as its `text`. A
plugin that errors, isn't found, or returns the text unchanged is skipped
silently; nothing ever blocks sending. There's no per-plugin on/off
switch yet -- having the plugin installed *is* the switch, so remove or
rename the file to stop it running.

`on_send` is the only hook name the app actually acts on today. The
`# vibo-hook: <name>` line is meant to carry future hook names (like
`on_receive`) the same way once something in the app looks for them --
using an unrecognized name today is just inert, not an error.

## What still can't happen: custom UI

A plugin cannot add its own tab, screen, button, or any other visible UI
element -- there's no declarative UI format for it to describe one in, and
nothing on the Swift side would know how to render it. Genuinely new UI
from a plugin (not just this app's own settings toggle, action-sheet, and
overlay/dialog plumbing calling into `vibo`/hooks) is a real gap, not a
missing convenience method -- it needs its own design before it can exist.

## Bringing over an idea from somewhere else

Don't copy the file — port the *technique*. Read what it computes as a
function of its inputs, then write that computation fresh as a
`transform(args)`-shaped function using your own names, wording, and (for
anything like word lists or fixed choices) your own content. Two ported
examples in this app did exactly that, credited in their own header
comments.

## What's not built yet

- No hook beyond `on_send`. Nothing runs your plugin on any other event
  (incoming messages, chat open, etc.) yet.
- No manifest, permissions, versioning, or update mechanism — a plugin is
  just the file you dropped in; updating it means re-importing it.
- Errors still don't surface as a proper message in the UI when a plugin
  raises — its call returns nothing, and the actual traceback only shows
  up in a live device console log. Use `vibo.log`/`vibo.toast`/`vibo.alert`
  to report your own problems back to the user instead of letting an
  exception swallow the whole run.
- No custom UI (see above) and no per-plugin on/off switch for hooks —
  installed is enabled.
