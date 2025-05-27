//
//  ID3.swift
//  Podcastle
//
//  Created by Emídio Cunha on 31/07/2024.
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
import UIKit

/// Represents the ID3v2 header found at the beginning of an MP3 file.
struct ID3V2Header {
    var fileIdentifier: String = ""     // 3-character string
    var version: UInt8 = 0              // 1 byte unsigned integer
    var revision: UInt8 = 0             // 1 byte unsigned integer
    var flags: UInt8 = 0                // 1 byte
    var size: UInt32 = 0                // 32-bit unsigned integer
    var unsync = false
    var extentedHeader = false

    /// Initializes an ID3V2Header from binary data.
    init?(from data: Data) {
        guard data.count >= 10 else { // 3 bytes + 4 bytes + 1 byte + 8 bytes = 10 bytes
            print("Data is too short reading ID3V2Header")
            return nil
        }
        
        // Extract the 3-character string
        if let string = String(data: data[0..<3], encoding: .ascii) {
            fileIdentifier = string
            if fileIdentifier != "ID3" {
                print("Invalid identifier string")
                return nil
            }
        } else {
            print("Failed to decode identifier string")
            return nil
        }

        data.withUnsafeBytes { rawBufferPointer in
            let base = rawBufferPointer.baseAddress!
            
            // Extract the 1 byte integer version number
            version = base.loadUnaligned(fromByteOffset: 3, as: UInt8.self)
            
            // Extract the 1 byte integer revision number
            revision = base.loadUnaligned(fromByteOffset: 4, as: UInt8.self)
            
            // Extract the 1 byte flags
            flags = base.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
            
            unsync = flags & 0x80 == 0x80 ? true : false
            extentedHeader = flags & 0x40 == 0x40 ? true : false
            
            // Extract the 32-bit integer (4 bytes) header size

            let s4 = UInt32(base.loadUnaligned(fromByteOffset: 6, as: UInt8.self) & 0x7f) << 21
            let s3 = UInt32(base.loadUnaligned(fromByteOffset: 7, as: UInt8.self) & 0x7f) << 14
            let s2 = UInt32(base.loadUnaligned(fromByteOffset: 8, as: UInt8.self) & 0x7f) << 7
            let s1 = UInt32(base.loadUnaligned(fromByteOffset: 9, as: UInt8.self) & 0x7f)
            
            size = s1 | s2 | s3 | s4
        }
    }
}

/// Represents a single ID3v2 frame (e.g., chapter, title, image, URL).
struct ID3V2Frame:Identifiable, Hashable {
    let id:UUID = UUID()
    var frameID:String = ""
    var size:UInt32 = 0
    var flags:UInt16 = 0
    var pic:UIImage? = nil
    var startTime:UInt32 = 0
    var endTime:UInt32 = 0
    var title:String = ""
    var elementID:String = ""
    var subFrames:[ID3V2Frame] = []
    var url:URL? = nil
    
    /// Initializes an ID3V2Frame from binary data at a given offset.
    init?(from data: Data, offset:UInt64) {
        frameID = String(data: data[offset ..< offset + 4], encoding: .ascii) ?? ""
        
        data.withUnsafeBytes {
            let base = $0.baseAddress!
            var i = Int(offset + 10)
            
            size = base.loadUnaligned(fromByteOffset: Int(offset + 4), as: UInt32.self).bigEndian
            flags = base.loadUnaligned(fromByteOffset: Int(offset + 8), as: UInt16.self).bigEndian
            
            // Our frame of interest
            if frameID == "CHAP" {
                elementID = readString(data: data, offset: &i, size: Int(size - 10), encoding: .ascii, doubleTerminator: false) ?? ""
                
                startTime = base.loadUnaligned(fromByteOffset: Int(i), as: UInt32.self).bigEndian
                endTime = base.loadUnaligned(fromByteOffset: Int(i + 4), as: UInt32.self).bigEndian
                
                i += 16 // Jump to content
                
                // Optional embeded subframes
                let bound = i + Int(size)
                while i < bound {
                    if let subFrame = ID3V2Frame(from: data, offset: UInt64(i)) {
                        subFrames.append(subFrame)
                        i += Int(subFrame.size)
                        i += 10
                    } else {
                        break
                    }
                }
            } else if frameID == "TIT2" {
                let encoding = encoding(base.loadUnaligned(fromByteOffset: i, as: UInt8.self).bigEndian)
            
                i += 1
                title = readString(data: data, offset: &i, size: Int(size) - 1, encoding: encoding, doubleTerminator: encoding == .utf16) ?? ""
            } else if frameID == "APIC" {
                var picSize = i
                let encoding = encoding(base.loadUnaligned(fromByteOffset: i, as: UInt8.self).bigEndian)
                
                i += 1
                
                _ = readString(data: data, offset: &i, size: Int(size), encoding: encoding, doubleTerminator: encoding == .utf16) ?? ""
                _ = base.loadUnaligned(fromByteOffset: i, as: UInt8.self).bigEndian
                
                i += 1
                
                title = readString(data: data, offset: &i, size: Int(size), encoding: encoding, doubleTerminator: encoding == .utf16) ?? ""
                
                picSize = Int(size) - (i - picSize)
                
                let imageData = readData(data: data, offset: &i, size: Int(picSize))
                
                pic = UIImage(data: imageData)
            } else if frameID == "WXXX" {
                let wsize = i
                let encoding = encoding(base.loadUnaligned(fromByteOffset: i, as: UInt8.self).bigEndian)
                
                i += 1
                
                title = readString(data: data, offset: &i, size: Int(size), encoding: encoding, doubleTerminator: encoding == .utf16) ?? ""
                
                if let urlString = readString(data: data, offset: &i, size: Int(size) - (i - wsize), encoding: .isoLatin1, doubleTerminator: false) {
                    url = URL(string: urlString)
                }
            }
        }
    }
    
