import Foundation

/// Watches the AI Meter support directory and fires a debounced callback when
/// its contents change — i.e. when the Claude Code activity hook atomically
/// replaces `activity.touch` (the `mv` changes the directory, so a single-file
/// `touch` of an existing inode is deliberately avoided on the writer side).
///
/// Watching the directory (not the file) keeps the file descriptor valid across
/// the hook's replace-in-place writes, so there is no re-open dance. The
/// callback runs on the main actor; bursts (e.g. a `stop` immediately followed
/// by `end`) collapse into one call via the debounce.
@MainActor
final class ActivityWatcher {
    private let directory: URL
    private let debounce: Duration
    private let onActivity: @MainActor () -> Void

    private var fileDescriptor: Int32 = -1
    private var source: (any DispatchSourceFileSystemObject)?
    private var debounceTask: Task<Void, Never>?

    init(
        directory: URL,
        debounce: Duration = .seconds(2),
        onActivity: @escaping @MainActor () -> Void
    ) {
        self.directory = directory
        self.debounce = debounce
        self.onActivity = onActivity
    }

    func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Event handler is dispatched on the main queue, so we are already
            // on the main actor here.
            MainActor.assumeIsolated { self?.scheduleCallback() }
        }
        source.setCancelHandler { [weak self] in
            MainActor.assumeIsolated {
                if let self, self.fileDescriptor >= 0 {
                    close(self.fileDescriptor)
                    self.fileDescriptor = -1
                }
            }
        }
        self.source = source
        source.resume()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        source?.cancel()
        source = nil
    }

    private func scheduleCallback() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            self.onActivity()
        }
    }
}
