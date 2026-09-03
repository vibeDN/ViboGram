import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import TelegramStringFormatting
import PresentationDataUtils
import ItemListUI
import AccountContext
import SGItemListUI
import SGMessageArchive

// MARK: ViboGram - the "История" (History) viewer the README flagged as
// missing: SGMessageArchive.recordEditVersion has been archiving prior text
// on every edit for a while, but nothing ever read it back. This is the
// read side -- a plain read-only list of the message's previous versions,
// oldest first, each timestamped with the moment it was edited away.

private enum SGEditHistorySection: Int32, SGItemListSection {
    case main
}

private typealias SGEditHistoryEntry = SGItemListUIEntry<SGEditHistorySection, AnyHashable, AnyHashable, AnyHashable, AnyHashable, AnyHashable>

private func sgEditHistoryEntries(versions: [SGMessageEditVersion], strings: PresentationStrings, dateTimeFormat: PresentationDateTimeFormat) -> [SGEditHistoryEntry] {
    var entries: [SGEditHistoryEntry] = []
    let id = SGItemListCounter()
    entries.append(.header(id: id.count, section: .main, text: "Previous versions of this message, oldest first. The current text is what's already on screen -- not repeated here.", badge: nil))
    for version in versions {
        let dateString = stringForMediumDate(timestamp: version.editTimestamp, strings: strings, dateTimeFormat: dateTimeFormat)
        let escapedText = version.text.replacingOccurrences(of: "*", with: "\\*")
        entries.append(.notice(id: id.count, section: .main, text: "**\(dateString)**\n\(escapedText)"))
    }
    return entries
}

public func sgEditHistoryController(context: AccountContext, peerId: Int64, messageId: Int32, namespace: Int32) -> ViewController {
    let versions = SGMessageArchive.editHistory(peerId: peerId, messageId: messageId, namespace: namespace)

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, AnyHashable>(context: context)

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgEditHistoryEntries(versions: versions, strings: presentationData.strings, dateTimeFormat: presentationData.dateTimeFormat)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("История"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    return ItemListController(context: context, state: signal)
}
