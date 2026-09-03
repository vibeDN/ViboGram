load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGBadgesUI",
    module_name = "SGBadgesUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGBadges:SGBadges",
    ],
    visibility = [
        "//visibility:public",
    ],
)
