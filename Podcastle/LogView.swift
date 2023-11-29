//
//  LogView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 09/11/2023.
//

import Foundation
import SwiftUI

struct LogView: View {
    @ObservedObject var player = PodcastPlayer.shared
    
    var body: some View {
        NavigationStack {
            List(player.log.reversed(), id: \.self) { item in
                Text(item).font(.footnote)
            }
            .navigationTitle("Log File")
        }
    }
}

struct Log_Previews: PreviewProvider {
    static var previews: some View {
        LogView()
    }
}
