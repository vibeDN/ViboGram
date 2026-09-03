import Foundation
import UIKit
import TelegramPresentationData

public final class TextInputMenu {
    public enum State {
        case inactive
        case general
        case format
    }
    
    private var stringBold: String = "Bold"
    private var stringItalic: String = "Italic"
    private var stringMonospace: String = "Monospace"
    private var stringLink: String = "Link"
    private var stringStrikethrough: String = "Strikethrough"
    private var stringUnderline: String = "Underline"
    private var stringSpoiler: String = "Spoiler"
    private var stringQuote: String = "Quote"
    private var stringCode: String = "Code"
    // MARK: ViboGram - Size/Dim/Rainbow text effects. Plain hardcoded
    // strings, not upstream PresentationStrings keys, matching how the
    // rest of this fork's own new-feature labels are done elsewhere.
    private var stringDim: String = "Dim"
    private var stringRainbow: String = "Rainbow"
    // MARK: ViboGram - label updated from "Big" to "Size": the handler behind
    // this now opens a size picker (13-70) instead of applying one fixed
    // multiplier, so "Big" no longer describes what tapping it does.
    private var stringSizeBig: String = "Size"
    
    private let hasSpoilers: Bool
    private let hasQuotes: Bool
    
    public private(set) var state: State = .inactive {
        didSet {
            if self.state != oldValue {
                switch self.state {
                case .inactive:
                    UIMenuController.shared.menuItems = []
                case .general:
                    UIMenuController.shared.menuItems = []
                case .format:
                    var menuItems: [UIMenuItem] = [
                        UIMenuItem(title: self.stringBold, action: Selector(("formatAttributesBold:"))),
                        UIMenuItem(title: self.stringItalic, action: Selector(("formatAttributesItalic:"))),
                        UIMenuItem(title: self.stringMonospace, action: Selector(("formatAttributesMonospace:"))),
                        UIMenuItem(title: self.stringLink, action: Selector(("formatAttributesLink:"))),
                        UIMenuItem(title: self.stringStrikethrough, action: Selector(("formatAttributesStrikethrough:"))),
                        UIMenuItem(title: self.stringUnderline, action: Selector(("formatAttributesUnderline:"))),
                        // MARK: ViboGram - real bug fix: formatAttributesDim/
                        // Rainbow/SizeBig existed and worked (see
                        // ChatTextFormat.swift's chatTextInputWrapWithEffect,
                        // called from all three of these @objc handlers) but
                        // were never actually added to this menu, so the
                        // format popup could never offer them -- only
                        // decoding an already-formatted message (applyEffects)
                        // worked, never composing one this way.
                        UIMenuItem(title: self.stringDim, action: Selector(("formatAttributesDim:"))),
                        UIMenuItem(title: self.stringRainbow, action: Selector(("formatAttributesRainbow:"))),
                        UIMenuItem(title: self.stringSizeBig, action: Selector(("formatAttributesSizeBig:")))
                    ]
                    if self.hasSpoilers {
                        menuItems.insert(UIMenuItem(title: self.stringSpoiler, action: Selector(("formatAttributesSpoiler:"))), at: 0)
                    }
                    if self.hasQuotes {
                        menuItems.insert(UIMenuItem(title: self.stringQuote, action: Selector(("formatAttributesQuote:"))), at: 0)
                        menuItems.append(UIMenuItem(title: self.stringCode, action: Selector(("formatAttributesCodeBlock:"))))
                    }
                    UIMenuController.shared.menuItems = menuItems
                }
            }
        }
    }
    
    private var observer: NSObjectProtocol?
    
    public init(hasSpoilers: Bool = false, hasQuotes: Bool = false) {
        self.hasSpoilers = hasSpoilers
        self.hasQuotes = hasQuotes
        self.observer = NotificationCenter.default.addObserver(forName: UIMenuController.didHideMenuNotification, object: nil, queue: nil, using: { [weak self] _ in
            self?.back()
        })
    }
    
    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    public func updateStrings(_ strings: PresentationStrings) {
        self.stringBold = strings.TextFormat_Bold
        self.stringItalic = strings.TextFormat_Italic
        self.stringMonospace = strings.TextFormat_Monospace
        self.stringLink = strings.TextFormat_Link
        self.stringStrikethrough = strings.TextFormat_Strikethrough
        self.stringUnderline = strings.TextFormat_Underline
        self.stringSpoiler = strings.TextFormat_Spoiler
        self.stringQuote = strings.TextFormat_Quote
        self.stringCode = strings.TextFormat_Code
    }
    
    public func activate() {
        if self.state == .inactive {
            self.state = .general
        }
    }
    
    public func deactivate() {
        self.state = .inactive
    }
    
    public func format(view: UIView, rect: CGRect) {
        if self.state == .general {
            self.state = .format
            if #available(iOS 13.0, *) {
                UIMenuController.shared.showMenu(from: view, rect: rect)
            } else {
                UIMenuController.shared.isMenuVisible = true
                UIMenuController.shared.update()
            }
        }
    }
    
    public func back() {
        if self.state == .format {
            self.state = .general
        }
    }
    
    public func hide() {
        self.back()
        if #available(iOS 13.0, *) {
            UIMenuController.shared.hideMenu()
        } else {
            UIMenuController.shared.isMenuVisible = false
        }
        UIMenuController.shared.update()
    }
}
