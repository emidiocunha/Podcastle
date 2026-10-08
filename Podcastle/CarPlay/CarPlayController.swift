//
//  CarPlayController.swift
//  Podcastle
//
//  MIT License
//
//  Copyright (c) 2025 Emídio Cunha
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import CarPlay
import Combine
import UIKit

// iOS instantiates one instance per CarPlay connection; all logic lives in the shared controller.

@objc(CarPlaySceneDelegate)
class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
    override init() {
        super.init()
        print("🚗 CarPlay: instantiated")
    }

    @objc(templateApplicationScene:didConnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in CarPlayController.shared.connect(interfaceController) }
    }

    @objc(templateApplicationScene:didDisconnectInterfaceController:)
    func templateApplicationScene(_ scene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in CarPlayController.shared.disconnect() }
    }
}

// Bridges PodcastPlayer + PodcastFile to the CarPlay template hierarchy.
// Root template: CPListTemplate of podcasts. CPNowPlayingTemplate (artwork + transport
// controls via MPNowPlayingInfoCenter) is pushed on top of it — Apple only supports
// pushing the shared Now Playing template, not making it the root. With it as root,
// anything pushed above it (the podcasts list) could get popped right back off the
// first time the system itself brought Now Playing forward.
// Chapters: CPListTemplate pushed above Now Playing; current chapter marked with a speaker icon.
@MainActor
final class CarPlayController {
    static let shared = CarPlayController()
    private init() {}

    var player: PodcastPlayer?
    var subscriptions: Subscriptions? {
        // On a cold launch from CarPlay, connect() can run before the app's setup
        // has handed these over — fill the root list in once they arrive.
        didSet { refreshPodcastsList() }
    }

    var file: PodcastFile? {
        didSet {
            subscribeToFile()
            refreshNowPlayingButtons()
        }
    }

    private var interfaceController: CPInterfaceController?
    private var podcastsTemplate: CPListTemplate?
    private var chapterTemplate: CPListTemplate?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Connection lifecycle

    func connect(_ controller: CPInterfaceController) {
        interfaceController = controller
        refreshNowPlayingButtons()
        let root = CPListTemplate(title: "Podcasts", sections: [])
        podcastsTemplate = root
        controller.setRootTemplate(root, animated: false, completion: nil)
        refreshPodcastsList()
        // Land on Now Playing, as before, when there's an episode loaded.
        if player?.currentPodcast != nil {
            showNowPlaying(animated: false)
        }
    }

    func disconnect() {
        interfaceController = nil
        podcastsTemplate = nil
        chapterTemplate = nil
    }

    private func showNowPlaying(animated: Bool) {
        guard let interfaceController else { return }
        let nowPlaying = CPNowPlayingTemplate.shared
        // Pushing a template that's already on the stack is an error in CarPlay.
        if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
            if interfaceController.topTemplate !== nowPlaying {
                interfaceController.pop(to: nowPlaying, animated: animated, completion: nil)
            }
        } else {
            interfaceController.pushTemplate(nowPlaying, animated: animated, completion: nil)
        }
    }

    // MARK: - Now Playing supplementary buttons

    private func refreshNowPlayingButtons() {
        guard interfaceController != nil else { return }

        var buttons: [CPNowPlayingButton] = []

        let podcastsIcon = UIImage(systemName: "square.stack")?.withTintColor(.label, renderingMode: .alwaysOriginal)
        buttons.append(CPNowPlayingImageButton(image: podcastsIcon ?? UIImage()) { [weak self] _ in
            self?.pushPodcastsList()
        })

        if file?.hasChapters == true {
            let chaptersIcon = UIImage(systemName: "list.bullet")?.withTintColor(.label, renderingMode: .alwaysOriginal)
            buttons.append(CPNowPlayingImageButton(image: chaptersIcon ?? UIImage()) { [weak self] _ in
                self?.pushChapterList()
            })
        }

        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons)
    }

    // MARK: - Podcasts list template

    // The podcasts list is the root, sitting under Now Playing — going back to it
    // is a pop, never a push.
    private func pushPodcastsList() {
        refreshPodcastsList()
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
    }

    private func refreshPodcastsList() {
        guard let subscriptions, let template = podcastsTemplate else { return }
        Task { @MainActor in
            let feed = await subscriptions.loadFeed()
            template.updateSections([CPListSection(items: self.makePodcastItems(from: feed))])
        }
    }

    private func makePodcastItems(from feed: [GroupedEpisodeList]) -> [CPListItem] {
        feed.compactMap { entry in
            let episode = entry.episode
            guard let name = episode.directory?.name, !name.isEmpty else { return nil }

            let item = CPListItem(text: name, detailText: episode.title, image: Self.artwork(for: episode))
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    guard let self, let player = self.player else { completion(); return }
                    if player.setPodcast(episode) {
                        player.play()
                        self.showNowPlaying(animated: true)
                    }
                    completion()
                }
            }
            return item
        }
    }

    // Uses the already-downloaded local artwork file if present; falls back to a
    // system-tinted placeholder glyph rather than fetching over the network from CarPlay.
    private static func artwork(for episode: Episode) -> UIImage? {
        if let url = episode.fullLocalUrl(.artwork),
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            return image
        }
        return UIImage(systemName: "mic.fill")?.withTintColor(.label, renderingMode: .alwaysOriginal)
    }

    // MARK: - Chapter list template

    private func pushChapterList() {
        let template = buildChapterTemplate()
        chapterTemplate = template
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func buildChapterTemplate() -> CPListTemplate {
        CPListTemplate(title: "Chapters", sections: [CPListSection(items: makeChapterItems())])
    }

    private func makeChapterItems() -> [CPListItem] {
        guard let file = file, let chapters = file.id3v2file?.chapters() else { return [] }
        let currentID = file.currentChapter?.id
        return chapters.compactMap { chapter in
            guard let sub = chapter.subFrames.first else { return nil }
            let isCurrent = chapter.id == currentID
            let image = UIImage(systemName: isCurrent ? "speaker.wave.2.fill" : "circle")?
                .withTintColor(.label, renderingMode: .alwaysOriginal)
            let item = CPListItem(text: sub.title,
                                  detailText: Double(chapter.startTime / 1000).prettyPrintSeconds(),
                                  image: image)
            item.handler = { [weak self] _, completion in
                Task { @MainActor in
                    self?.player?.absoluteSeek(Double(chapter.startTime) / 1000.0)
                    self?.interfaceController?.popTemplate(animated: true, completion: nil)
                    completion()
                }
            }
            return item
        }
    }

    private func refreshChapterTemplate() {
        guard let template = chapterTemplate else { return }
        template.updateSections([CPListSection(items: makeChapterItems())])
    }

    // MARK: - Observations

    private func subscribeToFile() {
        cancellables.removeAll()
        guard let file = file else { return }

        // currentChapter fires on every chapter boundary and on episode change (nil ↔ non-nil).
        // This covers both refreshing the "current" marker in the list and
        // showing/hiding the chapters button when episodes with/without chapters are loaded.
        file.$currentChapter
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshNowPlayingButtons()
                self?.refreshChapterTemplate()
            }
            .store(in: &cancellables)
    }
}
