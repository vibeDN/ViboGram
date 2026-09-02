import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import UndoUI
import SGItemListUI
import SGPython

// MARK: ViboGram - plugin-declared settings screen. A plugin that defines a
// module-level `settings(args)` function (called the same way `transform`
// is) can describe its own settings UI as a JSON array of widgets -- the
// idea ported from exteraGram's create_settings()/Header/Switch/Selector/
// Text convention (plugins.exteragram.app/docs/plugin-settings), rewritten
// against what our one-shot JSON contract can actually support. Switch/
// Selector values round-trip through the exact same per-plugin state file
// vibo.get_setting/set_setting use (via SGPythonRuntime.readState/
// writeState), so a plugin's own `transform` sees whatever the user
// configures here.
//
// `action` rows are this screen's answer to "can a plugin have real
// interactive UI" -- there's no live channel back into a running script
// (PyRun_SimpleString runs once, to completion), so a button can't hold a
// Python callback the way exteraGram's Java-bridged BasePlugin can.
// Instead, tapping one makes a fresh, short callFunctionRich call to a
// plugin-defined `on_action(args)` (args = {"id": <the tapped row's id>}),
// same primitive as everything else here -- request/response, not a live
// connection. `on_action` gets the full `vibo` host object like any other
// call (get_setting/set_setting/toast/alert/...), and the whole screen
// (widgets AND state) is re-fetched after it returns, so `settings()`
// itself can change what's shown next (hide a "Start" row, show a "Stop"
// row) as a side effect of the action that just ran. This is a
// discrete-step/re-render pattern, not real-time interactivity -- no
// animations, no continuously-updating rows, nothing that needs a
// callback while the screen is just sitting there.
//
// Deliberately NOT ported: exteraGram's free-text Input/EditText widgets.
// Those would need a new keyed text-input case in the shared
// SGItemListUIEntry enum (its existing `.searchInput` is a single
// un-keyed row, fine for a screen with exactly one search field, not for
// an arbitrary number of independent plugin-declared text settings) --
// that's a shared-framework change affecting every other screen built on
// it (SGSettingsController, SGDebugUI), not something to risk without
// being able to verify all three still render correctly on a real device.

private enum SGPluginSettingsSection: Int32, SGItemListSection {
    case main
}

private enum SGPluginSettingWidget {
    case header(text: String)
    case text(text: String)
    case toggle(key: String, text: String, defaultValue: Bool)
    case selector(key: String, text: String, items: [String], defaultIndex: Int)
    case action(actionId: String, text: String, destructive: Bool)
}

private typealias SGPluginSettingsEntry = SGItemListUIEntry<SGPluginSettingsSection, String, AnyHashable, String, AnyHashable, String>

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
        case "action":
            guard let actionId = dict["id"] as? String, let text = dict["text"] as? String else { continue }
            widgets.append(.action(actionId: actionId, text: text, destructive: dict["destructive"] as? Bool ?? false))
        default:
            continue
        }
    }
    return widgets
}

