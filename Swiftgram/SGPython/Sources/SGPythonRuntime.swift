import Foundation
import Python

// MARK: ViboGram - Tier 4 plugin system, Swift-side interpreter lifecycle
// wrapper around CPython's embedding C API (docs.python.org/3/c-api/init_config.html).
//
// Deliberately NOT the "bare minimum" setenv(PYTHONHOME)+Py_Initialize()
// sequence shown in Python-Apple-support's own USAGE.md -- that relies on
// CPython's automatic getpath search deriving lib/python3.14 from
// PYTHONHOME, which is confirmed broken on Apple platforms in practice:
// beeware/Python-Apple-support#142 hit exactly this ("ModuleNotFoundError:
// No module named 'encodings'") with that exact pattern, and the
// maintainers' own response is that only what Briefcase's generated
// template actually does is supported. So this mirrors that template
// (briefcase-iOS-Xcode-template's main.m) instead: PyConfig with
// module_search_paths_set=1 and every path appended explicitly, bypassing
// getpath's auto-derivation entirely. write_bytecode=0 because the app
// bundle is code-signed and read-only at runtime -- CPython must not try to
// write .pyc caches into it.
//
// Validated (2026-08-25): this exact PyConfig/PyPreConfig sequence, translated
// from briefcase-iOS-Xcode-template's (Objective-C) main.m, was compiled and
// run standalone against Linux' native CPython 3.14 (Swift 6.3.3 toolchain,
// not the iOS xcframework) as a stand-in for the C-interop syntax and control
// flow -- Py_InitializeFromConfig succeeded and PyRun_SimpleString could
// import sys. One real bug was caught and fixed this way (see the
// PyConfig_SetString call below). Still NOT validated: anything iOS-specific
// -- resource bundling into the actual app bundle, the xcframework's dynamic
// linking/signing, lib-dynload architecture selection. See
// docs/plugin-system-tier4.md.
//
// Restart-only activation (see README): the interpreter starts once per
// process and is never torn down/reinitialized -- Py_Finalize() followed by
// Py_Initialize() again in the same process is documented as fragile in
// CPython itself. Since plugins only take effect after a full app relaunch,
// that path is never needed here.
public enum SGPythonRuntime {
    private static var didStart = false
    // MARK: ViboGram - captures the CPython-provided PyStatus.err_msg on failure
    // (confirmed via the Linux compile test to carry a real, specific message,
    // e.g. "Failed to import encodings module" -- far more useful than just
    // knowing *that* something failed).
    public private(set) static var lastError: String?

    private static func describe(_ status: PyStatus) -> String {
        let funcName = status.func.map { String(cString: $0) } ?? "<unknown>"
        let errMsg = status.err_msg.map { String(cString: $0) } ?? "<no message>"
        return "\(funcName): \(errMsg)"
    }

    // MARK: ViboGram - the stdlib and lib-dynload are each their own
    // apple_resource_bundle (see third-party/python/BUILD), landing at the
    // app bundle's root as `python.bundle` / `python-lib-dynload.bundle` --
    // not a plain `python` folder like earlier revisions of this file
    // assumed before the resource-bundling wiring was actually designed.
    public static var isBundled: Bool {
        return Bundle.main.path(forResource: "python", ofType: "bundle") != nil
    }

