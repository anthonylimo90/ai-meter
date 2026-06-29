import CoreServices
import Foundation

/// Recursively watches a set of provider record folders with FSEvents and
/// reports the changed paths. FSEvents (not a per-fd DispatchSource) is used
/// deliberately: provider tools append to session files nested several levels
/// deep, and only a recursive stream catches those. Coalesced by a short
/// latency; ignores AI Meter's own writes.
@MainActor
final class ProviderActivityMonitor {
    private let paths: [String]
    private let onChange: @MainActor ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(paths: [String], onChange: @escaping @MainActor ([String]) -> Void) {
        self.paths = paths
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        let callback: FSEventStreamCallback = {
            _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let monitor = Unmanaged<ProviderActivityMonitor>
                .fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(eventPaths, to: NSArray.self)
                as? [String]) ?? []
            guard !changed.isEmpty else { return }
            // The stream is scheduled on the main queue, so we are on the main
            // actor here.
            MainActor.assumeIsolated { monitor.onChange(changed) }
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,
            flags
        ) else {
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
