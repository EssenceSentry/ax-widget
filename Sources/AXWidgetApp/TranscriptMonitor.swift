import Darwin
import Foundation

/// Observe the existing chat files; discovery still uses the fallback timer.
final class TranscriptMonitor {
  private var sources: [String: DispatchSourceFileSystemObject] = [:]
  private let changed: () -> Void

  init(changed: @escaping () -> Void) { self.changed = changed }

  func watch(_ paths: Set<String>) {
    for path in Set(sources.keys).subtracting(paths) {
      sources.removeValue(forKey: path)?.cancel()
    }
    for path in paths where sources[path] == nil {
      let descriptor = Darwin.open(path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        if let events = self.sources[path]?.data, !events.intersection([.rename, .delete]).isEmpty {
          self.sources.removeValue(forKey: path)?.cancel()
        }
        self.changed()
      }
      source.setCancelHandler { Darwin.close(descriptor) }
      sources[path] = source
      source.resume()
    }
  }

  deinit { sources.values.forEach { $0.cancel() } }
}
