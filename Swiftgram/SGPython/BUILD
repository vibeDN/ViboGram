load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# MARK: ViboGram - Tier 4 plugin system. NOT wired into any app target yet --
# see docs/plugin-system-tier4.md for what's confirmed vs. still unverified
# (in particular: stdlib/lib-dynload resource bundling into the app bundle,
# which needs a real Bazel build to get right, isn't done yet -- this module
# only wraps the C API/interpreter lifecycle calls themselves).
swift_library(
    name = "SGPython",
    module_name = "SGPython",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//third-party/python:Python",
    ],
    # MARK: ViboGram - bugfix: `data` on this library was meant to
    # auto-propagate these resource bundles to whatever app target links
    # SGPython in (rules_apple's documented resource-propagation mechanism),
    # but confirmed live (Python Smoke Test: "resource bundle not found,
    # isBundled=false") that it never actually reached the shipped .app.
    # Moved to an explicit `resources` entry on the app target itself
    # (Telegram/BUILD) instead of chasing why propagation didn't fire here --
    # removed from here so the same files aren't listed as inputs to two
    # different bundling paths (Bazel errors on duplicate bundle contents).
    visibility = [
        "//visibility:public",
    ],
)
