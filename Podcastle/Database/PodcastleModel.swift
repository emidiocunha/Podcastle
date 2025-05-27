//
//  ModelContainer.swift
//  Podcastle
//
//  Created by Emídio Cunha on 12/03/2025.
//

import Foundation
import SwiftData

/*
@globalActor actor PodcastleModelActor {
    static let shared = PodcastleModelActor()
}

@PodcastleModelActor
class PodcastleModel:Sendable {
    static let shared = PodcastleModel()
    
    let config: ModelConfiguration
    nonisolated let container: ModelContainer
    let context: ModelContext

    private init() {
        do {
            config = ModelConfiguration(isStoredInMemoryOnly: false)
            container = try ModelContainer(for: Directory.self, Episode.self, configurations: config)
            context = ModelContext(container)
        } catch {
            fatalError("Failed to create model container: \(error)")
        }
    }
    
    func save() {
        do {
            try context.save()
        } catch {
            print("Failed to save context: \(error)")
        }
    }
}*/
