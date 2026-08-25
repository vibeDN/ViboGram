import Foundation
import UIKit
import TelegramCore
import Display
import SwiftSignalKit
import TelegramUIPreferences
import AccountContext
import UndoUI
import AttachmentFileController
import LegacyMediaPickerUI
import ICloudResources
import TelegramPresentationData
import PromptUI
import SGStrings

final class OverlayAudioPlayerControllerImpl: ViewController, OverlayAudioPlayerController {
    private let context: AccountContext
    let chatLocation: ChatLocation
    let type: MediaManagerPlayerType
    let initialMessageId: EngineMessage.Id
    let initialOrder: MusicPlaybackSettingsOrder
    let playlistLocation: SharedMediaPlaylistLocation?
    
    private(set) weak var parentNavigationController: NavigationController?
    
    private var animatedIn = false
    
    private var controllerNode: OverlayAudioPlayerControllerNode {
        return self.displayNode as! OverlayAudioPlayerControllerNode
    }
    
    private var accountInUseDisposable: Disposable?
    // MARK: ViboGram - kept as a controller-lifetime property (not a local var
    // inside the button action) so it isn't deallocated mid-flow; mirrors the
    // existing AuthorizationSequenceSignUpController.presentLegacyAvatarPicker usage.
    private let avatarPickerHolder = Atomic<NSObject?>(value: nil)
    
    init(
        context: AccountContext,
        chatLocation: ChatLocation,
        type: MediaManagerPlayerType,
        initialMessageId: EngineMessage.Id,
        initialOrder: MusicPlaybackSettingsOrder,
        playlistLocation: SharedMediaPlaylistLocation? = nil,
        parentNavigationController: NavigationController?
    ) {
        self.context = context
        self.chatLocation = chatLocation
        self.type = type
        self.initialMessageId = initialMessageId
        self.initialOrder = initialOrder
        self.playlistLocation = playlistLocation
        self.parentNavigationController = parentNavigationController
        
        super.init(navigationBarPresentationData: nil)
        
        self.statusBar.statusBarStyle = .Ignore
        self.automaticallyControlPresentationContextLayout = false
        
        self.ready.set(.never())
        
        self.accountInUseDisposable = context.sharedContext.setAccountUserInterfaceInUse(context.account.id)
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.accountInUseDisposable?.dispose()
    }
    
