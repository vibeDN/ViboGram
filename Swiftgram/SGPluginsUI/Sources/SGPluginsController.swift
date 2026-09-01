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

private func sgPluginsEntries(installedPlugins: [String]) -> [SGPluginsEntry] {
    var entries: [SGPluginsEntry] = []
    let id = SGItemListCounter()

    entries.append(.header(id: id.count, section: .importActions, text: "Plugins are single .py files. This only proves a plugin's top-level code runs without crashing -- there is no BasePlugin/hook API to actually integrate with the app yet.", badge: nil))
    entries.append(.action(id: id.count, section: .importActions, actionType: .importFromFile, text: "Import from Files…", kind: .generic))
    entries.append(.action(id: id.count, section: .importActions, actionType: .importFromURL, text: "Import from URL…", kind: .generic))

    if installedPlugins.isEmpty {
        entries.append(.notice(id: id.count, section: .installed, text: "No plugins installed yet."))
    } else {
        for filename in installedPlugins {
            entries.append(.action(id: id.count, section: .installed, actionType: .plugin(filename: filename), text: filename, kind: .generic))
        }
    }

    return entries
}

public func sgPluginsController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    var pushControllerImpl: ((ViewController) -> Void)?

    let installedPluginsPromise = ValuePromise<[String]>(SGPluginsStore.installedPlugins(), ignoreRepeated: false)
    func refreshInstalledPlugins() {
        installedPluginsPromise.set(SGPluginsStore.installedPlugins())
    }

    func showResult(_ text: String, presentationData: PresentationData) {
        presentControllerImpl?(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return false }
        ), nil)
    }

    func runPlugin(named filename: String, presentationData: PresentationData) {
        let result = SGPythonRuntime.run(fileAt: SGPluginsStore.path(for: filename))
        showResult(result, presentationData: presentationData)
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
        let actionSheet = ActionSheetController(presentationData: presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: "Run", color: .accent, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    runPlugin(named: filename, presentationData: presentationData)
                }),
                ActionSheetButtonItem(title: "Delete", color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    deletePlugin(named: filename, presentationData: presentationData)
                }),
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }),
            ]),
        ])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
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
