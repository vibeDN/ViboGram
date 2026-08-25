load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGMessageArchive",
    module_name = "SGMessageArchive",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGAppGroupIdentifier:SGAppGroupIdentifier",
        "//Swiftgram/SGLogging:SGLogging",
    ],
    visibility = [
        "//visibility:public",
    ],
)
