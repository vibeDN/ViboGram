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
// UNVERIFIED: this file has never been compiled. The PyConfig/PyPreConfig
// struct-field and PyWideStringList C APIs are translated here from the
// (Objective-C) reference in briefcase-iOS-Xcode-template's main.m; the
// exact Swift-side spelling of pointer-to-struct-field arguments
// (`&config.home` etc.) and wide-string handling via Py_DecodeLocale needs
// to be confirmed against a real build before trusting it. See
// docs/plugin-system-tier4.md.
//
// Restart-only activation (see README): the interpreter starts once per
// process and is never torn down/reinitialized -- Py_Finalize() followed by
// Py_Initialize() again in the same process is documented as fragile in
// CPython itself. Since plugins only take effect after a full app relaunch,
// that path is never needed here.
public enum SGPythonRuntime {
    private static var didStart = false

    public static var isBundled: Bool {
        return Bundle.main.path(forResource: "python", ofType: nil) != nil
    }

    @discardableResult
    public static func start() -> Bool {
        if didStart {
            return true
        }
        guard let resourcePath = Bundle.main.resourcePath, isBundled else {
            return false
        }

        var preconfig = PyPreConfig()
        PyPreConfig_InitIsolatedConfig(&preconfig)
        preconfig.utf8_mode = 1
        preconfig.configure_locale = 1

        var preStatus = Py_PreInitialize(&preconfig)
        guard PyStatus_Exception(preStatus) == 0 else {
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
                return false
            }
            defer { PyMem_RawFree(wide) }
            let status = PyWideStringList_Append(&config.module_search_paths, wide)
            return PyStatus_Exception(status) == 0
        }

        let stdlibPath = resourcePath + "/python/lib/python3.14"
        let dynloadPath = stdlibPath + "/lib-dynload"
        let appPath = resourcePath + "/app"

        guard appendSearchPath(stdlibPath), appendSearchPath(dynloadPath), appendSearchPath(appPath) else {
            return false
        }

        if let homeWide = decode(resourcePath + "/python") {
            _ = PyConfig_SetString(&config, &config.home, homeWide)
            PyMem_RawFree(homeWide)
        }

        let initStatus = Py_InitializeFromConfig(&config)
        guard PyStatus_Exception(initStatus) == 0 else {
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
            return "SGPythonRuntime: start() failed (isBundled=\(isBundled) -- either the stdlib resource bundling isn't wired into the app target yet, or PyConfig init/module_search_paths setup failed; check device console log for the PyStatus error message CPython itself prints)"
        }
        let versionCString = Py_GetVersion()
        let version = versionCString.map { String(cString: $0) } ?? "<unknown>"
        let status = PyRun_SimpleString("import sys; print('SGPython smoke test OK, sys.path =', sys.path)")
        return "Py_GetVersion() = \(version); PyRun_SimpleString exit status = \(status) (0 = success; check device console log for the printed sys.path)"
    }
}
