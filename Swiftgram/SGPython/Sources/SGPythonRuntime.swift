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
}
