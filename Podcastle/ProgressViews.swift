//
//  CircularProgressView.swift
//  VoiceFeed
//
//  Created by Emídio Cunha on 16/08/2023.
//

import Foundation
import SwiftUI

struct ProgressBarView: View {
    @Environment(\.colorScheme) var colorScheme
    var progress: Double
    var title: String
    
    var body: some View {
        ZStack(alignment: .leading) {
            let color:Color = colorScheme == .dark ? .white : .black
            RoundedRectangle(cornerSize: CGSize(width: 4, height: 4))
                .stroke(color, lineWidth:1)
                .frame(width: 120, height: 24)
                .background(.clear)
                //.foregroundColor(color)
            Rectangle()
                .frame(width: min(CGFloat(self.progress * 120 / 100), 120), height: 24)
                .foregroundColor(color)
                .animation(.linear, value: UUID())
            HStack {
                Spacer()
                if title.count > 0 {
                    Text("\(title)")
                        .foregroundColor(.white)
                        .blendMode(.difference)
                        .cornerRadius(4)
                } else {
                    Text(String(format:"%.0f%%", progress))
                        .foregroundColor(.white)
                        .blendMode(.difference)
                        .cornerRadius(4)
                }
                Spacer()
            }
        }.frame(width: 120, height: 24).cornerRadius(4)
    }
}

struct CircularProgressView: View {
    let progress: Double
    let backgroundColor: Color
    var body: some View {
        Group {
            ZStack {
                Circle()
                    .stroke(
                        Color.white,
                        lineWidth: 7
                    )
                Circle()
                    .stroke(
                        backgroundColor,
                        lineWidth: 5
                    )
                Circle()
                    .trim(from: 0, to: progress/100)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(
                            lineWidth: 5,
                            lineCap: .butt
                        )
                    )
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