    @discardableResult
    public static func start() -> Bool {
        if didStart {
            return true
        }
        guard let resourcePath = Bundle.main.resourcePath, isBundled else {
            lastError = "resource bundle not found (isBundled=\(isBundled))"
            return false
        }

        var preconfig = PyPreConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        preconfig.utf8_mode = 1
        preconfig.configure_locale = 1

        let preStatus = Py_PreInitialize(&preconfig)
        guard PyStatus_Exception(preStatus) == 0 else {
            lastError = describe(preStatus)
            return false
        }

        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        defer {
            PyConfig_Clear(&config)
        }

        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.install_signal_handlers = 1
        config.module_search_paths_set = 1

        func decode(_ path: String) -> UnsafeMutablePointer<wchar_t>? {
            return path.withCString { Py_DecodeLocale($0, nil) }
        }
        func appendSearchPath(_ path: String) -> Bool {
            guard let wide = decode(path) else {
                lastError = "Py_DecodeLocale failed for path: \(path)"
                return false
            }
            defer { PyMem_RawFree(wide) }
            let status = PyWideStringList_Append(&config.module_search_paths, wide)
            if PyStatus_Exception(status) != 0 {
                lastError = describe(status)
                return false
            }
            return true
        }

        // MARK: ViboGram - two separate apple_resource_bundle targets (see
        // third-party/python/BUILD): `python.bundle` for the pure-Python
        // stdlib (structured_resources preserves the full package-relative
        // glob path, hence the "stdlib/lib/python3.14" segment), and
        // `python-lib-dynload.bundle` for the compiled extension modules,
        // which is select()-ed per build config so exactly one of
        // ios-arm64/ios-sim-arm64 is ever actually present on disk --
        // #if targetEnvironment(simulator) picks the matching literal path
        // to match whichever one Bazel actually bundled.
        let stdlibPath = resourcePath + "/python.bundle/stdlib/lib/python3.14"
        #if targetEnvironment(simulator)
        let dynloadPath = resourcePath + "/python-lib-dynload.bundle/lib-dynload/ios-sim-arm64"
        #else
        let dynloadPath = resourcePath + "/python-lib-dynload.bundle/lib-dynload/ios-arm64"
        #endif
        let appPath = resourcePath + "/app"

        guard appendSearchPath(stdlibPath), appendSearchPath(dynloadPath), appendSearchPath(appPath) else {
            return false
        }

        if let homeWide = decode(resourcePath + "/python.bundle") {
            // MARK: ViboGram - bugfix, confirmed by a standalone Linux Swift+CPython
            // compile test: `PyConfig_SetString(&config, &config.home, homeWide)` is
            // a Swift exclusivity violation (two overlapping inout accesses to the
            // same `config` in one call: the whole struct and one of its fields).
            // withUnsafeMutablePointer(to:) makes both derive from a single access.
            withUnsafeMutablePointer(to: &config) { configPtr in
                _ = PyConfig_SetString(configPtr, &configPtr.pointee.home, homeWide)
            }
            PyMem_RawFree(homeWide)
        }

        let initStatus = Py_InitializeFromConfig(&config)
        guard PyStatus_Exception(initStatus) == 0 else {
            lastError = describe(initStatus)
            return false
        }

        didStart = Py_IsInitialized() != 0
        return didStart
    }

    // Smoke test only -- not a real plugin-loading path. Intended to be
    // reached from a debug-only settings row (SGDebugUI), never from normal
    // app startup, until this has actually been confirmed against a real
    // build -- see docs/plugin-system-tier4.md.
    public static func runSmokeTest() -> String {
        guard start() else {
            return "SGPythonRuntime: start() failed -- \(lastError ?? "<no error captured>")"
        }
        let versionCString = Py_GetVersion()
        let version = versionCString.map { String(cString: $0) } ?? "<unknown>"
        let status = PyRun_SimpleString("import sys; print('SGPython smoke test OK, sys.path =', sys.path)")
        return "Py_GetVersion() = \(version); PyRun_SimpleString exit status = \(status) (0 = success; check device console log for the printed sys.path)"
    }