    override public func loadDisplayNode() {
        self.displayNode = OverlayAudioPlayerControllerNode(
            context: self.context,
            chatLocation: self.chatLocation,
            type: self.type,
            initialMessageId: self.initialMessageId,
            initialOrder: self.initialOrder,
            playlistLocation: self.playlistLocation,
            requestDismiss: { [weak self] in
                self?.dismiss()
            },
            requestShare: { [weak self] subject in
                if let strongSelf = self {
                    var canShowInChat = false
                    if case .messages = subject {
                        canShowInChat = true
                    }
                    let shareController = strongSelf.context.sharedContext.makeShareController(context: strongSelf.context, params: ShareControllerParams(subject: subject, showInChat: canShowInChat ? { message in
                        if let strongSelf = self {
                            strongSelf.context.sharedContext.navigateToChat(accountId: strongSelf.context.account.id, peerId: message.id.peerId, messageId: message.id)
                            strongSelf.dismiss()
                        }
                    } : nil, externalShare: true, completed: { [weak self] peerIds in
                        if let strongSelf = self {
                            let _ = (strongSelf.context.engine.data.get(
                                EngineDataList(
                                    peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)
                                )
                            )
                                     |> deliverOnMainQueue).startStandalone(next: { [weak self] peerList in
                                if let strongSelf = self {
                                    let peers = peerList.compactMap { $0 }
                                    let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }

                                    let text: String
                                    var savedMessages = false
                                    if peerIds.count == 1, let peerId = peerIds.first, peerId == strongSelf.context.account.peerId {
                                        text = presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One
                                        savedMessages = true
                                    } else {
                                        if peers.count == 1, let peer = peers.first {
                                            var peerName = peer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            peerName = peerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_Chat_One(peerName).string
                                        } else if peers.count == 2, let firstPeer = peers.first, let secondPeer = peers.last {
                                            var firstPeerName = firstPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : firstPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            firstPeerName = firstPeerName.replacingOccurrences(of: "**", with: "")
                                            var secondPeerName = secondPeer.id == strongSelf.context.account.peerId ? presentationData.strings.DialogList_SavedMessages : secondPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            secondPeerName = secondPeerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_TwoChats_One(firstPeerName, secondPeerName).string
                                        } else if let peer = peers.first {
                                            var peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            peerName = peerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_ManyChats_One(peerName, "\(peers.count - 1)").string
                                        } else {
                                            text = ""
                                        }
                                    }

                                    strongSelf.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: savedMessages, text: text), elevatedLayout: false, animateInAsReplacement: true, action: { action in
                                        if savedMessages, let self, action == .info {
                                            let _ = (self.context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: self.context.account.peerId))
                                                |> deliverOnMainQueue).start(next: { [weak self] peer in
                                                guard let self, let peer else {
                                                    return
                                                }
                                                guard let navigationController = self.parentNavigationController else {
                                                    return
                                                }
                                                self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: self.context, chatLocation: .peer(peer), forceOpenChat: true))
                                            })
                                        }
                                        return false
                                    }), in: .current)
                                }
                            })
                        }
                    }))
                    strongSelf.controllerNode.view.endEditing(true)
                    strongSelf.present(shareController, in: .window(.root))
                }
            },
            requestSearchByArtist: { [weak self] artist in
                guard let self else {
                    return
                }
                self.context.sharedContext.openSearch(filter: .music, query: artist)
                self.dismiss()
            },
            requestAdd: { [weak self] in
                guard let self, let navigationController = self.parentNavigationController else {
                    return
                }
                var dismissImpl: (() -> Void)?
                let controller = makeAttachmentFileControllerImpl(
                    context: self.context,
                    mode: .audio(.savedMusic),
                    presentFiles: { [weak self] in
                        guard let self else {
                            return
                        }
                        dismissImpl?()
                        let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                        let controller = legacyICloudFilePicker(theme: presentationData.theme, mode: .default, documentTypes: ["public.mp3", "public.mpeg-4-audio", "public.aac-audio", "org.xiph.flac"], completion: { [weak self] urls in
                            guard let self, let url = urls.first else {
                                return
                            }
                            
                            let _ = (iCloudFileDescription(url)
                            |> deliverOnMainQueue).start(next: { [weak self] item in
                                guard let self, let item else {
                                    return
                                }
                                let fileId = Int64.random(in: Int64.min ... Int64.max)
                                let mimeType = guessMimeTypeByFileExtension((item.fileName as NSString).pathExtension)
                                var previewRepresentations: [TelegramMediaImageRepresentation] = []
                                if mimeType.hasPrefix("image/") || mimeType == "application/pdf" || item.audioMetadata?.hasAudioArtwork == true {
                                    previewRepresentations.append(TelegramMediaImageRepresentation(dimensions: PixelDimensions(width: 320, height: 320), resource: ICloudFileResource(urlData: item.urlData, thumbnail: true), progressiveSizes: [], immediateThumbnailData: nil, hasVideo: false, isPersonal: false))
                                }
                                var attributes: [TelegramMediaFileAttribute] = []
                                attributes.append(.FileName(fileName: item.fileName))
                                if let audioMetadata = item.audioMetadata {
                                    attributes.append(.Audio(isVoice: false, duration: audioMetadata.duration, title: audioMetadata.title, performer: audioMetadata.performer, waveform: nil))
                                }
                                
                                let file = TelegramMediaFile(fileId: EngineMedia.Id(namespace: Namespaces.Media.LocalFile, id: fileId), partialReference: nil, resource: ICloudFileResource(urlData: item.urlData, thumbnail: false), previewRepresentations: previewRepresentations, videoThumbnails: [], immediateThumbnailData: nil, mimeType: mimeType, size: Int64(item.fileSize), attributes: attributes, alternativeRepresentations: [])
                                
                                let _ = (standaloneUploadedFile(
                                    postbox: self.context.account.postbox,
                                    network: self.context.account.network,
                                    peerId: self.context.account.peerId,
                                    text: "",
                                    source: .resource(.media(media: .standalone(media: file), resource: file.resource)),
                                    thumbnailData: file.immediateThumbnailData,
                                    mimeType: file.mimeType,
                                    attributes: file.attributes,
                                    hintFileIsLarge: false
                                )
                                |> deliverOnMainQueue).start(next: { [weak self] value in
                                    guard let self else {
                                        return
                                    }
                                    switch value {
                                    case let .result(result):
                                        switch result {
                                        case let .media(resultMedia):
                                            if let resultFile = resultMedia.media as? TelegramMediaFile {
                                                self.context.engine.resources.moveResourceData(from: EngineMediaResource.Id(file.resource.id), to: EngineMediaResource.Id(resultFile.resource.id), synchronous: true)
                                                self.controllerNode.addToSavedMusic(file: .standalone(media: file))
                                            }
                                        }
                                    default:
                                        break
                                    }
                                })
                            })
                        })
                        self.present(controller, in: .window(.root))
                    },
                    send: { [weak self] mediaReferences, _, _, _ in
                        guard let self, let reference = mediaReferences.first?.concrete(TelegramMediaFile.self) else {
                            return
                        }
                        self.controllerNode.addToSavedMusic(file: reference)
                    }
                ) as! AttachmentFileControllerImpl
                controller.navigationPresentation = .modal
                navigationController.pushViewController(controller)
                dismissImpl = { [weak controller] in
                    controller?.dismiss()
                }
            },
            // MARK: ViboGram - music file tag editing (Tier 3). Re-uploads the
            // already-cached track as a standalone document with edited
            // title/performer/cover, then swaps it into the profile (remove old,
            // add new) via the node's existing addToSavedMusic/removeFromSavedMusic
            // -- `account.saveMusic` itself has no tag-editing parameters, so a
            // fresh upload is the only way to change tags on profile music.
            requestEdit: { [weak self] fileReference in
                guard let self else {
                    return
                }
                let file = fileReference.media
                var currentTitle = ""
                var currentPerformer = ""
                var currentDuration = 0
                var currentWaveform: Data?
                for attribute in file.attributes {
                    if case let .Audio(_, duration, title, performer, waveform) = attribute {
                        currentDuration = duration
                        currentTitle = title ?? ""
                        currentPerformer = performer ?? ""
                        currentWaveform = waveform
                    }
                }
                let presentationData = self.context.sharedContext.currentPresentationData.with { $0 }
                let lang = presentationData.strings.baseLanguageCode

                let finishEdit: (String, String, UIImage?) -> Void = { [weak self] newTitle, newPerformer, coverImage in
                    guard let self else {
                        return
                    }
                    var attributes: [TelegramMediaFileAttribute] = file.attributes.filter { attribute in
                        if case .Audio = attribute {
                            return false
                        }
                        return true
                    }
                    attributes.append(.Audio(isVoice: false, duration: currentDuration, title: newTitle.isEmpty ? nil : newTitle, performer: newPerformer.isEmpty ? nil : newPerformer, waveform: currentWaveform))

                    let thumbnailData: Data?
                    if let coverImage, let jpegData = coverImage.jpegData(compressionQuality: 0.8) {
                        thumbnailData = jpegData
                    } else {
                        thumbnailData = file.immediateThumbnailData
                    }

                    let _ = (standaloneUploadedFile(
                        postbox: self.context.account.postbox,
                        network: self.context.account.network,
                        peerId: self.context.account.peerId,
                        text: "",
                        source: .resource(.media(media: fileReference.abstract, resource: file.resource)),
                        thumbnailData: thumbnailData,
                        mimeType: file.mimeType,
                        attributes: attributes,
                        hintFileIsLarge: false
                    )
                    |> deliverOnMainQueue).start(next: { [weak self] value in
                        guard let self else {
                            return
                        }
                        switch value {
                        case let .result(result):
                            switch result {
                            case let .media(resultMedia):
                                if let resultFile = resultMedia.media as? TelegramMediaFile {
                                    self.context.engine.resources.moveResourceData(from: EngineMediaResource.Id(file.resource.id), to: EngineMediaResource.Id(resultFile.resource.id), synchronous: true)
                                    self.controllerNode.removeFromSavedMusic(file: fileReference)
                                    self.controllerNode.addToSavedMusic(file: .standalone(media: resultFile))
                                }
                            }
                        default:
                            break
                        }
                    })
                }

                let showCoverStep: (String, String) -> Void = { [weak self] newTitle, newPerformer in
                    guard let self else {
                        return
                    }
                    let alert = standardTextAlertController(
                        theme: AlertControllerTheme(presentationData: presentationData),
                        title: i18n("MediaPlayer.SavedMusic.EditCoverTitle", lang),
                        text: i18n("MediaPlayer.SavedMusic.EditCoverText", lang),
                        actions: [
                            TextAlertAction(type: .genericAction, title: i18n("MediaPlayer.SavedMusic.EditCoverKeep", lang), action: {
                                finishEdit(newTitle, newPerformer, nil)
                            }),
                            TextAlertAction(type: .defaultAction, title: i18n("MediaPlayer.SavedMusic.EditCoverChange", lang), action: { [weak self] in
                                guard let self else {
                                    return
                                }
                                presentLegacyAvatarPicker(
                                    holder: self.avatarPickerHolder,
                                    signup: false,
                                    theme: presentationData.theme,
                                    present: { [weak self] c, _ in
                                        self?.present(c, in: .window(.root))
                                    },
                                    openCurrent: nil,
                                    completion: { image in
                                        finishEdit(newTitle, newPerformer, image)
                                    }
                                )
                            })
                        ]
                    )
                    self.present(alert, in: .window(.root))
                }

                let showPerformerPrompt: (String) -> Void = { [weak self] newTitle in
                    guard let self else {
                        return
                    }
                    let controller = promptController(
                        context: self.context,
                        text: i18n("MediaPlayer.SavedMusic.EditPerformerPrompt", lang),
                        value: currentPerformer,
                        placeholder: i18n("MediaPlayer.SavedMusic.EditPerformerPlaceholder", lang),
                        apply: { newPerformer in
                            guard let newPerformer else {
                                return
                            }
                            showCoverStep(newTitle, newPerformer)
                        }
                    )
                    self.present(controller, in: .window(.root))
                }

                let titleController = promptController(
                    context: self.context,
                    text: i18n("MediaPlayer.SavedMusic.EditTitlePrompt", lang),
                    value: currentTitle,
                    placeholder: i18n("MediaPlayer.SavedMusic.EditTitlePlaceholder", lang),
                    apply: { newTitle in
                        guard let newTitle else {
                            return
                        }
                        showPerformerPrompt(newTitle)
                    }
                )
                self.present(titleController, in: .window(.root))
            },
            getParentController: { [weak self] in
                return self
            }
        )
        
        self.ready.set(self.controllerNode.ready.get())
        
        self.displayNodeDidLoad()
    }
    
    override public func loadView() {
        super.loadView()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !self.animatedIn {
            self.animatedIn = true
            self.controllerNode.animateIn()
        }
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        self.controllerNode.animateOut(completion: { [weak self] in
            if let _ = self?.navigationController {
                self?.dismiss(animated: false, completion: nil)
            } else {
                self?.presentingViewController?.dismiss(animated: false, completion: nil)
            }
            completion?()
        })
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, transition: transition)
    }
}
