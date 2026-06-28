import Darwin
import Foundation

enum NetworkUtility {
  static func primaryIPv4Address() -> String? {
    var addresses: [(name: String, address: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?

    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
      return nil
    }
    defer { freeifaddrs(ifaddr) }

    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let interface = ptr.pointee
      let flags = Int32(interface.ifa_flags)
      let isUp = (flags & IFF_UP) == IFF_UP
      let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

      guard isUp, !isLoopback, interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else {
        continue
      }

      let name = String(cString: interface.ifa_name)
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        interface.ifa_addr,
        socklen_t(interface.ifa_addr.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )

      if result == 0 {
        let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        addresses.append((name, String(decoding: bytes, as: UTF8.self)))
      }
    }

    return addresses.first(where: { $0.name == "en0" })?.address
      ?? addresses.first(where: { $0.address.hasPrefix("192.168.") })?.address
      ?? addresses.first?.address
  }
}