    // MARK: ViboGram - first real plugin-execution path (SGPluginsUI). Still
    // just PyRun_SimpleString on the whole file's source, same as the smoke
    // test -- no BasePlugin/hook machinery yet (see docs/plugin-system-tier4.md's
    // exteraGram-ported API design for what that eventually needs to look
    // like). This only proves a given .py file's top-level code executes
    // without crashing the host process; a raised Python exception prints
    // to the console (PyRun_SimpleString's own behavior) and is reflected
    // here only as a nonzero exit status, not the exception text itself --
    // good enough to confirm "does this plugin even run", not full test.
    public static func run(fileAt path: String) -> String {
        guard start() else {
            return "SGPythonRuntime: start() failed -- \(lastError ?? "<no error captured>")"
        }
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "Failed to read plugin file at \(path)"
        }
        let status = source.withCString { PyRun_SimpleString($0) }
        if status == 0 {
            return "Ran successfully (exit status 0)."
        } else {
            return "Plugin raised an exception (exit status \(status)) -- check device console log for the traceback."
        }
    }

    // MARK: ViboGram - first real "call a plugin function and use its actual
    // return value" path, as opposed to run(fileAt:)/runSmokeTest's "did it
    // crash". Deliberately built on PyRun_SimpleString alone -- the one
    // primitive already confirmed working end-to-end through a real CI
    // build -- rather than the lower-level PyObject/PyDict C API
    // (PyRun_String, PyObject_CallFunctionObjArgs, PyUnicode_*, ...), which
    // this embedding has never exercised and can't be verified without
    // another full build cycle. Instead, the argument dict crosses the
    // boundary as a JSON file Swift writes, the plugin source plus a small
    // generated wrapper snippet (which decodes it, calls `functionName`,
    // and JSON-encodes the return value) run together as one
    // PyRun_SimpleString, and Swift reads the result back from a second
    // JSON file. Slower and more roundabout than a direct PyObject call,
    // but has no new C API surface to get wrong blind.
    public static func callFunction(scriptPath: String, functionName: String, argumentsJSON: [String: Any]) -> String? {
        guard start() else {
            return nil
        }
        guard let source = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
            return nil
        }
        let tempDir = FileManager.default.temporaryDirectory
        let inputURL = tempDir.appendingPathComponent("sg_plugin_in_\(UUID().uuidString).json")
        let outputURL = tempDir.appendingPathComponent("sg_plugin_out_\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard let inputData = try? JSONSerialization.data(withJSONObject: argumentsJSON),
              (try? inputData.write(to: inputURL)) != nil else {
            return nil
        }

        // MARK: ViboGram - the two temp paths are ours (UUID-named, under
        // the app's own temporary directory), never plugin- or
        // user-controlled, so embedding them as literal Python string
        // constants here doesn't need escaping the way `argumentsJSON`'s
        // actual content does (which is why that crosses via a JSON file
        // instead of being spliced into source text at all).
        let wrapper = """


        import json as _sg_json
        with open(\"\(inputURL.path)\", "r", encoding="utf-8") as _sg_f:
            _sg_args = _sg_json.load(_sg_f)
        _sg_result = \(functionName)(_sg_args)
        with open(\"\(outputURL.path)\", "w", encoding="utf-8") as _sg_f:
            _sg_json.dump({"result": _sg_result}, _sg_f)
        """

        let fullSource = source + wrapper
        let status = fullSource.withCString { PyRun_SimpleString($0) }
        guard status == 0 else {
            return nil
        }
        guard let outputData = try? Data(contentsOf: outputURL),
              let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let result = json["result"] as? String else {
            return nil
        }
        return result
    }

    // MARK: ViboGram - "Anime-ify" outgoing text, as an actual installed
    // plugin (not a hardcoded Swift feature) so the Settings toggle
    // exercises the real plugin-loading path (SGPythonRuntime.callFunction)
    // instead of simulating it. Idea + mechanism ported from Margelet's own
    // equivalent plugin; the word/kaomoji/particle lists here are our own.
    // Written out fresh every time it's needed (not just-if-missing) so a
    // future app update can ship a revised default without the user's
    // existing copy shadowing it -- if someone wants to keep editing their
    // own version instead, they should rename it.
    public static let builtinAnimefyPluginFilename = "animefy.vibo"

    @discardableResult
    public static func installBuiltinAnimefyPlugin() -> String {
        let destURL = SGPluginsStore.directory.appendingPathComponent(builtinAnimefyPluginFilename)
        try? builtinAnimefyPluginSource.write(to: destURL, atomically: true, encoding: .utf8)
        return builtinAnimefyPluginFilename
    }

    // MARK: ViboGram - ASCII-art plugin, Python half (see SGAsciiArtBridge
    // in SGPluginsUI for the Swift-side image decode/downsample). Idea +
    // mechanism (luminance-to-character ladder, darkest-to-lightest,
    // dark-theme invert) ported from Margelet's own equivalent plugin; the
    // character ladder here is our own choice.
    public static let builtinAsciiArtPluginFilename = "ascii_art.vibo"

    @discardableResult
    public static func installBuiltinAsciiArtPlugin() -> String {
        let destURL = SGPluginsStore.directory.appendingPathComponent(builtinAsciiArtPluginFilename)
        try? builtinAsciiArtPluginSource.write(to: destURL, atomically: true, encoding: .utf8)
        return builtinAsciiArtPluginFilename
    }
}

