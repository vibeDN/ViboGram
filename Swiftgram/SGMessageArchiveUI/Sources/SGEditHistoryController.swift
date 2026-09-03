import Foundation
import UIKit
import Display
import SwiftSignalKit
import Postbox
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import SGItemListUI
import SGMessageArchive

// MARK: ViboGram - the "История" (History) viewer the README flagged as
// missing: SGMessageArchive.recordEditVersion has been archiving prior text
// (and, as of this pass, prior media) on every edit for a while, but nothing
// ever read it back. This is the read side -- a plain read-only list of the
// message's previous versions, oldest first, each timestamped down to the
// second (edits can land seconds apart, and a minute-granularity timestamp
// isn't enough to tell two of them apart).

private enum SGEditHistorySection: Int32, SGItemListSection {
    case main
}

// MARK: ViboGram - only the previous-photo case is actually tappable-to-view
// here (see sgPresentPreviousImage below for why video/file aren't); the
// index identifies which archived version's blob to decode on tap.
private enum SGEditHistoryAction: Hashable {
    case viewImage(versionIndex: Int)
}

private typealias SGEditHistoryEntry = SGItemListUIEntry<SGEditHistorySection, AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGEditHistoryAction>

private func sgFormattedTimestamp(_ timestamp: Int32) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    // MARK: ViboGram - bugfix: this used to reuse stringForMediumDate, which
    // (like the rest of Telegram's own date formatting) only goes down to
    // minutes. Two edits landing in the same minute -- easy to do, e.g.
    // fixing a typo right after sending -- would then show identical
    // timestamps with no way to tell which version came first.
    formatter.setLocalizedDateFormatFromTemplate("yyyyMMddHHmmss")
    return formatter.string(from: date)
}

private func sgMediaChangeDescription(kind: String, summary: String?) -> String {
    switch kind {
    case "image":
        return "🖼 Photo replaced"
    case "video":
        return "🎥 Video replaced" + (summary.map { " (\($0))" } ?? "")
    default:
        return "📎 File replaced" + (summary.map { ": \($0)" } ?? "")
    }
}

private func sgEditHistoryEntries(versions: [SGMessageEditVersion]) -> [SGEditHistoryEntry] {
    var entries: [SGEditHistoryEntry] = []
    let id = SGItemListCounter()
    entries.append(.header(id: id.count, section: .main, text: "Previous versions of this message, oldest first. The current version is what's already on screen -- not repeated here.", badge: nil))
    for (index, version) in versions.enumerated() {
        let dateString = sgFormattedTimestamp(version.editTimestamp)
        let escapedText = version.text.replacingOccurrences(of: "*", with: "\\*")
        var noticeText = "**\(dateString)**"
        if !escapedText.isEmpty {
            noticeText += "\n\(escapedText)"
        }
        if let kind = version.previousMediaKind {
            noticeText += "\n\(sgMediaChangeDescription(kind: kind, summary: version.previousMediaSummary))"
        }
        entries.append(.notice(id: id.count, section: .main, text: noticeText))
        // MARK: ViboGram - photo preview only. Video/file previous versions
        // are described above but not made tappable: a full video player or
        // document previewer for an archived, possibly-stale resource
        // reference is a bigger, separate piece of UI than this pass covers
        // -- better to say plainly what changed than to half-build a preview
        // for it.
        if version.previousMediaKind == "image" {
            entries.append(.action(id: id.count, section: .main, actionType: .viewImage(versionIndex: index), text: "View this photo", kind: .generic))
        }
    }
    return entries
}

// MARK: ViboGram - decodes the PostboxEncoder blob AccountStateManagementUtils.swift
// wrote for this version and fetches its bytes through the normal MediaBox
// pipeline (same as any other image in the app -- redownloads from Telegram's
// CDN if it's since been evicted from the local cache, using the resource
// reference embedded in the decoded TelegramMediaImage itself).
private func sgPresentPreviousImage(context: AccountContext, from presentingController: ViewController, encoded: Data) {
    guard let image = PostboxDecoder(buffer: MemoryBuffer(data: encoded)).decodeRootObject() as? TelegramMediaImage,
          let largest = largestImageRepresentation(image.representations) else {
        return
    }
    let disposable = (context.engine.resources.data(resource: EngineMediaResource(largest.resource), incremental: true)
    |> take(1)
    |> deliverOnMainQueue).startStandalone(next: { data in
        guard data.isComplete, let fileData = try? Data(contentsOf: URL(fileURLWithPath: data.path)), let uiImage = UIImage(data: fileData) else {
            return
        }
        presentingController.present(SGEditHistoryImageViewController(image: uiImage), animated: true)
    })
    let _ = disposable
}

