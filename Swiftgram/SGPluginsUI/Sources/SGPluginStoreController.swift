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

// MARK: ViboGram - "Plugin Store": lists whatever .vibo/.plugin/.py files
// currently live in this repo's plugins/ folder on GitHub (via the public,
// unauthenticated Contents API -- no token needed, no server of our own to
// run) and lets a tap download + install one directly, same
// SGPluginsStore.importPlugin(from:) primitive "Import from URL..." already
// uses. Reachable from the main Plugins screen's action list.

private enum SGPluginStoreSection: Int32, SGItemListSection {
    case main
}

private enum SGPluginStoreAction: Hashable {
    case install(filename: String)
}

private typealias SGPluginStoreEntry = SGItemListUIEntry<SGPluginStoreSection, AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGPluginStoreAction>

// MARK: ViboGram - curated one-line descriptions for the store listing.
// GitHub's Contents API only gives filenames, not descriptions -- this is a
// small local catalog, not a fetched manifest. A plugin missing from this
// dict still lists fine (falls back to its bare filename), so adding a new
// file to plugins/ on GitHub doesn't require touching this dict to become
// installable, only to get a nicer one-liner here.
private let sgPluginStoreDescriptions: [String: String] = [
    "animefy.vibo": "Anime-ify outgoing messages (already built in -- here for reference/reinstall only).",
    "ascii_art.vibo": "Photo -> ASCII art (already built in -- here for reference/reinstall only).",
    "piratify.vibo": "Talk like a pirate on every message sent. Arr.",
    "gop_style.vibo": "Деревенский стиль. Поясни за шмот.",
    "vaporwave.vibo": "Ｆｕｌｌｗｉｄｔｈ ａｅｓｔｈｅｔｉｃ text converter.",
    "mock_case.vibo": "sPoNgEbOb MoCkInG cAsE converter.",
    "love_calculator.vibo": "Classic love-percentage calculator for two names.",
    "tarot.vibo": "One tarot card a day -- same card all day, changes at midnight.",
]

private struct SGPluginStoreListing: Equatable {
    let filename: String
    let downloadURL: String
}

private enum SGPluginStoreLoadState: Equatable {
    case loading
    case loaded([SGPluginStoreListing])
    case failed(String)
}

// MARK: ViboGram - unauthenticated GitHub Contents API call, no server of
// our own. Rate-limited to 60 req/hr per IP for anonymous callers -- fine
// for a manually-opened personal screen, not something polled/refreshed
// automatically.
private func fetchPluginStoreListing(completion: @escaping (SGPluginStoreLoadState) -> Void) {
    guard let url = URL(string: "https://api.github.com/repos/vibeDN/ViboGram/contents/plugins") else {
        completion(.failed("Bad store URL"))
        return
    }
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    let task = URLSession.shared.dataTask(with: request) { data, _, error in
        guard let data else {
            completion(.failed(error?.localizedDescription ?? "Network error"))
            return
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            completion(.failed("Unexpected response from GitHub (rate-limited?)"))
            return
        }
        let acceptedExtensions: Set<String> = ["vibo", "plugin", "py"]
        let listings: [SGPluginStoreListing] = array.compactMap { item in
            guard let name = item["name"] as? String,
                  let downloadURL = item["download_url"] as? String,
                  acceptedExtensions.contains((name as NSString).pathExtension.lowercased()) else {
                return nil
            }
            return SGPluginStoreListing(filename: name, downloadURL: downloadURL)
        }.sorted { $0.filename < $1.filename }
        completion(.loaded(listings))
    }
    task.resume()
}

private func sgPluginStoreEntries(state: SGPluginStoreLoadState) -> [SGPluginStoreEntry] {
    var entries: [SGPluginStoreEntry] = []
    let id = SGItemListCounter()
    entries.append(.header(id: id.count, section: .main, text: "Downloads straight from github.com/vibeDN/ViboGram/plugins. Installing doesn't strictly require a restart (hooks and the plugin list are both read fresh), but you'll get the prompt anyway for consistency with how other Swiftgram features handle this.", badge: nil))
    switch state {
    case .loading:
        entries.append(.notice(id: id.count, section: .main, text: "Loading…"))
    case let .failed(message):
        entries.append(.notice(id: id.count, section: .main, text: "Couldn't load the store: \(message)"))
    case let .loaded(listings):
        if listings.isEmpty {
            entries.append(.notice(id: id.count, section: .main, text: "No plugins found in the store right now."))
        } else {
            for listing in listings {
                let description = sgPluginStoreDescriptions[listing.filename]
                let text = description.map { "\(listing.filename) — \($0)" } ?? listing.filename
                entries.append(.action(id: id.count, section: .main, actionType: .install(filename: listing.filename), text: text, kind: .generic))
            }
        }
    }
    return entries
}

public func sgPluginStoreController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?

    // MARK: ViboGram - `latestListings` kept alongside the promise (same
    // pattern as SGPluginSettingsController.swift's `latest`) so install(),
    // which runs synchronously at tap time outside the signal pipeline, has
    // something to look the tapped filename's download URL up against
    // without trying to synchronously drain a Signal.
    var latestListings: [SGPluginStoreListing] = []
    let statePromise = Promise<SGPluginStoreLoadState>(.loading)
    fetchPluginStoreListing { result in
        Queue.mainQueue().async {
            if case let .loaded(listings) = result {
                latestListings = listings
            }
            statePromise.set(.single(result))
        }
    }

    func showResult(_ text: String, presentationData: PresentationData) {
        presentControllerImpl?(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: text, timeout: nil, customUndoText: nil),
            elevatedLayout: false,
            action: { _ in return false }
        ), nil)
    }

    // MARK: ViboGram - same "exit(0), let the user/OS relaunch" trick
    // SGSettingsController.swift's askForRestart already uses (there's no
    // real programmatic app-restart API on iOS) -- kept local to this file
    // rather than sharing that private closure across modules.
    func showRestartPrompt(installedName: String, presentationData: PresentationData) {
        presentControllerImpl?(UndoOverlayController(
            presentationData: presentationData,
            content: .info(title: nil, text: "\(installedName) installed. Restart recommended.", timeout: nil, customUndoText: "Restart Now"),
            elevatedLayout: false,
            action: { action in
                if action == .undo {
                    exit(0)
                }
                return true
            }
        ), nil)
    }

    func install(filename: String, presentationData: PresentationData) {
        guard let listing = latestListings.first(where: { $0.filename == filename }),
              let url = URL(string: listing.downloadURL) else {
            showResult("Couldn't find that plugin's download URL anymore -- try reopening the store.", presentationData: presentationData)
            return
        }
        let task = URLSession.shared.downloadTask(with: url) { tempURL, _, error in
            Queue.mainQueue().async {
                guard let tempURL else {
                    showResult("Download failed: \(error?.localizedDescription ?? "unknown error")", presentationData: presentationData)
                    return
                }
                do {
                    let savedName = try SGPluginsStore.importPlugin(from: tempURL, suggestedName: filename)
                    showRestartPrompt(installedName: savedName, presentationData: presentationData)
                } catch {
                    showResult("Failed to save downloaded plugin: \(error.localizedDescription)", presentationData: presentationData)
                }
            }
        }
        task.resume()
    }

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGPluginStoreAction>(context: context, action: { actionType in
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        switch actionType {
        case let .install(filename):
            install(filename: filename, presentationData: presentationData)
        }
    })

    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgPluginStoreEntries(state: state)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Plugin Store"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}
