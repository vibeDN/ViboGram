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
    # MARK: ViboGram - resources (data), not deps: rules_apple docs are
    # explicit that resource bundles attach to a library's `data` attribute,
    # propagating up to whatever app target eventually links this in. The
    # lib-dynload bundle is select()-ed per build config since device and
    # simulator ship different compiled .so files under the same in-bundle
    # name (see third-party/python/BUILD) -- only one can be present at once.
    data = [
        "//third-party/python:PythonStdlib",
    ] + select({
        "@build_bazel_rules_apple//apple:ios_arm64": ["//third-party/python:PythonLibDynloadDevice"],
        "//build-system:ios_sim_arm64": ["//third-party/python:PythonLibDynloadSimulator"],
    }),
    visibility = [
        "//visibility:public",
    ],
)
