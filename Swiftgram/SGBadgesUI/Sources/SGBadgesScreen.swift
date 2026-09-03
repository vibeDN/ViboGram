import Foundation
import UIKit
import SGBadges

// MARK: ViboGram - the "Badges" screen: a big spinnable preview of the
// peer's currently-selected badge (SGBadgeSpinView, real image if img_url
// is set, plain colored square otherwise) plus a row of thumbnails for
// their other badges. On the OWN profile, an Equip button opens a
// pre-filled GitHub Issue (SGBadges.equipIssueURL) requesting that badge
// become the one shown everywhere -- see badge_sync.py for why this can't
// just be a local toggle. Plain UIKit modal, same reasoning as
// SGEditHistoryImageViewController earlier: this isn't tied to a real
// peer/message identity the way Telegram's own gallery/profile machinery
// expects, so building it on top of that would misrepresent what it is.
public final class SGBadgesScreen: UIViewController {
    private let peerId: Int64
    private let isOwnProfile: Bool
    private let badges: [SGBadge]
    private var selectedIndex: Int = 0

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let aboutLabel = UILabel()
    private let spinView = SGBadgeSpinView()
    private let equipButton = UIButton(type: .system)
    private let emptyLabel = UILabel()
    private let thumbnailScrollView = UIScrollView()
    private let thumbnailStack = UIStackView()
    private var thumbnailButtons: [UIButton] = []
    private var imageLoadTask: URLSessionDataTask?

    public init(peerId: Int64, isOwnProfile: Bool) {
        self.peerId = peerId
        self.isOwnProfile = isOwnProfile
        self.badges = SGBadges.allBadges(for: peerId)
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    deinit {
        imageLoadTask?.cancel()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        closeButton.setTitle("✕", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 20.0, weight: .semibold)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)

        if badges.isEmpty {
            emptyLabel.text = "No badges yet."
            emptyLabel.textAlignment = .center
            emptyLabel.textColor = .secondaryLabel
            view.addSubview(emptyLabel)
            return
        }

        titleLabel.font = .boldSystemFont(ofSize: 24.0)
        titleLabel.textAlignment = .center
        view.addSubview(titleLabel)

        aboutLabel.font = .systemFont(ofSize: 15.0)
        aboutLabel.textColor = .secondaryLabel
        aboutLabel.textAlignment = .center
        aboutLabel.numberOfLines = 0
        view.addSubview(aboutLabel)

        view.addSubview(spinView)

        equipButton.titleLabel?.font = .boldSystemFont(ofSize: 16.0)
        equipButton.layer.cornerRadius = 12.0
        equipButton.backgroundColor = .systemBlue
        equipButton.setTitleColor(.white, for: .normal)
        equipButton.addTarget(self, action: #selector(equipTapped), for: .touchUpInside)
        view.addSubview(equipButton)

        thumbnailStack.axis = .horizontal
        thumbnailStack.spacing = 12.0
        thumbnailScrollView.addSubview(thumbnailStack)
        view.addSubview(thumbnailScrollView)

        for (index, badge) in badges.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(badge.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13.0, weight: .medium)
            button.backgroundColor = UIColor(hexString: badge.color)?.withAlphaComponent(0.2) ?? UIColor.systemGray5
            button.layer.cornerRadius = 10.0
            button.contentEdgeInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 8.0, right: 12.0)
            button.tag = index
            button.addTarget(self, action: #selector(thumbnailTapped(_:)), for: .touchUpInside)
            thumbnailButtons.append(button)
            thumbnailStack.addArrangedSubview(button)
        }

        let equippedTitle = SGBadges.primaryBadge(for: peerId)?.title
        let initialIndex = badges.firstIndex(where: { $0.title == equippedTitle }) ?? 0
        select(index: initialIndex)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let safeTop = view.safeAreaInsets.top
        closeButton.frame = CGRect(x: 16.0, y: safeTop + 8.0, width: 36.0, height: 36.0)

        if badges.isEmpty {
            emptyLabel.frame = CGRect(x: 20.0, y: view.bounds.height / 2.0 - 20.0, width: view.bounds.width - 40.0, height: 40.0)
            return
        }

        let contentWidth = view.bounds.width - 40.0
        var y = safeTop + 56.0

        let spinSize = min(contentWidth, 220.0)
        spinView.frame = CGRect(x: (view.bounds.width - spinSize) / 2.0, y: y, width: spinSize, height: spinSize)
        y = spinView.frame.maxY + 20.0

        titleLabel.frame = CGRect(x: 20.0, y: y, width: contentWidth, height: 30.0)
        y = titleLabel.frame.maxY + 6.0

        let aboutHeight = aboutLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height
        aboutLabel.frame = CGRect(x: 20.0, y: y, width: contentWidth, height: aboutHeight)
        y = aboutLabel.frame.maxY + 20.0

        if isOwnProfile {
            equipButton.frame = CGRect(x: (view.bounds.width - 160.0) / 2.0, y: y, width: 160.0, height: 44.0)
            y = equipButton.frame.maxY + 24.0
        }

        thumbnailStack.frame.origin = CGPoint(x: 20.0, y: 0.0)
        thumbnailStack.sizeToFit()
        thumbnailScrollView.frame = CGRect(x: 0.0, y: y, width: view.bounds.width, height: max(44.0, thumbnailStack.frame.height))
        thumbnailScrollView.contentSize = CGSize(width: thumbnailStack.frame.maxX + 20.0, height: thumbnailScrollView.frame.height)
    }

