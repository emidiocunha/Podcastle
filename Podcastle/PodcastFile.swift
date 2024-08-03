//
//  PodcastFile.swift
//  Podcastle
//
//  Created by Emídio Cunha on 03/08/2024.
//

import Foundation

class PodcastFile : NSObject, ObservableObject {
    @Published var currentChapter:ID3V2Frame? = nil
    static let shared = PodcastFile()
    var id3v2file:ID3V2File? = nil
    
    func loadFile(_ filename:String, seconds:Double) {
        id3v2file = ID3V2File(filename: filename)
        if id3v2file?.chapters().count ?? 0 > 0 {
            updateCurrentChapter(seconds)
        } else {
            currentChapter = nil
        }
    }
    
    func updateCurrentChapter(_ seconds:Double) {
        if let ch = id3v2file?.chapters().first(where: { frame in
            let m = UInt32(seconds * 1000)
            return m >= frame.startTime && m <= frame.endTime
        }) {
            if currentChapter == nil || currentChapter?.id != ch.id {
                currentChapter = ch
            }
        }
    }
    
}
