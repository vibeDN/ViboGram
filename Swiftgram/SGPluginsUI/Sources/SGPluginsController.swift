import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import UndoUI
import LegacyMediaPickerUI
import SGItemListUI
import SGPython

// MARK: ViboGram - Tier 4 plugin system. Minimal import/list/run/delete UI so
// plugins can actually be installed and smoke-tested end to end, ahead of
// any real BasePlugin/hook machinery (see docs/plugin-system-tier4.md).
// Reachable via Settings (a real row, not debug-gated) and via the
// "tg://sg/plugins" deep link for quick testing.

private enum SGPluginsControllerSection: Int32, SGItemListSection {
    case importActions
    case installed
}

private enum SGPluginsAction: Hashable {
    case importFromFile
    case importFromURL
    case plugin(filename: String)
}

private typealias SGPluginsEntry = SGItemListUIEntry<SGPluginsControllerSection, AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGPluginsAction>

// MARK: ViboGram - same cheap-static-check pattern as sgPluginDeclaresSettings
// and the `# vibo-hook: on_send` marker: a plugin opts into the
// "Run on Photo..." button by having this line anywhere in its file, no
// Python execution needed to check for it.
private func sgPluginNeedsImage(filename: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: SGPluginsStore.path(for: filename)),
          let source = String(data: data, encoding: .utf8) else {
        return false
    }
    return source.contains("# vibo-needs: image")
}

