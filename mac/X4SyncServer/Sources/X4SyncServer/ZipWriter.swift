import Foundation

final class ZipWriter {
  private struct Entry {
    let path: String
    let data: Data
    let crc: UInt32
    let offset: UInt32
  }

  private var data = Data()
  private var entries: [Entry] = []

  func add(path: String, data fileData: Data) {
    let offset = UInt32(data.count)
    let crc = CRC32.checksum(fileData)

    data.appendUInt32LE(0x04034B50)
    data.appendUInt16LE(20)
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt32LE(crc)
    data.appendUInt32LE(UInt32(fileData.count))
    data.appendUInt32LE(UInt32(fileData.count))
    data.appendUInt16LE(UInt16(path.utf8.count))
    data.appendUInt16LE(0)
    data.append(Data(path.utf8))
    data.append(fileData)

    entries.append(Entry(path: path, data: fileData, crc: crc, offset: offset))
  }

  func finalize() -> Data {
    let centralDirectoryOffset = UInt32(data.count)

    for entry in entries {
      data.appendUInt32LE(0x02014B50)
      data.appendUInt16LE(20)
      data.appendUInt16LE(20)
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt32LE(entry.crc)
      data.appendUInt32LE(UInt32(entry.data.count))
      data.appendUInt32LE(UInt32(entry.data.count))
      data.appendUInt16LE(UInt16(entry.path.utf8.count))
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt16LE(0)
      data.appendUInt32LE(0)
      data.appendUInt32LE(entry.offset)
      data.append(Data(entry.path.utf8))
    }

    let centralDirectorySize = UInt32(data.count) - centralDirectoryOffset

    data.appendUInt32LE(0x06054B50)
    data.appendUInt16LE(0)
    data.appendUInt16LE(0)
    data.appendUInt16LE(UInt16(entries.count))
    data.appendUInt16LE(UInt16(entries.count))
    data.appendUInt32LE(centralDirectorySize)
    data.appendUInt32LE(centralDirectoryOffset)
    data.appendUInt16LE(0)

    return data
  }
}

enum CRC32 {
  private static let table: [UInt32] = (0..<256).map { index in
    var crc = UInt32(index)
    for _ in 0..<8 {
      if crc & 1 == 1 {
        crc = 0xEDB88320 ^ (crc >> 1)
      } else {
        crc >>= 1
      }
    }
    return crc
  }

  static func checksum(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      let index = Int((crc ^ UInt32(byte)) & 0xFF)
      crc = table[index] ^ (crc >> 8)
    }
    return crc ^ 0xFFFF_FFFF
  }
}

extension Data {
  mutating func appendUInt16LE(_ value: UInt16) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
  }

  mutating func appendUInt32LE(_ value: UInt32) {
    append(UInt8(value & 0xFF))
    append(UInt8((value >> 8) & 0xFF))
    append(UInt8((value >> 16) & 0xFF))
    append(UInt8((value >> 24) & 0xFF))
  }

  mutating func appendInt32LE(_ value: Int32) {
    appendUInt32LE(UInt32(bitPattern: value))
  }
}
