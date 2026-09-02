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
string out. If your plugin actually wants text (like the two examples
below), use **Run with Text…** instead — it prompts for a string and calls
`transform({"text": ...})`.

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
- **Return value**: any JSON-safe value -- a string is the common case,
  but a number/list/dict/`None` all work too (see "The `vibo` host
  object" below for the details of how each is shown).
- **Where it lives**: `Settings → Plugins` manages your installed plugins
  (stored in the app's own Documents folder, so they survive updates). The
  same screen is reachable directly via the `tg://sg/plugins` link.
- **Display name** (optional): a top-level `__name__ = "Your Plugin"`
  string constant -- same convention exteraGram plugins use. Shown in the
  Plugins list instead of the raw filename; purely cosmetic, doesn't
  change how your plugin is called.

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

Any plugin can opt into this by putting `# vibo-needs: image` anywhere in
its file -- that alone gets it a **Run on Photo…** button (not just
`ascii_art.vibo`, that's just the plugin this was built for). Picking a
photo calls your `transform` with `{"grid": [[0-255, ...], ...], "invert":
False}` -- rows of per-cell brightness, nothing else. Any effect that
reduces to "a pattern of brightness values" fits this; anything needing
actual color or pixel detail doesn't have a way in yet.

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
  after your plugin finishes. (Only when run from the Plugins screen's
  **Run** button -- an `on_send` hook's toast/log/alert/share calls are
  recorded but nothing currently displays them, since a message send
  shouldn't interrupt itself with a dialog.)
- `vibo.alert(text, title=None)` -- shown as a real dialog after your
  plugin finishes. Same Plugins-screen-only caveat as above.
- `vibo.share(text)` -- the system share sheet (AirDrop, Files, any other
  app), not Telegram's own in-chat share. Same Plugins-screen-only caveat.
- `vibo.open_url(url)` -- opens a link in the browser. `http`/`https`
  only; anything else is silently ignored (no custom URL schemes, this
  app's own `tg://` included). Takes effect immediately, like the
  clipboard/haptic calls below -- no dialog involved.
- `vibo.play_sound(style_or_path="default")` -- a short system sound.
  `style_or_path` is one of `"default"`/`"tap"`, `"success"`, `"alert"`,
  or a local file path (any short clip -- `.caf`/`.wav`/`.aiff` work
  best, same format iOS's own UI sounds use) if you want your own,
  e.g. something you decoded once into `vibo.data_dir()`. An
  unrecognized style or a path that doesn't exist just stays silent,
  never an error. Immediate effect, same as clipboard/haptic/open_url.
- `vibo.get_setting(key, default=None)` / `vibo.set_setting(key, value)` --
  your plugin's own small persistent JSON store, keyed by your plugin's
  filename. Survives between runs; nothing else can read it.
- `vibo.data_dir()` -- a real directory path, yours alone (also keyed by
  filename), for anything bigger than get_setting's one JSON blob. Use
  plain `open()`/`os.path.join(vibo.data_dir(), "...")` against it -- no
  special API, just a sandboxed folder.
- `vibo.get_clipboard()` -- the system clipboard's current text, or
  `None`. `vibo.set_clipboard(text)` -- replaces it. This one **does**
  take effect immediately, from any call site, `on_send` hooks included --
  there's no dialog involved, so nothing needs to wait for the Plugins
  screen to display it.
- `vibo.haptic(style="light")` -- a haptic tap. `style` is one of
  `"light"`, `"medium"`, `"heavy"`, `"success"`, `"warning"`, `"error"`.
  Same immediate-effect, works-from-any-caller behavior as the clipboard
  calls.
- `vibo.device_info()` -- a dict: `os_version`, `device_model`,
  `app_version`, `locale`, `is_dark_theme`. Read-only, computed fresh each
  call.
- `vibo.list_plugins()` -- filenames of every currently installed plugin
  (yours included). Read-only.

None of `log`/`toast`/`alert`/`share` fire *while* your code is running --
there's no live channel back into a running script, so those four are
queued and only actually shown once your `transform` returns. Call them
as many times as you like; order among themselves is preserved.
`get_clipboard`/`device_info`/`list_plugins`/`data_dir` are the opposite:
computed once right before your script starts, so they read as of when
your plugin was *called*, not as of when you happen to read them inside
your own code. `set_clipboard`/`haptic`/`open_url`/`play_sound` take effect immediately
after your script finishes, same as the queued ones, but need no UI to
do it, so they fire from every call site (Plugins screen or `on_send`
hook alike).

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

### `on_receive` -- reacting to incoming messages

Same marker convention, different name and a real capability boundary:

```python
# vibo-hook: on_receive
```

calls your `on_receive(args)` (`args = {"text": ..., "peer_title": ...}`)
for every real incoming message (not muted, not while the device is
locked -- same filtering this app's own notification sound already
uses). Unlike `on_send`, **the return value is completely ignored** --
there's no safe way for a plugin to rewrite what a message says it said,
so it can't. Only side effects reach the user, and only some of them:
`vibo.play_sound`/`set_clipboard`/`open_url` fire immediately (no UI
needed), but `vibo.toast`/`alert`/`log`/`share` go nowhere from
`on_receive` -- there's no notification-banner-safe place to show them
yet. Lean on `play_sound` for the "something happened" reaction.

`on_send` and `on_receive` are the only hook names the app acts on
today. The `# vibo-hook: <name>` line is meant to carry future hook
names the same way once something in the app looks for them -- using an
unrecognized name today is just inert, not an error.

## Your own settings screen

Define a `settings(args)` function -- it's called exactly like `transform`
is, with `{}`, so it needs to accept the argument even though there's
nothing useful in it yet -- and return a list of widgets:

```python
def settings(args):
    return [
        {"type": "header", "text": "Behavior"},
        {"type": "switch", "key": "loud", "text": "Shout everything", "default": False},
        {"type": "selector", "key": "tone", "text": "Tone", "default": 0, "items": ["Polite", "Neutral", "Rude"]},
        {"type": "text", "text": "Changes apply on your next message."},
    ]
```

A **Settings…** button appears in the plugin's action sheet automatically
once it sees a `settings()` function in your file. Values the user picks
are stored in the exact same per-plugin state your `transform` already
reads with `vibo.get_setting`/`vibo.set_setting` -- nothing extra to wire
up on your end, just read the keys you declared:

```python
def transform(args):
    tone = ["polite", "neutral", "rude"][vibo.get_setting("tone", 0)]
    loud = vibo.get_setting("loud", False)
    ...
```

Widget types today: `header` (section title), `text` (a plain line, not
clickable), `switch` (`key`, `text`, `default: bool`), `selector` (`key`,
`text`, `default: int` index, `items: [str]`), `action` (`id`, `text`,
`default` for `destructive: bool`), `input` (`key`, `text` as the row's
label, `default: str`, `placeholder: str`) -- a real text field, e.g. for
an API key or any other string a plugin needs from the user. This is the
same shape as exteraGram's `create_settings()` Header/Switch/Selector/
Text/Action/Input rows, ported to this app's own settings framework.
`input` writes on every keystroke but doesn't trigger a screen refresh
the way switch/selector/action do -- typing shouldn't fight the field for
focus. Read it back with `vibo.get_setting` the same as any other value.

### Buttons that actually do something: `action` + `on_action`

```python
{"type": "action", "id": "start", "text": "Start"}
```

Tapping this calls `on_action(args)` in your file, with
`args = {"id": "start"}` -- it gets the full `vibo` object like any other
call, and the **whole screen refreshes** after it returns (your
`settings()` runs again, so it can show something different based on
what just happened):

```python
def on_action(args):
    if args["id"] == "start":
        vibo.set_setting("running", True)
        vibo.toast("Started", style="success")
    return None
```

There's no live connection while the screen sits there -- this is
request/response, not a running callback. A plugin can't animate
anything or update a row on its own timer; it can only react to a tap by
computing what the screen should look like *next* and handing that back.
Good enough for multi-step config, a Start/Stop pair that swaps itself
out, "generate X and show the result" -- not for anything that needs to
move or update while nobody's touching it.

## What still can't happen: custom UI beyond a settings screen

A plugin cannot add its own tab, a button in the chat itself, or any
visible UI beyond what's described above -- there's no general
declarative UI format, just this one fixed settings-screen vocabulary,
and nothing on the Swift side would know how to render anything outside
it. A real generic UI system (arbitrary layouts, live callbacks while
something is on screen) is still a gap, not a missing convenience method.

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
- If your plugin raises, **Run** in the Plugins screen and the settings
  screen both now show the actual traceback in a dialog — no more
  guessing from a console log. This only applies when running through
  the Plugins screen, though: an `on_send` hook that raises is still
  silently skipped (never blocks sending), so use `vibo.log`/`vibo.toast`
  there if you want the user to know something went wrong.
- No custom UI (see above) and no per-plugin on/off switch for hooks —
  installed is enabled.
