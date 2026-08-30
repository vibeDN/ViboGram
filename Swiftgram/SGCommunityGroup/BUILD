load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# MARK: ViboGram - shared "post/search/remove in the Margelet-interop public
# group" primitive backing SGBanner and SGGradient. See
# Sources/SGCommunityGroup.swift's header comment for the design.
swift_library(
    name = "SGCommunityGroup",
    module_name = "SGCommunityGroup",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/Postbox:Postbox",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramCore:TelegramCore",
        "//submodules/AccountContext:AccountContext",
    ],
    visibility = [
        "//visibility:public",
    ],
)
