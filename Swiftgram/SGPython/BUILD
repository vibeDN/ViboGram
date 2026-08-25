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
    visibility = [
        "//visibility:public",
    ],
)
