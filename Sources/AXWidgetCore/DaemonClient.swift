import Darwin
import Foundation

public enum DaemonClient {
  public static func request(_ operation: String, dataDirectory: URL) throws -> Any {
    let path = Array(dataDirectory.appendingPathComponent("daemon.sock").path.utf8)
    var address = sockaddr_un()
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
      throw AxClient.ClientError.unavailable
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.initializeMemory(as: UInt8.self, repeating: 0)
      buffer.copyBytes(from: path)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw AxClient.ClientError.unavailable }
    defer { close(descriptor) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw AxClient.ClientError.unavailable }
    var request = try JSONSerialization.data(
      withJSONObject: ["operation": operation, "args": [:]] as [String: Any])
    request.append(10)
    try request.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.send(
          descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
        guard count > 0 else { throw AxClient.ClientError.unavailable }
        offset += count
      }
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while result.count < 2_097_152 {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      guard count > 0 else { throw AxClient.ClientError.unavailable }
      result.append(contentsOf: buffer.prefix(count))
      if result.contains(10) { break }
    }
    guard result.count < 2_097_152,
      let response = try JSONSerialization.jsonObject(with: result) as? [String: Any],
      response["ok"] as? Bool == true, let value = response["result"]
    else { throw AxClient.ClientError.invalid }
    return value
  }
}
