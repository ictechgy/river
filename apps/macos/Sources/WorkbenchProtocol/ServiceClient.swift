import Darwin
import Foundation

public struct ServiceFailure: Decodable, Error, LocalizedError, Sendable {
  public let code: String
  public let message: String
  public init(code: String, message: String) { self.code = code; self.message = message }
  public var errorDescription: String? { "\(code): \(message)" }
}
public enum TransportFailure: Error, LocalizedError, Sendable {
  case invalidSocketPath, oversizedRequest, invalidReply, oversizedReply
  case unsupportedSchema(Int)
  case system(String, Int32)

  /// Only failures before the first send can rule out a submitted request.
  /// Send/reply failures remain conservative because partial delivery is possible.
  public var requestMayHaveBeenSent: Bool {
    switch self {
    case .invalidSocketPath, .oversizedRequest: false
    case .system(let action, _): !["socket", "timeout 설정", "연결"].contains(action)
    default: true
    }
  }

  public var errorDescription: String? {
    switch self {
    case .invalidSocketPath: "작업 엔진에 연결하지 못했습니다. 저장소를 다시 열어 주세요."
    case .oversizedRequest: "요청이 1 MiB 제한을 초과했습니다."
    case .invalidReply: "서비스가 완전한 JSON 응답을 반환하지 않았습니다."
    case .oversizedReply: "응답이 16 MiB 제한을 초과했습니다."
    case .unsupportedSchema(let version): "지원하지 않는 응답 schema: \(version)"
    case .system(let action, let code): "로컬 서비스 \(action) 실패: \(String(cString: strerror(code)))"
    }
  }
}

public actor ServiceClient {
  private let ioQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "workbench.socket-io"
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 4
    return queue
  }()
  public let socketPath: String
  private let timeoutSeconds: Int
  private let mutationTimeoutSeconds: Int
  private let remoteTimeoutSeconds: Int
  public init(socketPath: String, timeoutSeconds: Int = 30, mutationTimeoutSeconds: Int = 180, remoteTimeoutSeconds: Int = 360) {
    self.socketPath = socketPath
    self.timeoutSeconds = min(30, max(1, timeoutSeconds))
    self.mutationTimeoutSeconds = min(180, max(1, mutationTimeoutSeconds))
    self.remoteTimeoutSeconds = min(360, max(1, remoteTimeoutSeconds))
  }

  public func call<T: Decodable & Sendable>(
    _ method: String, params: [String: JSONValue] = [:], as: T.Type = T.self
  ) async throws -> T {
    let request = try JSONEncoder().encode(ServiceRequest(method: method, params: params))
    let path = socketPath
    let timeout = ["configure_remote", "fetch_remote", "pull_remote", "push_remote"].contains(method)
      ? remoteTimeoutSeconds : (["stage_file", "stage_hunk", "commit"].contains(method) ? mutationTimeoutSeconds : timeoutSeconds)
    let cancellation = SocketCancellation()
    let response: Data = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        cancellation.install(continuation)
        let operation = BlockOperation {
          do {
            try cancellation.check()
            let result = try SocketTransport.exchange(
              path: path, request: request, timeoutSeconds: timeout, cancellation: cancellation)
            try cancellation.check()
            cancellation.complete(.success(result))
          } catch {
            cancellation.complete(.failure(cancellation.isCancelled ? CancellationError() : error))
          }
        }
        cancellation.enqueue(operation)
        ioQueue.addOperation(operation)
      }
    } onCancel: {
      cancellation.cancel()
    }
    let decoded = try await Task.detached(priority: .userInitiated) {
      try Self.decode(response, as: T.self)
    }.value
    try Task.checkCancellation()
    return decoded
  }

  public nonisolated static func decode<T: Decodable & Sendable>(_ data: Data, as: T.Type) throws
    -> T
  {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let reply = try decoder.decode(ServiceReply<T>.self, from: data)
    guard reply.schemaVersion == 1 else {
      throw TransportFailure.unsupportedSchema(reply.schemaVersion)
    }
    if let error = reply.error { throw error }
    guard let result = reply.result else { throw TransportFailure.invalidReply }
    return result
  }
}
private struct ServiceRequest: Encodable {
  let method: String
  let params: [String: JSONValue]
}
private struct ServiceReply<T: Decodable>: Decodable {
  let schemaVersion: Int
  let result: T?
  let error: ServiceFailure?
}