public func sgEditHistoryController(context: AccountContext, peerId: Int64, messageId: Int32, namespace: Int32) -> ViewController {
    let versions = SGMessageArchive.editHistory(peerId: peerId, messageId: messageId, namespace: namespace)

    var controllerRef: ItemListController?

    let arguments = SGItemListArguments<AnyHashable, AnyHashable, AnyHashable, AnyHashable, SGEditHistoryAction>(context: context, action: { actionType in
        switch actionType {
        case let .viewImage(versionIndex):
            guard versionIndex >= 0, versionIndex < versions.count, let encoded = versions[versionIndex].previousMediaEncoded, let controller = controllerRef else {
                return
            }
            sgPresentPreviousImage(context: context, from: controller, encoded: encoded)
        }
    })

    let signal = context.sharedContext.presentationData
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = sgEditHistoryEntries(versions: versions)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("История"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, ensureVisibleItemTag: nil, initialScrollToItem: nil)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    controllerRef = controller
    return controller
}

// MARK: ViboGram - minimal standalone full-screen image viewer, deliberately
// plain UIKit rather than reaching for Telegram's own gallery machinery
// (AvatarGalleryController etc.): those are built around a real peer/message
// identity for sharing, captions, forwarding and so on, none of which applies
// to a historical, possibly-orphaned archived photo -- forcing this into that
// machinery would either misrepresent what it is or require stubbing out most
// of its own functionality. Pinch-to-zoom via UIScrollView, tap the close
// button (top-left, safe-area aware) to dismiss.
private final class SGEditHistoryImageViewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private let closeButton = UIButton(type: .system)

    init(image: UIImage) {
        self.image = image
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        self.view.backgroundColor = .black

        self.imageView.image = self.image
        self.imageView.contentMode = .scaleAspectFit

        self.scrollView.delegate = self
        self.scrollView.minimumZoomScale = 1.0
        self.scrollView.maximumZoomScale = 4.0
        self.scrollView.showsHorizontalScrollIndicator = false
        self.scrollView.showsVerticalScrollIndicator = false
        self.scrollView.addSubview(self.imageView)
        self.view.addSubview(self.scrollView)

        self.closeButton.setTitle("✕", for: .normal)
        self.closeButton.setTitleColor(.white, for: .normal)
        self.closeButton.titleLabel?.font = .systemFont(ofSize: 22.0, weight: .semibold)
        self.closeButton.backgroundColor = UIColor(white: 0.0, alpha: 0.4)
        self.closeButton.layer.cornerRadius = 18.0
        self.closeButton.addTarget(self, action: #selector(self.closeTapped), for: .touchUpInside)
        self.view.addSubview(self.closeButton)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        self.scrollView.frame = self.view.bounds

        let imageSize = self.image.size
        let bounds = self.view.bounds
        if imageSize.width > 0.0, imageSize.height > 0.0, bounds.width > 0.0, bounds.height > 0.0 {
            let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
            let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            self.imageView.frame = CGRect(origin: .zero, size: fittedSize)
            self.scrollView.contentSize = fittedSize
            self.centerImageView()
        }

        let closeSize: CGFloat = 36.0
        self.closeButton.frame = CGRect(x: self.view.safeAreaInsets.left + 12.0, y: self.view.safeAreaInsets.top + 8.0, width: closeSize, height: closeSize)
    }

    private func centerImageView() {
        let boundsSize = self.scrollView.bounds.size
        var frame = self.imageView.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2.0 : 0.0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2.0 : 0.0
        self.imageView.frame = frame
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return self.imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        self.centerImageView()
    }

    @objc private func closeTapped() {
        self.dismiss(animated: true)
    }
}