// MARK: ViboGram - friendly names in the plugin list instead of raw
// filenames, without executing the plugin: a plain top-level
// `__name__ = "..."` string constant (exteraGram's own convention --
// confirmed against a real installed .plugin file this session found
// declares exactly this) is read via a cheap line scan, no Python
// involved. Falls back to the filename itself when absent or malformed
// -- this is cosmetic only, never a reason to hide a plugin.
private func sgPluginDisplayName(filename: String) -> String {
    guard let data = FileManager.default.contents(atPath: SGPluginsStore.path(for: filename)),
          let source = String(data: data, encoding: .utf8) else {
        return filename
    }
    for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("__name__") else { continue }
        guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
        var value = String(trimmed[trimmed.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        if !value.isEmpty {
            return value
        }
    }
    return filename
}

private func sgPluginsEntries(installedPlugins: [String]) -> [SGPluginsEntry] {
    var entries: [SGPluginsEntry] = []
    let id = SGItemListCounter()

    entries.append(.header(id: id.count, section: .importActions, text: "Plugins are single .vibo files (.plugin/.py from elsewhere also import fine). This only proves a plugin's top-level code runs without crashing -- there is no BasePlugin/hook API to actually integrate with the app yet, so anything importing base_plugin/client_utils/etc. will fail immediately, and plugins reaching into Android/Java internals (org.telegram.*, java.*) can never work on iOS.", badge: nil))
    entries.append(.action(id: id.count, section: .importActions, actionType: .importFromFile, text: "Import from Files…", kind: .generic))
    entries.append(.action(id: id.count, section: .importActions, actionType: .importFromURL, text: "Import from URL…", kind: .generic))

    if installedPlugins.isEmpty {
        entries.append(.notice(id: id.count, section: .installed, text: "No plugins installed yet."))
    } else {
        for filename in installedPlugins {
            let displayName = sgPluginDisplayName(filename: filename)
            let text = displayName == filename ? filename : "\(displayName) (\(filename))"
            entries.append(.action(id: id.count, section: .installed, actionType: .plugin(filename: filename), text: text, kind: .generic))
        }
    }

    return entries
}

public func sgPluginsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    // MARK: ViboGram - seed the built-in example plugins so they're visible
    // here even if their own settings toggle (animefy) was never touched,
    // or there is no separate toggle at all (ascii-art). Re-written every
    // time the screen opens (not just-if-missing), matching
    // installBuiltinAnimefyPlugin's own reasoning: ships an updated default
    // without a stale copy silently shadowing it.
    SGPythonRuntime.installBuiltinAnimefyPlugin()
    SGPythonRuntime.installBuiltinAsciiArtPlugin()

    let installedPluginsPromise = ValuePromise<[String]>(SGPluginsStore.installedPlugins(), ignoreRepeated: false)
    func refreshInstalledPlugins() {
        installedPluginsPromise.set(SGPluginsStore.installedPlugins())
    }

    // MARK: ViboGram - `succeed` styling for `vibo.toast(text, style="success")`
    // (the rest -- "info", anything unrecognized -- stays the plain overlay
    // this already was), matching exteraGram's BulletinHelper distinguishing
    // show_info/show_success as separate calls; we fold it into one call
    // with a style argument instead of separate methods.
    func showResult(_ text: String, style: String = "info", presentationData: PresentationData) {
        let content: UndoOverlayContent = style == "success"
            ? .succeed(text: text, timeout: nil, customUndoText: nil)
            : .info(title: nil, text: text, timeout: nil, customUndoText: nil)
        presentControllerImpl?(UndoOverlayController(
            presentationData: presentationData,
            content: content,
            elevatedLayout: false,
            action: { _ in return false }
        ), nil)
    }

    // MARK: ViboGram - presents whatever a callFunctionRich call handed
    // back: any vibo.alert events first (they're the plugin explicitly
    // asking for a blocking-style dialog), then vibo.toast/vibo.log events
    // as overlay notices (log included -- there's no separate console-only
    // channel from this UI, so it gets the same treatment as toast), then
    // the actual return value if the plugin gave one.
    func presentCallResult(_ result: SGPythonRuntime.SGPluginCallResult, presentationData: PresentationData) {
        // MARK: ViboGram - this is the actual fix for docs/plugin-authoring.md's
        // "errors don't surface in the UI" gap: a raised exception used to
        // make the whole call return nil, so every caller showed "check
        // device console log" -- now the traceback rides home in the
        // result and gets shown directly. Checked first and returns early:
        // an error means nothing else in `result` (events, resultText) is
        // meaningful.
        if let errorText = result.errorText {
            let alert = UIAlertController(title: "Plugin error", message: errorText, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
            context.sharedContext.mainWindow?.presentNative(alert)
            return
        }
        for event in result.events where event.type == "alert" {
            let alert = UIAlertController(title: event.title, message: event.text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
            context.sharedContext.mainWindow?.presentNative(alert)
        }
        // MARK: ViboGram - vibo.share(text): the system share sheet, not
        // Telegram's own in-app chat-share -- lets a plugin hand its
        // output to AirDrop/Files/any other app, same primitive already
        // used for the plugin-source-file export (QrCodeScreen.swift is
        // the other precedent for presentNativeController + this
        // UIActivityViewController pattern in this codebase).
        for event in result.events where event.type == "share" {
            let activityController = UIActivityViewController(activityItems: [event.text], applicationActivities: nil)
            if let window = context.sharedContext.mainWindow {
                activityController.popoverPresentationController?.sourceView = window.hostView.containerView
                activityController.popoverPresentationController?.sourceRect = CGRect(origin: CGPoint(x: window.hostView.containerView.bounds.width / 2.0, y: window.hostView.containerView.bounds.height - 1.0), size: CGSize(width: 1.0, height: 1.0))
            }
            context.sharedContext.applicationBindings.presentNativeController(activityController)
        }
        for event in result.events where event.type == "toast" || event.type == "log" {
            showResult(event.text, style: event.title ?? "info", presentationData: presentationData)
        }
        if let resultText = result.resultText {
            showResult(resultText, presentationData: presentationData)
        } else if result.events.isEmpty {
            showResult("Ran successfully (no return value, no events).", presentationData: presentationData)
        }
    }

    func runPlugin(named filename: String, argumentsJSON: [String: Any] = [:], presentationData: PresentationData) {
        guard let result = SGPythonRuntime.callFunctionRich(scriptPath: SGPluginsStore.path(for: filename), functionName: "transform", argumentsJSON: argumentsJSON) else {
            showResult("Plugin failed to run -- check device console log for the traceback.", presentationData: presentationData)
            return
        }
        presentCallResult(result, presentationData: presentationData)
    }

    // MARK: ViboGram - closes a real gap: plain "Run" always calls
    // transform({}), so a plugin like word_count/text_cleaner that expects
    // args["text"] never gets anything meaningful to work with from this
    // screen alone. "text" is the de-facto convention every text-shaped
    // plugin here already uses (animefy, word_count, text_cleaner) --
    // unconditional on every plugin rather than marker-gated, since
    // prompting for text costs nothing and a plugin that ignores the key
    // just behaves like plain Run.
    func presentRunWithText(pluginFilename: String, presentationData: PresentationData) {
        let alert = UIAlertController(title: "Run with Text", message: "Passed as args[\"text\"].", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "Text"
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Run", style: .default, handler: { [weak alert] _ in
            let text = alert?.textFields?.first?.text ?? ""
            runPlugin(named: pluginFilename, argumentsJSON: ["text": text], presentationData: presentationData)
        }))
        context.sharedContext.mainWindow?.presentNative(alert)
    }

    func deletePlugin(named filename: String, presentationData: PresentationData) {
        do {
            try SGPluginsStore.deletePlugin(named: filename)
            refreshInstalledPlugins()
        } catch {
            showResult("Failed to delete \(filename): \(error.localizedDescription)", presentationData: presentationData)
        }
    }

    func presentPluginActions(filename: String, presentationData: PresentationData) {
        // MARK: ViboGram - forward-declared like presentControllerImpl/
        // pushControllerImpl above: the buttons below need a dismiss
        // closure before `actionSheet` itself exists, so they capture this
        // var (by reference, as any enclosing-scope var is) and it's given
        // its real implementation once actionSheet is actually created.
        var dismissActionSheet: (() -> Void)?

        var runButtons: [ActionSheetItem] = [
            ActionSheetButtonItem(title: "Run", color: .accent, action: {
                dismissActionSheet?()
                runPlugin(named: filename, presentationData: presentationData)
            }),
            ActionSheetButtonItem(title: "Run with Text…", color: .accent, action: {
                dismissActionSheet?()
                presentRunWithText(pluginFilename: filename, presentationData: presentationData)
            }),
        ]
        // MARK: ViboGram - any plugin declaring `# vibo-needs: image`
        // (see sgPluginNeedsImage) gets this, not just the ascii-art
        // built-in it was originally special-cased for.
        if sgPluginNeedsImage(filename: filename) {
            runButtons.append(ActionSheetButtonItem(title: "Run on Photo…", color: .accent, action: {
                dismissActionSheet?()
                presentImagePlugin(pluginFilename: filename, presentationData: presentationData)
            }))
        }
        // MARK: ViboGram - only offered when the file plausibly defines a
        // settings() function (see sgPluginDeclaresSettings) -- built-ins
        // don't, most imported plugins won't either, so this stays hidden
        // rather than cluttering every plugin's action sheet with a screen
        // that would just say "nothing usable".
        if sgPluginDeclaresSettings(filename: filename) {
            runButtons.append(ActionSheetButtonItem(title: "Settings…", color: .accent, action: {
                dismissActionSheet?()
                pushControllerImpl?(sgPluginSettingsController(context: context, pluginFilename: filename))
            }))
        }
        runButtons.append(ActionSheetButtonItem(title: "Delete", color: .destructive, action: {
            dismissActionSheet?()
            deletePlugin(named: filename, presentationData: presentationData)
        }))

        let actionSheet = ActionSheetController(presentationData: presentationData)
        dismissActionSheet = { [weak actionSheet] in
            actionSheet?.dismissAnimated()
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: runButtons),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }),
            ]),
        ])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }

    // MARK: ViboGram - generalized from an ascii_art-only special case: any
    // plugin whose file contains the first-line-or-anywhere marker
    // `# vibo-needs: image` gets this button, not just the one built-in.
    // The contract stays exactly what ascii_art already established --
    // Swift decodes the photo and computes a luminance grid (our bundled
    // Python has no image codec, so this half can never move into the
    // plugin), the plugin's transform({"grid":, "invert": false}) only
    // ever sees numbers -- not every possible image idea fits that shape,
    // but a real class of them do (any effect that reduces to "brightness
    // pattern per cell").
    func presentImagePlugin(pluginFilename: String, presentationData: PresentationData) {
        let picker = legacyICloudFilePicker(theme: presentationData.theme, mode: .import, documentTypes: ["public.image"], completion: { urls in
            guard let sourceURL = urls.first else { return }
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: sourceURL), let image = UIImage(data: data) else {
                showResult("Couldn't read that as an image.", presentationData: presentationData)
                return
            }
            guard let grid = SGAsciiArtBridge.brightnessGrid(from: image, requestedColumns: 40) else {
                showResult("Couldn't process that image.", presentationData: presentationData)
                return
            }
            let pluginPath = SGPluginsStore.path(for: pluginFilename)
            guard let result = SGPythonRuntime.callFunctionRich(scriptPath: pluginPath, functionName: "transform", argumentsJSON: [
                "grid": grid.values,
                "invert": false,
            ]) else {
                showResult("Plugin failed to run -- check device console log for the traceback.", presentationData: presentationData)
                return
            }
            presentCallResult(result, presentationData: presentationData)
        })
        presentControllerImpl?(picker, nil)
    }

    func presentImportFromURL(presentationData: PresentationData) {
        let alert = UIAlertController(title: "Import from URL", message: "Paste a direct download link to a .py plugin file.", preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "https://…/plugin.py"
            textField.keyboardType = .URL
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: "Import", style: .default, handler: { [weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let url = URL(string: text), let scheme = url.scheme, scheme == "http" || scheme == "https" else {
                showResult("Not a valid http(s) URL.", presentationData: presentationData)
                return
            }
            let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
                Queue.mainQueue().async {
                    guard let tempURL else {
                        showResult("Download failed: \(error?.localizedDescription ?? "unknown error")", presentationData: presentationData)
                        return
                    }
                    do {
                        let filename = try SGPluginsStore.importPlugin(from: tempURL, suggestedName: url.lastPathComponent)
                        refreshInstalledPlugins()
                        showResult("Imported \(filename).", presentationData: presentationData)
                    } catch {
                        showResult("Failed to save downloaded plugin: \(error.localizedDescription)", presentationData: presentationData)
                    }
                }
            }
            task.resume()
        }))
        // MARK: ViboGram - same pattern the existing "Custom Edited Label"
        // settings row uses (SGSettingsController.swift) for a plain
        // UIAlertController text-input prompt -- there's no Telegram-styled
        // equivalent with a text field wired up already.
        context.sharedContext.mainWindow?.presentNative(alert)
    }

    func presentImportFromFile(presentationData: PresentationData) {
        let picker = legacyICloudFilePicker(theme: presentationData.theme, mode: .import, documentTypes: ["public.python-script", "public.plain-text", "public.item"], completion: { urls in
            guard let sourceURL = urls.first else { return }
            let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let filename = try SGPluginsStore.importPlugin(from: sourceURL)
                refreshInstalledPlugins()
                showResult("Imported \(filename).", presentationData: presentationData)
            } catch {
                showResult("Failed to import: \(error.localizedDescription)", presentationData: presentationData)
            }
        })
        presentControllerImpl?(picker, nil)
    }

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGPluginsAction>(context: context, action: { actionType in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch actionType {
        case .importFromFile:
            presentImportFromFile(presentationData: presentationData)
        case .importFromURL:
            presentImportFromURL(presentationData: presentationData)
        case let .plugin(filename):
            presentPluginActions(filename: filename, presentationData: presentationData)
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, installedPluginsPromise.get())
    |> map { presentationData, installedPlugins -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgPluginsEntries(installedPlugins: installedPlugins)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Plugins"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    let _ = pushControllerImpl

    return controller
}