// shutdown wakes a blocked read/write; the I/O operation remains the sole FD owner.
// Locking registration/removal prevents cancellation from touching a reused descriptor.
private final class SocketCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32?
  private var cancelled = false
  private var completed = false
  private var continuation: CheckedContinuation<Data, Error>?
  private weak var operation: BlockOperation?
  var isCancelled: Bool { lock.withLock { cancelled } }
  func install(_ value: CheckedContinuation<Data, Error>) {
    let wasCancelled = lock.withLock {
      if completed { return true }
      continuation = value
      return false
    }
    if wasCancelled { value.resume(throwing: CancellationError()) }
  }
  func enqueue(_ value: BlockOperation) {
    let wasCancelled = lock.withLock {
      operation = value
      return cancelled
    }
    if wasCancelled { value.cancel() }
  }
  func complete(_ result: Result<Data, Error>) {
    let pending = lock.withLock { () -> CheckedContinuation<Data, Error>? in
      guard !completed else { return nil }
      completed = true
      let pending = continuation
      continuation = nil
      operation = nil
      return pending
    }
    pending?.resume(with: result)
  }
  func check() throws { if isCancelled { throw CancellationError() } }
  func register(_ fd: Int32) throws {
    try lock.withLock {
      if cancelled { throw CancellationError() }
      descriptor = fd
    }
  }
  func unregister() { lock.withLock { descriptor = nil } }
  func cancel() {
    let pending = lock.withLock { () -> (CheckedContinuation<Data, Error>?, BlockOperation?) in
      cancelled = true
      if let descriptor { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
      guard !completed else { return (nil, nil) }
      completed = true
      let pending = continuation
      continuation = nil
      return (pending, operation)
    }
    pending.1?.cancel()
    pending.0?.resume(throwing: CancellationError())
  }
}

private enum SocketTransport {
  static func exchange(
    path: String, request: Data, timeoutSeconds: Int, cancellation: SocketCancellation
  ) throws -> Data {
    var address = sockaddr_un()
    let bytes = Array(path.utf8)
    guard path.hasPrefix("/"), !bytes.contains(0),
      bytes.count < MemoryLayout.size(ofValue: address.sun_path)
    else {
      throw TransportFailure.invalidSocketPath
    }
    guard request.count <= 1024 * 1024 else { throw TransportFailure.oversizedRequest }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: bytes)
      buffer[bytes.count] = 0
    }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw TransportFailure.system("socket", errno) }
    defer { cancellation.unregister(); Darwin.close(fd) }
    try cancellation.register(fd)
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    var noSignal: Int32 = 1
    guard
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
    else {
      throw TransportFailure.system("timeout 설정", errno)
    }
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw TransportFailure.system("연결", errno) }
    try cancellation.check()
    var framed = request
    framed.append(0x0A)
    try framed.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        try cancellation.check()
        let sent = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
        if sent < 0 && errno == EINTR { continue }
        guard sent > 0 else { throw TransportFailure.system("전송", errno) }
        offset += sent
      }
    }
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
      try cancellation.check()
      let size = Darwin.recv(fd, &buffer, buffer.count, 0)
      if size < 0 && errno == EINTR { continue }
      guard size > 0 else {
        if size < 0 { throw TransportFailure.system("수신", errno) }
        throw TransportFailure.invalidReply
      }
      response.append(contentsOf: buffer[..<size])
      guard response.count <= 16 * 1024 * 1024 else { throw TransportFailure.oversizedReply }
      if let newline = buffer[..<size].firstIndex(of: 0x0A) {
        return Data(response.prefix(response.count - size + newline))
      }
    }
  }
}
