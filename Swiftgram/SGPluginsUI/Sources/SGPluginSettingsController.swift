import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import SGItemListUI
import SGPython

// MARK: ViboGram - plugin-declared settings screen. A plugin that defines a
// module-level `settings()` function (called with {} like `transform`, via
// the same callFunctionRich bridge) can describe its own settings UI as a
// JSON array of widgets -- the idea ported from exteraGram's
// create_settings()/Header/Switch/Selector/Text convention
// (plugins.exteragram.app/docs/plugin-settings), rewritten against what our
// one-shot JSON contract can actually support. Values read/write the exact
// same per-plugin state file vibo.get_setting/set_setting use (via
// SGPythonRuntime.readState/writeState), so a plugin's own `transform` sees
// whatever the user configures here.
//
// Deliberately NOT ported: exteraGram's free-text Input/EditText widgets.
// Those would need a new keyed text-input case in the shared
// SGItemListUIEntry enum (its existing `.searchInput` is a single
// un-keyed row, fine for a screen with exactly one search field, not for
// an arbitrary number of independent plugin-declared text settings) --
// that's a shared-framework change affecting every other screen built on
// it (SGSettingsController, SGDebugUI), not something to risk without
// being able to verify all three still render correctly on a real device.
// Header/Text/Switch/Selector cover a real settings screen already; Input
// can follow once there's a safe way to extend the shared entry type.

private enum SGPluginSettingsSection: Int32, SGItemListSection {
    case main
}

private enum SGPluginSettingWidget {
    case header(text: String)
    case text(text: String)
    case toggle(key: String, text: String, defaultValue: Bool)
    case selector(key: String, text: String, items: [String], defaultIndex: Int)
}

private typealias SGPluginSettingsEntry = SGItemListUIEntry<SGPluginSettingsSection, String, AnyHashable, String, AnyHashable, AnyHashable>

// MARK: ViboGram - a plugin's `settings()` is arbitrary, untrusted JSON --
// one malformed row (missing key, wrong type) is skipped, not a reason to
// blank the whole screen or crash.
private func parseSettingWidgets(_ raw: Any?) -> [SGPluginSettingWidget] {
    guard let array = raw as? [[String: Any]] else {
        return []
    }
    var widgets: [SGPluginSettingWidget] = []
    for dict in array {
        guard let type = dict["type"] as? String else { continue }
        switch type {
        case "header":
            guard let text = dict["text"] as? String else { continue }
            widgets.append(.header(text: text))
        case "text":
            guard let text = dict["text"] as? String else { continue }
            widgets.append(.text(text: text))
        case "switch", "toggle":
            guard let key = dict["key"] as? String, let text = dict["text"] as? String else { continue }
            widgets.append(.toggle(key: key, text: text, defaultValue: dict["default"] as? Bool ?? false))
        case "selector":
            guard let key = dict["key"] as? String, let text = dict["text"] as? String,
                  let items = dict["items"] as? [String], !items.isEmpty else { continue }
            widgets.append(.selector(key: key, text: text, items: items, defaultIndex: dict["default"] as? Int ?? 0))
        default:
            continue
        }
    }
    return widgets
}

private func sgPluginSettingsEntries(widgets: [SGPluginSettingWidget], state: [String: Any], errorText: String?) -> [SGPluginSettingsEntry] {
    if let errorText {
        let id = SGItemListCounter()
        return [
            .header(id: id.count, section: .main, text: "settings() raised an exception", badge: nil),
            .notice(id: id.count, section: .main, text: errorText),
        ]
    }
    var entries: [SGPluginSettingsEntry] = []
    let id = SGItemListCounter()
    for widget in widgets {
        switch widget {
        case let .header(text):
            entries.append(.header(id: id.count, section: .main, text: text, badge: nil))
        case let .text(text):
            entries.append(.notice(id: id.count, section: .main, text: text))
        case let .toggle(key, text, defaultValue):
            let value = (state[key] as? Bool) ?? defaultValue
            entries.append(.toggle(id: id.count, section: .main, settingName: key, value: value, text: text, enabled: true))
        case let .selector(key, text, items, defaultIndex):
            let rawIndex = (state[key] as? Int) ?? defaultIndex
            let index = (0..<items.count).contains(rawIndex) ? rawIndex : 0
            entries.append(.oneFromManySelector(id: id.count, section: .main, settingName: key, text: text, value: items[index], enabled: true))
        }
    }
    if entries.isEmpty {
        entries.append(.notice(id: id.count, section: .main, text: "This plugin's settings() returned nothing usable."))
    }
    return entries
}

// MARK: ViboGram - cheap static check (no interpreter start) so
// SGPluginsController only offers "Settings..." for plugins that plausibly
// define one. A false positive (the substring appears in a comment/string
// but there's no real settings() function) just means the button shows and
// the resulting screen says "returned nothing usable" -- never a crash.
public func sgPluginDeclaresSettings(filename: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: SGPluginsStore.path(for: filename)),
          let source = String(data: data, encoding: .utf8) else {
        return false
    }
    return source.contains("def settings(")
}

public func sgPluginSettingsController(context: AccountContext, pluginFilename: String) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?

    let settingsCallResult = SGPythonRuntime.callFunctionRich(scriptPath: SGPluginsStore.path(for: pluginFilename), functionName: "settings", argumentsJSON: [:])
    let widgets = parseSettingWidgets(settingsCallResult?.rawResult)
    // MARK: ViboGram - show the plugin's own traceback if settings() raised,
    // instead of falling through to the generic "returned nothing usable"
    // (which is indistinguishable from "this plugin just has no settings
    // worth showing" -- an author debugging their own settings() needs to
    // see which one actually happened).
    let settingsErrorText = settingsCallResult?.errorText
    let statePromise = ValuePromise<[String: Any]>(SGPythonRuntime.readState(for: pluginFilename), ignoreRepeated: false)
    func refreshState() {
        statePromise.set(SGPythonRuntime.readState(for: pluginFilename))
    }

    func presentSelectorPicker(key: String, text: String, items: [String]) {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var buttons: [ActionSheetItem] = []
        for (index, item) in items.enumerated() {
            buttons.append(ActionSheetButtonItem(title: item, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                SGPythonRuntime.writeState(for: pluginFilename, merging: [key: index])
                refreshState()
            }))
        }
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: buttons),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                }),
            ]),
        ])
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }

    let arguments = SGItemListArguments<String, AnyHashable, String, AnyHashable, AnyHashable>(
        context: context,
        setBoolValue: { key, value in
            SGPythonRuntime.writeState(for: pluginFilename, merging: [key: value])
            refreshState()
        },
        setOneFromManyValue: { key in
            guard case let .selector(_, text, items, _)? = widgets.first(where: { widget in
                if case let .selector(widgetKey, _, _, _) = widget { return widgetKey == key }
                return false
            }) else { return }
            presentSelectorPicker(key: key, text: text, items: items)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgPluginSettingsEntries(widgets: widgets, state: state, errorText: settingsErrorText)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(pluginFilename), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}
