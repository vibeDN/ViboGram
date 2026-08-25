import Foundation
import Python

// MARK: ViboGram - Tier 4 plugin system, Swift-side interpreter lifecycle
// wrapper around CPython's embedding C API (docs.python.org/3/c-api/init.html).
// Init sequence follows BeeWare Python-Apple-support's own documented Swift
// snippet (USAGE.md) exactly: PYTHONHOME -> a "python" resource folder
// containing lib/python3.14/ (the stdlib), PYTHONPATH -> an "app" resource
// folder (our own plugin scripts), then Py_Initialize().
//
// Restart-only activation (see README): the interpreter starts once per
// process and is never torn down/reinitialized. Py_Finalize() followed by
// Py_Initialize() again in the same process is documented as fragile in
// CPython itself (extension modules can't fully unload, global/thread state
// can leak) -- since plugins only take effect after a full app relaunch,
// that path is simply never needed here.
//
// NOT wired into app startup (or any other app-target BUILD file) yet.
// See docs/plugin-system-tier4.md for what's confirmed correct (this file's
// approach matches upstream's own documented pattern) vs. still genuinely
// unverified without a real build -- in particular, the stdlib/lib-dynload
// resource bundling this depends on (`isBundled` below) isn't wired into
// the app target yet, so `start()` will currently always fail gracefully.
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
        guard let pythonHome = Bundle.main.path(forResource: "python", ofType: nil) else {
            return false
        }
        let appPath = Bundle.main.path(forResource: "app", ofType: nil)

        setenv("PYTHONHOME", pythonHome, 1)
        if let appPath {
            setenv("PYTHONPATH", appPath, 1)
        }

        Py_Initialize()
        didStart = Py_IsInitialized() != 0
        return didStart
    }

    // Smoke test only -- not a real plugin-loading path. Intended to be
    // reached from a debug-only settings row (SGDebugUI), never from normal
    // app startup, until the resource bundling and lib-dynload
    // architecture-selection questions in docs/plugin-system-tier4.md are
    // resolved against a real device/simulator build.
    public static func runSmokeTest() -> String {
        guard start() else {
            return "SGPythonRuntime: not started (isBundled=\(isBundled) -- stdlib resource bundling isn't wired into the app target yet, see docs/plugin-system-tier4.md)"
        }
        let versionCString = Py_GetVersion()
        let version = versionCString.map { String(cString: $0) } ?? "<unknown>"
        let status = PyRun_SimpleString("import sys; print('SGPython smoke test OK, sys.path =', sys.path)")
        return "Py_GetVersion() = \(version); PyRun_SimpleString exit status = \(status) (0 = success; check device console log for the printed sys.path)"
    }
}
