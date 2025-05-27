//
//  ProgressViews.swift
//  Podcastle
//
//  Created by Emídio Cunha on 16/08/2023.
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
                .animation(.none, value: UUID())
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
        }
        .frame(width: 120, height: 24)
        .cornerRadius(4)
        .animation(.none, value:UUID())
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

