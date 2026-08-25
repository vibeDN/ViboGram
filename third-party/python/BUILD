load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_dynamic_xcframework_import",
)

# MARK: ViboGram - Tier 4 plugin system. Vendored from BeeWare's
# Python-Apple-support (github.com/beeware/Python-Apple-support), release
# 3.14-b10, iOS artifact only (device arm64 + simulator arm64/x86_64 slices).
# CPython is a pure bytecode interpreter (no JIT), so this needs no special
# entitlements -- see docs.python.org/3/using/ios.html, CPython iOS is an
# officially supported (Tier 3) platform as of this release line. The
# framework ships its own Headers/module.modulemap (module "Python"), so no
# hand-written bridging header is needed -- `import Python` works directly
# from Swift once this is a swift_library dep.
apple_dynamic_xcframework_import(
    name = "Python",
    xcframework_imports = glob(["Python.xcframework/**"]),
    visibility = [
        "//visibility:public",
    ],
)
