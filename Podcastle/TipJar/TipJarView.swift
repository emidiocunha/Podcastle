//
//  TipJarView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 15/05/2025.
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

import SwiftUI

struct TipJarView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var tipJar = TipJar()

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let product = tipJar.product {
                    Spacer()
                    Text("Support the app with a tip 🙏")
                        .font(.title)
                    Text("Podcastle is a free, and open source project that you can find at https://github.com/emidiocunha/podcastle")
                        .font(.body)
                    Button {
                        Task { await tipJar.purchase() }
                    } label: {
                        Text(product.displayPrice)
                    }
                    .disabled(tipJar.isPurchased)
                    .buttonStyle(.bordered)
                    Spacer()
                    
                    if tipJar.isPurchased {
                        Text("Thanks for your support! ❤️")
                    }
                } else {
                    ProgressView("Loading tip jar...")
                }
            }
            .padding()
            .navigationTitle("Tip Jar")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
        }
        
    }
}

#Preview {
    TipJarView()
}