// MARK: ViboGram - plugin file storage. Plugins live in the app's own
// Documents directory (writable at runtime, unlike the read-only signed app
// bundle) so they survive relaunches and can be added/removed without a
// reinstall. One flat directory -- no manifest parsing or per-plugin
// subfolder yet, since there's no real plugin-loading API to consume a
// manifest for until BasePlugin/hooks exist.
//
// Extension: exteraGram's real plugin files use `.plugin` (confirmed against
// an actual installed plugin, gift_stats.plugin -- plain Python source
// despite the extension, per `file`: "Python script, Unicode text"). `.py`
// is also accepted for anything hand-written/not exteraGram-sourced.
public enum SGPluginsStore {
    // MARK: ViboGram - `.vibo` is our own extension (not exteraGram's
    // `.plugin`, not Margelet's zip-based `.marp`); `.plugin`/`.py` are
    // still accepted on import for anything brought over from elsewhere,
    // but new plugins (including both built-ins) are written as `.vibo`.
    private static let acceptedExtensions: Set<String> = ["vibo", "plugin", "py"]

    public static var directory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Plugins", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func installedPlugins() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.filter { acceptedExtensions.contains($0.pathExtension.lowercased()) }.map { $0.lastPathComponent }.sorted()
    }

    public static func path(for filename: String) -> String {
        return directory.appendingPathComponent(filename).path
    }

    // `sourceURL` is expected to already be a local file (either a
    // security-scoped Files-app URL the caller has already
    // started/stopped accessing, or a temp download destination) --
    // this function only copies, it doesn't fetch.
    @discardableResult
    public static func importPlugin(from sourceURL: URL, suggestedName: String? = nil) throws -> String {
        var filename = suggestedName ?? sourceURL.lastPathComponent
        if filename.isEmpty {
            filename = "plugin.vibo"
        }
        if !acceptedExtensions.contains((filename as NSString).pathExtension.lowercased()) {
            filename += ".vibo"
        }
        let destURL = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destURL)
        return filename
    }

    public static func deletePlugin(named filename: String) throws {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(filename))
    }
}

