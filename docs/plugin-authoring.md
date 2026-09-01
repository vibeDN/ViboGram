# Writing a plugin for ViboGram

A quick guide to what you can actually build today, with a working example
first and the fine print after. For the longer architecture writeup (how the
Python runtime is embedded, what's still unverified), see
[`plugin-system-tier4.md`](plugin-system-tier4.md).

## Quick start

Create a file, `hello.plugin`:

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

- **File**: a single `.plugin` or `.py` file, plain Python. (`.plugin` is
  just the extension exteraGram uses too, kept for familiarity — the
  contract below is our own, not theirs.)
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

**`animefy.plugin`** — text in, text out. Takes `{"text": ..., "intensity":
..., "options": {...}}`, returns the decorated string. Wired up for real:
turning on **Settings → Anime-ify sent messages** calls this plugin on every
outgoing message. This is the shape most plugins should aim for — pure
function of JSON-safe input to a JSON-safe output, no platform access needed
inside the plugin at all.

**`ascii_art.plugin`** — a plugin that needs something Python alone can't
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

## Bringing over an idea from somewhere else

Don't copy the file — port the *technique*. Read what it computes as a
function of its inputs, then write that computation fresh as a
`transform(args)`-shaped function using your own names, wording, and (for
anything like word lists or fixed choices) your own content. Two ported
examples in this app did exactly that, credited in their own header
comments.

## What's not built yet

- No automatic hooks. Nothing runs your plugin on a message/event unless
  something in the app specifically calls it — like `animefy.plugin`'s
  settings toggle does. There's no generic "run this on every incoming
  message" registration yet.
- No manifest, permissions, versioning, or update mechanism — a plugin is
  just the file you dropped in; updating it means re-importing it.
- Errors don't surface in the UI. A plugin that raises makes its call
  return nothing; the actual traceback only shows up in a live device
  console log, not in the app.
