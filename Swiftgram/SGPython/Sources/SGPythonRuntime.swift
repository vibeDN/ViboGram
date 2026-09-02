import Foundation
import Python
import UIKit
import AudioToolbox

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

    // MARK: ViboGram - `vibo.play_sound(style)` preset name -> System
    // Sound Services id. See the "play_sound" event case in
    // callFunctionRich for what happens with a name not in this table.
    private static let presetSystemSoundIds: [String: SystemSoundID] = [
        "default": 1104, // "Tock" -- generic short UI click
        "tap": 1104,
        "success": 1025, // "Sent" -- ascending two-tone
        "alert": 1005, // "New Mail" -- distinct attention tone
    ]
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

    // MARK: ViboGram - one entry a plugin pushed via `vibo.log`/`vibo.toast`/
    // `vibo.alert` during its run (see callFunctionRich). Order-preserved
    // relative to each other, but all delivered only after the whole script
    // has finished -- there's no live channel back into a running
    // PyRun_SimpleString call, so these are recorded Python-side and
    // replayed by the caller once execution completes, not fired in real
    // time as the plugin executes.
    public struct SGPluginCallEvent {
        public let type: String // "log" | "toast" | "alert"
        public let text: String
        public let title: String?
    }

    public struct SGPluginCallResult {
        // The plugin's return value: the raw string if it returned one,
        // otherwise a pretty-printed JSON rendering of whatever JSON-safe
        // value it did return (dict/list/number/bool); nil if it returned
        // None/null. Meant for display.
        public let resultText: String?
        // The same return value, undecorated -- a String/NSNumber/Bool/
        // [Any]/[String: Any]/NSNull straight out of JSONSerialization, for
        // a caller that needs to consume structured data programmatically
        // (e.g. the plugin-settings screen's `settings()` convention)
        // instead of showing it to the user as text.
        public let rawResult: Any?
        public let events: [SGPluginCallEvent]
        // The plugin's own traceback text, if `transform`/`settings`/etc.
        // raised -- nil when it returned normally. A caller should check
        // this BEFORE reading resultText/rawResult (both are meaningless,
        // just None, on an error).
        public let errorText: String?
    }

    // MARK: ViboGram - callFunction's richer sibling: gives the plugin a
    // `vibo` host object (log/toast/alert -- queued during the run, applied
    // by the caller after; get_setting/set_setting -- backed by a small
    // per-plugin JSON file this function loads before running and writes
    // back after, so a plugin can remember state across calls) and lets
    // `transform` return any JSON-safe value, not just a string. Built on
    // the exact same primitive as callFunction (one PyRun_SimpleString, a
    // JSON file in, a JSON file out) -- the host object is plain Python
    // defined in the prelude, not a new C-API bridge, so this carries none
    // of the unverified-PyObject-API risk called out on callFunction.
    // Left as a separate function rather than folding into callFunction so
    // the already-proven animefy/ascii-art call sites are untouched.
    public static func callFunctionRich(scriptPath: String, functionName: String, argumentsJSON: [String: Any]) -> SGPluginCallResult? {
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

        // MARK: ViboGram - keyed by the plugin's own filename, not a
        // caller-supplied id, so two different call sites invoking the same
        // installed plugin share one state file (matches "the plugin
        // remembers its own state", not "this call site remembers state on
        // the plugin's behalf").
        let filename = (scriptPath as NSString).lastPathComponent
        let stateFilePath = SGPluginsStore.stateFilePath(for: filename)

        // MARK: ViboGram - read-only host info, computed once up front (no
        // live channel back into a running script, same reasoning as
        // get_setting's preload) so `vibo.get_clipboard()`/`device_info()`/
        // `list_plugins()`/`data_dir()` can return a real value the instant
        // they're called instead of only ever queuing something for later.
        let hostInfoFilePath = tempDir.appendingPathComponent("sg_plugin_host_\(UUID().uuidString).json").path
        defer {
            try? FileManager.default.removeItem(atPath: hostInfoFilePath)
        }
        let isDarkTheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark
        let hostInfo: [String: Any] = [
            "clipboard": UIPasteboard.general.string ?? NSNull(),
            "device_info": [
                "os_version": UIDevice.current.systemVersion,
                "device_model": UIDevice.current.model,
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "locale": Locale.current.identifier,
                "is_dark_theme": isDarkTheme,
            ],
            "plugins": SGPluginsStore.installedPlugins(),
            "data_dir": SGPluginsStore.dataDirectory(for: filename),
        ]
        guard let hostInfoData = try? JSONSerialization.data(withJSONObject: hostInfo),
              (try? hostInfoData.write(to: URL(fileURLWithPath: hostInfoFilePath))) != nil else {
            return nil
        }

        let prelude = """


        import json as _sg_json

        class _SgHost:
            def __init__(self, state, host_info):
                self._state = dict(state)
                self._host_info = dict(host_info)
                self.events = []

            def log(self, message):
                self.events.append({"type": "log", "text": str(message)})

            def toast(self, text, style="info"):
                self.events.append({"type": "toast", "text": str(text), "title": style})

            def alert(self, text, title=None):
                self.events.append({"type": "alert", "text": str(text), "title": title})

            def get_setting(self, key, default=None):
                return self._state.get(key, default)

            def set_setting(self, key, value):
                self._state[key] = value

            def get_clipboard(self):
                return self._host_info.get("clipboard")

            def set_clipboard(self, text):
                self.events.append({"type": "set_clipboard", "text": str(text)})

            def haptic(self, style="light"):
                self.events.append({"type": "haptic", "text": str(style)})

            def share(self, text):
                self.events.append({"type": "share", "text": str(text)})

            def open_url(self, url):
                self.events.append({"type": "open_url", "text": str(url)})

            def delete_this_message(self):
                # MARK: ViboGram - on_receive only. Deletes *locally*
                # (InteractiveMessagesDeletionType.forLocalPeer) -- the
                # other side's copy is untouched, no admin rights needed,
                # nothing sent over the wire. Silently ignored by any
                # caller that isn't on_receive (there's no "current
                # message" outside that context).
                self.events.append({"type": "delete_local_message", "text": "1"})

            def play_sound(self, style_or_path="default"):
                self.events.append({"type": "play_sound", "text": str(style_or_path)})

            def device_info(self):
                return self._host_info.get("device_info", {})

            def list_plugins(self):
                return self._host_info.get("plugins", [])

            def data_dir(self):
                return self._host_info.get("data_dir", "")

        try:
            with open(\"\(stateFilePath)\", "r", encoding="utf-8") as _sg_state_f:
                _sg_initial_state = _sg_json.load(_sg_state_f)
        except Exception:
            _sg_initial_state = {}

        try:
            with open(\"\(hostInfoFilePath)\", "r", encoding="utf-8") as _sg_host_f:
                _sg_host_info = _sg_json.load(_sg_host_f)
        except Exception:
            _sg_host_info = {}

        vibo = _SgHost(_sg_initial_state, _sg_host_info)
        """

        // MARK: ViboGram - the try/except is the actual fix for "errors
        // don't surface in the UI" (docs/plugin-authoring.md's own listed
        // gap): a raised exception used to make the whole
        // PyRun_SimpleString call fail (nonzero exit), so callFunctionRich
        // returned nil and every caller showed "check device console log"
        // -- not because that's the only way to see it, just because
        // nothing ever wrote it anywhere else. Catching it here means this
        // PyRun_SimpleString call still succeeds (exit 0), and the
        // traceback text rides home in the same output JSON everything
        // else already uses. A genuine syntax error in the plugin's own
        // top-level code still fails this call the old way -- it can't
        // reach this try/except at all, since the file doesn't parse into
        // running code in the first place.
        let wrapper = """


        import traceback as _sg_traceback
        try:
            with open(\"\(inputURL.path)\", "r", encoding="utf-8") as _sg_f:
                _sg_args = _sg_json.load(_sg_f)
            _sg_result = \(functionName)(_sg_args)
            _sg_error = None
        except Exception:
            _sg_result = None
            _sg_error = _sg_traceback.format_exc()
        with open(\"\(outputURL.path)\", "w", encoding="utf-8") as _sg_f:
            _sg_json.dump({"result": _sg_result, "events": vibo.events, "state": vibo._state, "error": _sg_error}, _sg_f)
        """

        // MARK: ViboGram - the explicit "\n" matters: prelude's Swift
        // multiline literal doesn't end in a trailing newline (its last
        // content line sits right against the closing """), so without
        // this, a plugin file whose own first line isn't blank gets glued
        // directly onto prelude's last line as one line of source --
        // confirmed by reproducing this exact concatenation in a standalone
        // Python interpreter before it could otherwise only have shown up
        // as an unexplained CI-only failure.
        let fullSource = prelude + "\n" + source + wrapper
        let status = fullSource.withCString { PyRun_SimpleString($0) }
        guard status == 0 else {
            return nil
        }
        guard let outputData = try? Data(contentsOf: outputURL),
              let json = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] else {
            return nil
        }

        if let state = json["state"] as? [String: Any], !state.isEmpty {
            try? JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: stateFilePath))
        }

        var events: [SGPluginCallEvent] = []
        if let rawEvents = json["events"] as? [[String: Any]] {
            for rawEvent in rawEvents {
                guard let type = rawEvent["type"] as? String, let text = rawEvent["text"] as? String else { continue }
                events.append(SGPluginCallEvent(type: type, text: text, title: rawEvent["title"] as? String))
            }
        }

        // MARK: ViboGram - clipboard/haptic are plain device-level side
        // effects with no UI to present (unlike toast/alert/share), so
        // they're applied right here regardless of caller -- an on_send
        // hook plugin gets these "for free" even though ChatControllerNode
        // never looks at .events itself. Must run on the same thread
        // callFunctionRich was called on; every current call site is
        // already main-thread (button taps, the message-send path), same
        // assumption UIAlertController presentation elsewhere in this
        // subsystem already makes.
        for event in events {
            switch event.type {
            case "set_clipboard":
                UIPasteboard.general.string = event.text
            case "haptic":
                switch event.text {
                case "success", "warning", "error":
                    let generator = UINotificationFeedbackGenerator()
                    let style: UINotificationFeedbackGenerator.FeedbackType = event.text == "success" ? .success : (event.text == "warning" ? .warning : .error)
                    generator.notificationOccurred(style)
                default:
                    let style: UIImpactFeedbackGenerator.FeedbackStyle = event.text == "heavy" ? .heavy : (event.text == "medium" ? .medium : .light)
                    UIImpactFeedbackGenerator(style: style).impactOccurred()
                }
            case "open_url":
                // MARK: ViboGram - http(s) only, same restriction
                // presentImportFromURL already applies to a pasted URL --
                // a plugin shouldn't be able to trigger an arbitrary
                // custom URL scheme (this app's own tg:// included) this
                // casually, only hand the user off to a normal web link.
                if let url = URL(string: event.text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                    UIApplication.shared.open(url)
                }
            case "play_sound":
                // MARK: ViboGram - a handful of named presets (System
                // Sound Services IDs -- undocumented-but-stable, widely
                // relied on across the iOS dev community for years; a
                // wrong/unregistered id is a documented no-op, never a
                // crash, so getting one wrong is a "no sound" bug at
                // worst) covers the common case with zero setup. Anything
                // else is tried as a local file path -- naturally reaches
                // for vibo.data_dir() since that's the one place a plugin
                // can be sure it already has a file it dropped there
                // itself (e.g. a small bundled clip, base64-decoded once
                // on first run). No path restriction to data_dir
                // specifically: a plugin already has unrestricted
                // Python-level file I/O, so gating *playback* alone adds
                // no real containment.
                if let systemSoundId = SGPythonRuntime.presetSystemSoundIds[event.text] {
                    AudioServicesPlaySystemSound(systemSoundId)
                } else if FileManager.default.fileExists(atPath: event.text) {
                    var soundId: SystemSoundID = 0
                    if AudioServicesCreateSystemSoundID(URL(fileURLWithPath: event.text) as CFURL, &soundId) == kAudioServicesNoError {
                        AudioServicesPlaySystemSoundWithCompletion(soundId) {
                            AudioServicesDisposeSystemSoundID(soundId)
                        }
                    }
                }
            default:
                break
            }
        }

        let rawResult = json["result"]
        let resultText: String?
        if let text = rawResult as? String {
            resultText = text
        } else if rawResult == nil || rawResult is NSNull {
            resultText = nil
        } else if let other = rawResult,
                  let data = try? JSONSerialization.data(withJSONObject: ["result": other], options: [.prettyPrinted]),
                  let text = String(data: data, encoding: .utf8) {
            resultText = text
        } else {
            resultText = nil
        }

        let errorText = json["error"] as? String
        return SGPluginCallResult(resultText: resultText, rawResult: rawResult, events: events, errorText: errorText)
    }

    // MARK: ViboGram - generic automatic hook: any installed plugin whose
    // FIRST LINE is exactly `# vibo-hook: on_send` gets its `transform`
    // called on every outgoing plain-text message, chained in
    // installedPlugins() (alphabetical) order -- each plugin sees the
    // previous one's output. A plugin that fails, isn't found, or returns
    // the text unchanged is silently skipped (same "never block sending"
    // philosophy as the animefy call site). Deliberately just a first-line
    // string check, not real manifest parsing or executing the file to ask
    // it -- cheap enough to run on every send with zero installed
    // hook-plugins, and needs no new C-API surface. Animefy itself doesn't
    // carry this marker (it runs via its own dedicated Settings toggle in
    // ChatControllerNode, with its own options dict) so it's never
    // double-applied here.
    //
    // The `# vibo-hook: <name>` marker is deliberately generic -- today
    // only "on_send" is actually consumed by the app, but the same
    // convention is meant to carry future hook names (e.g. on_receive) once
    // something calls a matching applyOn<X>Hooks, without inventing a new
    // declaration mechanism each time.
    public static func applyOnSendHooks(to text: String) -> String {
        var current = text
        for filename in SGPluginsStore.installedPlugins() {
            let path = SGPluginsStore.path(for: filename)
            guard let firstLine = firstLine(ofFileAt: path), firstLine.trimmingCharacters(in: .whitespaces) == "# vibo-hook: on_send" else {
                continue
            }
            guard let callResult = callFunctionRich(scriptPath: path, functionName: "transform", argumentsJSON: ["text": current]),
                  let transformed = callResult.resultText, transformed != current else {
                continue
            }
            current = transformed
        }
        return current
    }

    // MARK: ViboGram - the incoming-message counterpart to
    // applyOnSendHooks, deliberately much narrower: on_send can REPLACE
    // the text about to be sent (the app was already about to show
    // exactly that text, as what the user typed); on_receive cannot --
    // there's no safe way for a plugin to rewrite what a message says it
    // said, and doing so would be actively deceptive. So this only ever
    // calls each hook plugin's on_receive and discards the WHOLE
    // SGPluginCallResult, not just resultText -- including .events. Only
    // the callFunctionRich-internal auto-applies (set_clipboard/haptic/
    // open_url/play_sound -- the ones needing no presenting UI) actually
    // happen; vibo.toast/alert/log/share go nowhere from here, since
    // there is deliberately no presentControllerImpl-style UI surface
    // wired to this call site (a toast popping up over whatever screen
    // the user happens to be on, triggered by a message notification
    // pipeline for a possibly-different chat, needs real design, not a
    // blind reuse of the Plugins-screen pattern). Documented as a real
    // capability boundary, not a bug -- an on_receive plugin should lean
    // on play_sound/set_clipboard for its reaction.
    // Called from ApplicationContext.swift (TelegramUI layer, already on
    // the main queue, already past this app's own mute/lock/restriction
    // filtering for the exact same message) -- never from TelegramCore,
    // which this module's UIKit/AudioToolbox imports make off-limits
    // there (see CLAUDE.md's "TelegramCore never imports UIKit/Display").
    // A slow or hanging plugin here delays that one message's
    // notification, same trust boundary as any other installed plugin --
    // no new isolation was added to bound it.
    // MARK: ViboGram - return value is deliberately narrow: not the
    // SGPluginCallResult (see the type's own doc comment for why events
    // besides play_sound/set_clipboard/open_url/delete_local_message go
    // nowhere from here), just whether ANY hook plugin asked for THIS
    // message to be deleted locally via vibo.delete_this_message(). The
    // caller (ApplicationContext.swift) owns the actual
    // deleteMessagesInteractively(type: .forLocalPeer) call -- this
    // module has no AccountContext/TelegramEngine access at all, by
    // design (see SGPythonRuntime's own top-of-file doc comment: this is
    // an interpreter-lifecycle wrapper, not an account-aware layer).
    @discardableResult
    public static func applyOnReceiveHooks(text: String, peerTitle: String) -> Bool {
        var shouldDeleteLocally = false
        for filename in SGPluginsStore.installedPlugins() {
            let path = SGPluginsStore.path(for: filename)
            guard let firstLine = firstLine(ofFileAt: path), firstLine.trimmingCharacters(in: .whitespaces) == "# vibo-hook: on_receive" else {
                continue
            }
            guard let result = callFunctionRich(scriptPath: path, functionName: "on_receive", argumentsJSON: ["text": text, "peer_title": peerTitle]) else {
                continue
            }
            if result.events.contains(where: { $0.type == "delete_local_message" }) {
                shouldDeleteLocally = true
            }
        }
        return shouldDeleteLocally
    }

    private static func firstLine(ofFileAt path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
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

    // MARK: ViboGram - per-plugin persistent storage for the `vibo` host API
    // (get_setting/set_setting -- see callFunctionRich). One JSON file per
    // plugin filename, hidden alongside the plugins themselves; never
    // enumerated by installedPlugins() since it doesn't match
    // acceptedExtensions.
    private static var stateDirectory: URL {
        let dir = directory.appendingPathComponent(".state", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func stateFilePath(for filename: String) -> String {
        return stateDirectory.appendingPathComponent(filename + ".json").path
    }

    // MARK: ViboGram - plain Swift read/merge/write against the exact same
    // file `vibo.get_setting`/`set_setting` use -- for the plugin-settings
    // screen (SGPluginSettingsController) to read/change a value without
    // spinning up the interpreter for something as simple as a toggle flip.
    // A plugin's own `transform` still sees changes made this way, since
    // both paths read/write the identical file.
    public static func readState(for filename: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: stateFilePath(for: filename)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    @discardableResult
    public static func writeState(for filename: String, merging updates: [String: Any]) -> Bool {
        var state = readState(for: filename)
        for (key, value) in updates {
            state[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: state) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: stateFilePath(for: filename)))) != nil
    }

    // MARK: ViboGram - a whole sandboxed directory per plugin (`vibo.data_dir()`),
    // not just the single JSON blob get_setting/set_setting gives -- for
    // anything a plugin wants to store as real files (its own bigger JSON
    // documents, generated text, whatever), not just small key/value state.
    // One subfolder per plugin filename under a hidden `.data` directory,
    // same "hidden alongside the plugins, never enumerated as one" pattern
    // as stateDirectory.
    private static var dataRootDirectory: URL {
        let dir = directory.appendingPathComponent(".data", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public static func dataDirectory(for filename: String) -> String {
        let dir = dataRootDirectory.appendingPathComponent(filename, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
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

__name__ = "Anime-ify"

WORD_SWAPS = {
    "привет": "приветик",
    "пока": "покеда",
    "да": "агась",
    "нет": "не-а",
    "спасибо": "спасибки",
    "круто": "класн\\u00f3",
    "хорошо": "чудненько",
    "ладно": "лады",
    "мило": "мимими",
    "здравствуй": "драсьте",
    "смешно": "лолич",
    "красиво": "кавайно",
    "супер": "сюпер",
    "прости": "прастити",
    "хочу": "хочухочу",
    "люблю": "лаву",
    "странно": "стрёмненько",
    "устал": "у-тю-тюмс",
}
# MARK: ViboGram - "больше няшности" per explicit user request: bigger
# kaomoji/particle/heart pools and (see _THRESHOLDS below) higher default
# roll chances, so the built-in actually reads as more cutesy day to day,
# not just occasionally.
KAOMOJI = [
    "(^_^)", "(-_-)", "(o_o)", "\\\\(^o^)/", "(^w^)",
    "(=^-ω-^=)", "(◕‿◕)", "(´｡• ω •｡`)",
    "(*≧ω≦*)", "UwU", "＼(≡ △ ≡)／",
]
PARTICLES = ["нья", "десу", "кун", "тян", "ня", "мяу", "чан", "нэ"]
HEARTS = ["<3", "♡", "💕", "💞", "✨", "☆", "~"]
LENGTH_CEILING = 4096


def _seed(text, salt):
    h = 5381
    for ch in text:
        h = (h * 131 + ord(ch)) & 0xFFFFFFF
    return (h + salt * 7919) & 0xFFFFFFF


def _roll(text, word_index, axis):
    return (_seed(text, word_index * 10 + axis) % 1000) / 1000.0


_THRESHOLDS = {
    "mild": {"swap": 0.22, "stutter": 0.12, "particle": 0.10, "kaomoji": 0.10, "hearts": 1},
    "normal": {"swap": 0.42, "stutter": 0.25, "particle": 0.22, "kaomoji": 0.22, "hearts": 3},
    "max": {"swap": 0.7, "stutter": 0.45, "particle": 0.4, "kaomoji": 0.4, "hearts": 4},
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
# vibo-needs: image

__name__ = "ASCII Art"

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
