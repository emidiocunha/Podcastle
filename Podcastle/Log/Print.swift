//
//  Print.swift
//  Podcastle
//
//  Created by Emídio Cunha on 10/11/2023.
//

import Foundation

public func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let output = items.map { "\($0)" }.joined(separator: separator)
    #if DEBUG
        Swift.print(output, terminator: terminator)
    #endif
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "HH:mm:ss.SSS"
    dateFormatter.timeZone = .current
    let currentDateTimeString = dateFormatter.string(from: Date())
    DispatchQueue.main.async {
        LogFile.shared.log.append("\(currentDateTimeString) \(output)")
    }
}