    private func select(index: Int) {
        guard index >= 0, index < badges.count else {
            return
        }
        selectedIndex = index
        let badge = badges[index]
        titleLabel.text = badge.title
        aboutLabel.text = badge.about
        spinView.fallbackColor = UIColor(hexString: badge.color) ?? .systemGray4
        spinView.image = nil

        for (i, button) in thumbnailButtons.enumerated() {
            button.alpha = i == index ? 1.0 : 0.55
        }

        imageLoadTask?.cancel()
        if let imgURLString = badge.imgUrl, let imgURL = URL(string: imgURLString) {
            let task = URLSession.shared.dataTask(with: imgURL) { [weak self] data, _, error in
                guard let self, let data, error == nil, let image = UIImage(data: data) else {
                    return
                }
                DispatchQueue.main.async {
                    guard self.selectedIndex == index else {
                        return
                    }
                    self.spinView.image = image
                }
            }
            imageLoadTask = task
            task.resume()
        }

        updateEquipButton()
    }

    private func updateEquipButton() {
        guard isOwnProfile, !badges.isEmpty else {
            return
        }
        let badge = badges[selectedIndex]
        let isEquipped = SGBadges.primaryBadge(for: peerId)?.title == badge.title
        equipButton.setTitle(isEquipped ? "Equipped" : "Equip", for: .normal)
        equipButton.isEnabled = !isEquipped
        equipButton.alpha = isEquipped ? 0.5 : 1.0
    }

    @objc private func thumbnailTapped(_ sender: UIButton) {
        select(index: sender.tag)
        view.setNeedsLayout()
    }

    @objc private func equipTapped() {
        guard selectedIndex < badges.count,
              let url = SGBadges.equipIssueURL(peerId: peerId, badgeTitle: badges[selectedIndex].title) else {
            return
        }
        UIApplication.shared.open(url)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }
}

// MARK: ViboGram - same hex-color parsing every other badge display in
// this codebase already relies on (PeerInfoHeaderNode.swift uses Display's
// own UIColor(hexString:)) -- duplicated locally rather than pulling in
// the whole Display module just for this one initializer, since this
// screen is otherwise plain UIKit with no other Display dependency.
private extension UIColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        hex = hex.replacingOccurrences(of: "#", with: "")
        guard hex.count == 6 || hex.count == 8 else {
            return nil
        }
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value) else {
            return nil
        }
        let r, g, b, a: CGFloat
        if hex.count == 8 {
            r = CGFloat((value & 0xFF000000) >> 24) / 255.0
            g = CGFloat((value & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((value & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(value & 0x000000FF) / 255.0
        } else {
            r = CGFloat((value & 0xFF0000) >> 16) / 255.0
            g = CGFloat((value & 0x00FF00) >> 8) / 255.0
            b = CGFloat(value & 0x0000FF) / 255.0
            a = 1.0
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}
