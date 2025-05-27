//
//  LogView.swift
//  Podcastle
//
//  Created by Emídio Cunha on 09/11/2023.
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

actor LogFile {
    static let shared = LogFile()
    private(set) var log: [String] = []
    
    private init() {}

    func append(_ message: String) {
        log.append(message)
    }

    func getLog() -> [String] {
        return log
    }
}

// Being able to watch the app log file is inspired in desktop apps
// It helps break the oppaque nature of smartphones when it comes
// to what the hell is going on inside an app.

struct LogView: View {
    @State private var log: [String] = []
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List(log.reversed(), id: \.self) { item in
                Text(item).font(.footnote)
            }
            .navigationTitle("Log File")
            .navigationBarItems(trailing: Button("Close", action: { dismiss() }))
            .task {
                log = await LogFile.shared.getLog()
            }
        }
    }
}

struct Log_Previews: PreviewProvider {
    static var previews: some View {
        LogView()
    }
}