private let builtinAnimefyPluginSource = """
# ViboGram built-in plugin: "Anime-ify" outgoing text.
# Idea and mechanism ported from Margelet's own equivalent plugin
# (deterministic per-message/per-word pseudo-random rolls gating a word-swap
# dictionary, first-word stutter, trailing particle, kaomoji insertion, and
# a heart tail; links/mentions/commands are skipped; a length safety cutoff
# falls back to the untouched text). Word/kaomoji/particle lists below are
# our own, not the source plugin's content.

WORD_SWAPS = {
    "привет": "приветик",
    "пока": "покеда",
    "да": "агась",
    "нет": "не-а",
    "спасибо": "спасибки",
    "круто": "класн\\u00f3",
    "хорошо": "чудненько",
    "ладно": "лады",
}
KAOMOJI = ["(^_^)", "(-_-)", "(o_o)", "\\\\(^o^)/", "(^w^)"]
PARTICLES = ["нья", "десу", "кун", "тян"]
HEARTS = ["<3", "*", "~"]
LENGTH_CEILING = 4096


def _seed(text, salt):
    h = 5381
    for ch in text:
        h = (h * 131 + ord(ch)) & 0xFFFFFFF
    return (h + salt * 7919) & 0xFFFFFFF


def _roll(text, word_index, axis):
    return (_seed(text, word_index * 10 + axis) % 1000) / 1000.0


_THRESHOLDS = {
    "mild": {"swap": 0.15, "stutter": 0.08, "particle": 0.06, "kaomoji": 0.06, "hearts": 1},
    "normal": {"swap": 0.3, "stutter": 0.18, "particle": 0.15, "kaomoji": 0.15, "hearts": 2},
    "max": {"swap": 0.55, "stutter": 0.35, "particle": 0.3, "kaomoji": 0.3, "hearts": 3},
}


def _is_untouchable(word):
    lower = word.lower()
    if not lower:
        return True
    if lower[0] in "@#/":
        return True
    for marker in ("://", "t.me/", "www.", ".com", ".ru", ".org", ".\\u0440\\u0444"):
        if marker in lower:
            return True
    return False


def _split_punctuation(word):
    start, end = 0, len(word)
    while start < end and not word[start].isalnum():
        start += 1
    while end > start and not word[end - 1].isalnum():
        end -= 1
    return word[:start], word[start:end], word[end:]


def _match_case(original, replacement):
    if len(original) > 1 and original.isupper():
        return replacement.upper()
    if original[:1].isupper():
        return replacement[:1].upper() + replacement[1:]
    return replacement


def _stutter(word):
    if not word or not word[0].isalpha():
        return word
    return word[0] + "-" + word


def animefy(text, intensity="normal", options=None):
    if not text or not text.strip():
        return text
    if text.lstrip()[:1] == "/":
        return text
    options = options or {}
    bar = _THRESHOLDS.get(intensity, _THRESHOLDS["normal"])

    out = []
    word_index = 0
    is_first = True
    for word in text.split(" "):
        if not word:
            out.append(word)
            continue
        word_index += 1
        if _is_untouchable(word):
            out.append(word)
            is_first = False
            continue
        lead, core, trail = _split_punctuation(word)
        if core:
            lower = core.lower()
            if options.get("word_swaps", True) and lower in WORD_SWAPS and _roll(text, word_index, 1) < bar["swap"]:
                core = _match_case(core, WORD_SWAPS[lower])
            if options.get("stutter", True) and is_first and _roll(text, word_index, 2) < bar["stutter"]:
                core = _stutter(core)
            if options.get("particles", True) and _roll(text, word_index, 3) < bar["particle"]:
                pick = PARTICLES[int(_roll(text, word_index, 4) * len(PARTICLES)) % len(PARTICLES)]
                core = core + "-" + pick
        out.append(lead + core + trail)
        is_first = False
        if options.get("kaomoji", True) and _roll(text, word_index, 5) < bar["kaomoji"]:
            pick = KAOMOJI[int(_roll(text, word_index, 6) * len(KAOMOJI)) % len(KAOMOJI)]
            out.append(pick)

    result = " ".join(out)
    if options.get("hearts", True) and bar["hearts"] > 0:
        tail = [HEARTS[int(_roll(text, 100 + i, 8) * len(HEARTS)) % len(HEARTS)] for i in range(bar["hearts"])]
        if tail:
            result = result + " " + "".join(tail)
    if len(result) > LENGTH_CEILING:
        return text
    return result


def transform(args):
    \"\"\"Entry point called by SGPythonRuntime.callFunction: args is a dict
    with "text" (str) and optional "intensity"/"options" keys.\"\"\"
    return animefy(args.get("text", ""), args.get("intensity", "normal"), args.get("options"))
"""

private let builtinAsciiArtPluginSource = """
# ViboGram built-in plugin: ASCII art from a photo.
# Idea and mechanism ported from Margelet's own equivalent plugin
# (luminance-to-character ladder from darkest to lightest, optional invert
# for dark themes). Image decoding and aspect-corrected downsampling happen
# on the Swift side (SGAsciiArtBridge) -- our bundled stdlib has no image
# codec -- so this plugin only turns an already-computed brightness grid
# into the rendered art. The character ladder below is our own choice.

LADDER = "#%*+=-:. "


def render(grid, invert):
    ladder = LADDER[::-1] if invert else LADDER
    last = len(ladder) - 1
    lines = []
    for row in grid:
        line = []
        for luminance in row:
            luminance = max(0, min(255, int(luminance)))
            line.append(ladder[luminance * last // 255])
        lines.append("".join(line).rstrip())
    return "\\n".join(lines)


def transform(args):
    \"\"\"Entry point called by SGPythonRuntime.callFunction: args is a dict
    with "grid" (list of rows, each a list of 0-255 int luminance values)
    and optional "invert" (bool). Swift has already picked columns/rows and
    computed per-cell luminance -- this only maps brightness to characters.
    \"\"\"
    grid = args.get("grid") or []
    invert = bool(args.get("invert", False))
    if not grid:
        return ""
    art = render(grid, invert)
    return "```\\n" + art + "\\n```"
"""
