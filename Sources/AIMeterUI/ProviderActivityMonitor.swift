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

        // The context retains this object for as long as the underlying
        // FSEventStreamRef exists (released via `release` below, which fires
        // from FSEventStreamRelease). Without this, the only thing keeping
        // the Swift wrapper alive is the caller's stored property; if that
        // gets reassigned while a callback is already queued on the dispatch
        // queue, the callback fires against freed memory (EXC_BAD_ACCESS).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<ProviderActivityMonitor>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        let callback: FSEventStreamCallback = {
            _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            // Borrow only — the context above owns the retain/release.
            let monitor = Unmanaged<ProviderActivityMonitor>
                .fromOpaque(info).takeUnretainedValue()
            // Without kFSEventStreamCreateFlagUseCFTypes, eventPaths is a raw
            // `const char *[]`, not a CFArray/NSArray — bitcasting it to
            // NSArray (as an earlier version of this code did) sends real
            // Objective-C messages to what is actually a C string array and
            // crashes. Read it as the C array it is.
            let cPaths = eventPaths.assumingMemoryBound(
                to: UnsafePointer<CChar>.self
            )
            let changed = (0..<numEvents).map { String(cString: cPaths[$0]) }
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
            // No stream was created, so it will never invoke `release` to
            // balance the retain above — release it ourselves.
            Unmanaged<ProviderActivityMonitor>.fromOpaque(context.info!).release()
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
