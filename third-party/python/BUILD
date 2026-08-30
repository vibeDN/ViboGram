load(
    "@build_bazel_rules_apple//apple:apple.bzl",
    "apple_dynamic_xcframework_import",
)
# MARK: ViboGram - bugfix, caught by the first real Bazel analysis of this
# file: apple_resource_bundle lives in apple:resources.bzl, not apple.bzl
# (confirmed against the vendored rules_apple source itself,
# build-system/bazel-rules/rules_apple/apple/resources.bzl). Wrong load path
# is a bazel analysis-time failure, not something a Linux-side review could
# have caught -- this is exactly the kind of thing only a real build finds.
load(
    "@build_bazel_rules_apple//apple:resources.bzl",
    "apple_resource_bundle",
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
#
# MARK: ViboGram - this glob used to also sweep up a large amount of content
# that isn't part of the real XCFramework payload at all: BeeWare's
# distribution archive extracts a full (unpruned, ~53MB) copy of the
# pure-Python stdlib, host cross-compilation toolchain binaries, C headers
# for building extensions from source, and sysconfig/build metadata directly
# alongside the real per-platform Python.framework directories -- none of it
# declared in the xcframework's own Info.plist (which only lists
# `<Identifier>/Python.framework` per slice; verified by reading it
# directly). All of that has been removed (stdlib is vendored separately and
# pruned below; the rest is genuinely unneeded at runtime -- no on-device
# compilation is planned). `lib-dynload` (the compiled stdlib *extension*
# modules -- also not part of the declared xcframework payload, and also not
# something the linker needs) has been relocated to lib-dynload/ below and is
# bundled as a resource, not linked.
apple_dynamic_xcframework_import(
    name = "Python",
    xcframework_imports = glob(["Python.xcframework/**"]),
    visibility = [
        "//visibility:public",
    ],
)

# MARK: ViboGram - pure-Python stdlib (python.org's `Lib/`, pruned -- see
# docs/plugin-system-tier4.md). `apple_resource_bundle` preserves each
# resource's path relative to the package declaring it (this BUILD file, per
# rules_apple's own resources.md examples), so this can live right next to
# the vendored files regardless of which app target eventually consumes it --
# no cross-package glob-root ambiguity. Lands in the app bundle as
# `python.bundle/stdlib/lib/python3.14/...` (SGPythonRuntime.swift's search
# paths must match this exactly).
apple_resource_bundle(
    name = "PythonStdlib",
    bundle_name = "python",
    structured_resources = glob(["stdlib/**"]),
    visibility = ["//visibility:public"],
)

# MARK: ViboGram - compiled stdlib extension modules (`_socket.so`,
# `_ssl.so`, etc.), one directory per (platform, host-arch) pair -- these are
# NOT merged into a universal directory the way `Python.framework/Python`
# itself is, so the right one must be selected per build config. Only
# arm64 is vendored for the simulator slice (virtually all current Macs are
# Apple Silicon; Intel-Mac-simulator is treated as unsupported, per the
# already-made call in docs/plugin-system-tier4.md) -- there is deliberately
# no lib-x86_64 target here.
apple_resource_bundle(
    name = "PythonLibDynloadDevice",
    bundle_name = "python-lib-dynload",
    structured_resources = glob(["lib-dynload/ios-arm64/**"]),
    visibility = ["//visibility:public"],
)

apple_resource_bundle(
    name = "PythonLibDynloadSimulator",
    bundle_name = "python-lib-dynload",
    structured_resources = glob(["lib-dynload/ios-sim-arm64/**"]),
    visibility = ["//visibility:public"],
)