private func sgPluginSettingsEntries(widgets: [SGPluginSettingWidget], state: [String: Any], errorText: String?) -> [SGPluginSettingsEntry] {
    let counter = SGItemListCounter()
    if let errorText {
        return [
            .header(id: counter.count, section: .main, text: "This raised an exception", badge: nil),
            .notice(id: counter.count, section: .main, text: errorText),
        ]
    }
    var entries: [SGPluginSettingsEntry] = []
    for widget in widgets {
        switch widget {
        case let .header(text):
            entries.append(.header(id: counter.count, section: .main, text: text, badge: nil))
        case let .text(text):
            entries.append(.notice(id: counter.count, section: .main, text: text))
        case let .toggle(key, text, defaultValue):
            let value = (state[key] as? Bool) ?? defaultValue
            entries.append(.toggle(id: counter.count, section: .main, settingName: key, value: value, text: text, enabled: true))
        case let .selector(key, text, items, defaultIndex):
            let rawIndex = (state[key] as? Int) ?? defaultIndex
            let index = (0..<items.count).contains(rawIndex) ? rawIndex : 0
            entries.append(.oneFromManySelector(id: counter.count, section: .main, settingName: key, text: text, value: items[index], enabled: true))
        case let .action(actionId, text, destructive):
            entries.append(.action(id: counter.count, section: .main, actionType: actionId, text: text, kind: destructive ? .destructive : .generic))
        }
    }
    if entries.isEmpty {
        entries.append(.notice(id: counter.count, section: .main, text: "This plugin's settings() returned nothing usable."))
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

private struct SGPluginScreenState {
    var widgets: [SGPluginSettingWidget]
    var state: [String: Any]
    var errorText: String?
}

public func sgPluginSettingsController(context: AccountContext, pluginFilename: String) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    let scriptPath = SGPluginsStore.path(for: pluginFilename)

    func fetchScreenState() -> SGPluginScreenState {
        let result = SGPythonRuntime.callFunctionRich(scriptPath: scriptPath, functionName: "settings", argumentsJSON: [:])
        return SGPluginScreenState(
            widgets: parseSettingWidgets(result?.rawResult),
            state: SGPythonRuntime.readState(for: pluginFilename),
            errorText: result?.errorText
        )
    }

    // MARK: ViboGram - `latest` is kept alongside the promise (not just
    // inside it) so the interaction closures below, which run synchronously
    // at tap time outside the signal pipeline, always have the latest
    // widgets to look up against -- e.g. which items a tapped selector's
    // key belongs to. Plain Promise, not ValuePromise -- ValuePromise
    // requires T: Equatable, and SGPluginScreenState holds a [String: Any]
    // (from arbitrary plugin JSON), which Any can't conform to.
    var latest = fetchScreenState()
    let screenPromise = Promise<SGPluginScreenState>(latest)
    func refreshScreen() {
        latest = fetchScreenState()
        screenPromise.set(.single(latest))
    }

    func presentPluginEvents(_ events: [SGPythonRuntime.SGPluginCallEvent], presentationData: PresentationData) {
        for event in events where event.type == "alert" {
            let alert = UIAlertController(title: event.title, message: event.text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
            context.sharedContext.mainWindow?.presentNative(alert)
        }
        for event in events where event.type == "toast" || event.type == "log" {
            presentControllerImpl?(UndoOverlayController(
                presentationData: presentationData,
                content: event.title == "success" ? .succeed(text: event.text, timeout: nil, customUndoText: nil) : .info(title: nil, text: event.text, timeout: nil, customUndoText: nil),
                elevatedLayout: false,
                action: { _ in return false }
            ), nil)
        }
    }

    func presentError(_ text: String, presentationData: PresentationData) {
        let alert = UIAlertController(title: "Plugin error", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: presentationData.strings.Common_OK, style: .default))
        context.sharedContext.mainWindow?.presentNative(alert)
    }

    func presentSelectorPicker(key: String, items: [String], presentationData: PresentationData) {
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var buttons: [ActionSheetItem] = []
        for (index, item) in items.enumerated() {
            buttons.append(ActionSheetButtonItem(title: item, color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                SGPythonRuntime.writeState(for: pluginFilename, merging: [key: index])
                refreshScreen()
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

    func runPluginAction(actionId: String, presentationData: PresentationData) {
        guard let result = SGPythonRuntime.callFunctionRich(scriptPath: scriptPath, functionName: "on_action", argumentsJSON: ["id": actionId]) else {
            presentError("on_action failed to run -- make sure the plugin defines def on_action(args).", presentationData: presentationData)
            return
        }
        if let errorText = result.errorText {
            presentError(errorText, presentationData: presentationData)
        } else {
            presentPluginEvents(result.events, presentationData: presentationData)
        }
        refreshScreen()
    }

    let arguments = SGItemListArguments<String, AnyHashable, String, AnyHashable, String>(
        context: context,
        setBoolValue: { key, value in
            SGPythonRuntime.writeState(for: pluginFilename, merging: [key: value])
            refreshScreen()
        },
        setOneFromManyValue: { key in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            guard case let .selector(_, _, items, _)? = latest.widgets.first(where: { widget in
                if case let .selector(widgetKey, _, _, _) = widget { return widgetKey == key }
                return false
            }) else { return }
            presentSelectorPicker(key: key, items: items, presentationData: presentationData)
        },
        action: { actionId in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            runPluginAction(actionId: actionId, presentationData: presentationData)
        }
    )

    let signal = combineLatest(context.sharedContext.presentationData, screenPromise.get())
    |> map { presentationData, screen -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgPluginSettingsEntries(widgets: screen.widgets, state: screen.state, errorText: screen.errorText)
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
