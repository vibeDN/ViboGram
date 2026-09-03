load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "SGPluginsUI",
    module_name = "SGPluginsUI",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//Swiftgram/SGItemListUI:SGItemListUI",
        "//Swiftgram/SGLogging:SGLogging",
        "//Swiftgram/SGPython:SGPython",
        "//submodules/AccountContext:AccountContext",
        "//submodules/Display:Display",
        "//submodules/ItemListUI:ItemListUI",
        "//submodules/LegacyMediaPickerUI:LegacyMediaPickerUI",
        "//submodules/PresentationDataUtils:PresentationDataUtils",
        "//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
        "//submodules/TelegramPresentationData:TelegramPresentationData",
        "//submodules/UndoUI:UndoUI",
    ],
    visibility = [
        "//visibility:public",
    ],
)
