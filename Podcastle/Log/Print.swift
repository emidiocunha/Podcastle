//
//  Print.swift
//  Podcastle
//
//  Created by Emídio Cunha on 10/11/2023.
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

// Custom print function that logs output to console during DEBUG builds
// and appends the output with timestamp to a shared log file asynchronously.
//
// Regardless of your fancy IDE, trending language, and hipster frameworks,
// there’s nothing like leaving breadcrumbs along your code to confirm or deny
// a given problem, and by that I mean using print.

public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    // Convert all input items to strings and join them using the specified separator.
    let output = items.map { "\($0)" }.joined(separator: separator)
    // Only print to standard output in DEBUG mode.
    #if DEBUG
        Swift.print(output, terminator: terminator)
    #endif
    // Format the current timestamp to include in the log file.
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"
    dateFormatter.timeZone = .current
    let currentDateTimeString = dateFormatter.string(from: Date())
    // Asynchronously append the timestamped log entry to the shared log file.
    Task { await LogFile.shared.append("\(currentDateTimeString) \(output)") }
}
