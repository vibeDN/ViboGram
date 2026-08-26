load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

# MARK: ViboGram - .session (Telethon/Pyrogram) file parsing, part of the
# "log in via an existing session file" long-term roadmap item. Deliberately
# scoped to parsing only -- see Sources/SGSessionImport.swift's header
# comment and docs/session-import.md for why the actual MTContext injection
# isn't attempted here.
swift_library(
    name = "SGSessionImport",
    module_name = "SGSessionImport",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/sqlcipher:sqlcipher",
    ],
    visibility = [
        "//visibility:public",
    ],
)