    /// Returns a formatted chapter title, optionally with a time.
    func prettyPrintChapterTitle(time:Bool) -> String {
        if subFrames.count > 0 {
            if time {
                return "\(Double(startTime / 1000).prettyPrintSeconds()) - \(subFrames[0].title)"
            } else {
                return "\(subFrames[0].title)"
            }
        }
        return ""
    }
    
    /// Returns the chapter image if present.
    func chapterImage() -> UIImage? {
        if subFrames.count > 0 {
            for f in subFrames {
                if f.frameID == "APIC" {
                    return f.pic
                }
            }
        }
        return nil
    }
    
    /// Returns the chapter URL if present.
    func chapterURL() -> URL? {
        if subFrames.count > 0 {
            for f in subFrames {
                if f.frameID == "WXXX" {
                    return f.url
                }
            }
        }
        return nil
    }
        
    /// Reads a chunk of data from the given offset and size.
    func readData(data: Data, offset: inout Int, size: Int) -> Data {
        var bytes: [UInt8] = []
        var bound = offset + size
        
        if bound > data.count {
            bound = data.count
        }
        
        while offset < bound {
            bytes.append(data[offset])
            offset += 1
        }
        
        var d = Data()
        
        d.append(contentsOf:bytes)
        
        return d
    }
    
    /// Returns the string encoding for a given byte value.
    func encoding(_ data: UInt8) -> String.Encoding {
        var encoding:String.Encoding = .ascii
        
        switch data {
        case 0:
            encoding = .ascii
        case 1:
            encoding = .utf16
        case 2:
            encoding = .utf16BigEndian
        case 3:
            encoding = .utf8
        default:
            encoding = .ascii
        }
        return encoding
    }
    
    /// Reads a string from data with a given encoding and size, handling terminators.
    func readString(data: Data, offset: inout Int, size: Int, encoding: String.Encoding, doubleTerminator:Bool) -> String? {
        var bytes: [UInt8] = []
        let endOffset = offset + size
            
        if doubleTerminator {
            let startingOffset = offset
            
            while offset < endOffset {
                let byte = data[offset]
                if byte == 0x0 && offset > startingOffset {
                    if data[offset - 1] == 0x0 {
                        bytes.removeLast()
                        break
                    }
                }
                bytes.append(byte)
                offset += 1
            }
            
            offset += 1
        } else {
            while offset < endOffset {
                let byte: UInt8 = data[offset]

                if byte != 0x00 {
                    bytes.append(byte)
                    offset += 1
                } else {
                    break
                }
            }
            offset += 1
        }
        return String(bytes: bytes, encoding: encoding)
    }
}

/// Represents an MP3 file with ID3v2 tags and provides access to its frames and chapters.
struct ID3V2File {
    var filename:String
    var header:ID3V2Header? = nil
    var frames:[ID3V2Frame] = []
    var chaptersCache:[ID3V2Frame] = []
    
    /// Initializes an ID3V2File from a filename and optional header.
    init(filename: String, header: ID3V2Header? = nil) {
        self.filename = filename
        
        if let url = URL(string: filename) {
            // Read the header
            let fileData = readFileChunk(url: url, offset: 0, size: 10)
            // Initialize the struct from the binary data
            if let header = ID3V2Header(from: fileData) {
                self.header = header
                if header.size > 0 {
                    frames.append(contentsOf: readFrames(url: url, offset: 10, size: Int(header.size)))
                }
                chaptersCache = frames.filter { frame in
                    return frame.frameID == "CHAP"
                }
            }
        }
    }
    
    /// Returns all chapter frames.
    func chapters() -> [ID3V2Frame] {
        return chaptersCache
    }
    
    /// Returns the chapter frame matching the given UUID, if any.
    func chapterWithUUID(_ uuid:UUID) -> ID3V2Frame? {
        if let ch = chapters().first(where: {$0.id == uuid}) {
            return ch
        }
        return nil
    }
    
    /// Reads frames from a file at the given offset and size.
    func readFrames(url: URL, offset:UInt64, size:Int) -> [ID3V2Frame] {
        var f:[ID3V2Frame] = []
        let data = readFileChunk(url: url, offset: offset, size: size)
        var cursor:UInt64 = 0
        
        if !data.isEmpty {
            while cursor < size {
                if let frame = ID3V2Frame(from: data, offset:cursor) {
                    cursor += UInt64(frame.size) + 10
                    f.append(frame)
                } else {
                    break
                }
            }
        }
        
        return f
    }
    
    /// Reads a chunk of data from a file at the given offset and size.
    func readFileChunk(url: URL, offset:UInt64, size:Int) -> Data {
        var buffer = Data() // Initialize an empty Data object to hold the bytes
        
        do {
            // Open the file for reading
            let fileHandle = try FileHandle(forReadingFrom: url)

            defer {
                fileHandle.closeFile() // Ensure the file is closed after reading
            }

            try fileHandle.seek(toOffset: offset)
            
            let chunkData = fileHandle.readData(ofLength: size)
            
            buffer.append(chunkData) // Append chunk to buffer
        } catch {
            print("Failed to read file chunk: \(error.localizedDescription)")
        }
        
        return buffer
    }
}
