// RetryQueue.swift — Offline retry queue for failed postback events.
//
// Rules:
//   • Max 100 items.  Oldest are dropped when capacity is exceeded.
//   • Items are persisted in UserDefaults across app launches.
//   • Flush is triggered automatically when NWPathMonitor reports connectivity
//     and can also be called manually via AdSparkle.flushQueue().

import Foundation
import Network

final class RetryQueue {

    private static let maxItems = 100

    private let networkingQueue: DispatchQueue
    private let send: (QueuedEvent, @escaping (Bool) -> Void) -> Void
    private var items: [QueuedEvent]
    private var monitor: NWPathMonitor?
    private var isFlushing = false

    /// - Parameters:
    ///   - networkingQueue: The serial queue shared with the networking layer.
    ///   - send: Closure called to re-attempt a queued event. Returns success via callback.
    init(
        networkingQueue: DispatchQueue,
        send: @escaping (QueuedEvent, @escaping (Bool) -> Void) -> Void
    ) {
        self.networkingQueue = networkingQueue
        self.send = send
        self.items = Self.load()
        startMonitor()
    }

    // MARK: - Queue management

    func enqueue(_ event: QueuedEvent) {
        networkingQueue.async { [weak self] in
            guard let self = self else { return }
            // Deduplicate by event id
            self.items.removeAll { $0.id == event.id }
            self.items.append(event)
            if self.items.count > Self.maxItems {
                self.items.removeFirst(self.items.count - Self.maxItems)
            }
            self.persist()
            AdSparkleLogger.debug("RetryQueue: enqueued \(event.id). Queue size: \(self.items.count)")
        }
    }

    func flush() {
        networkingQueue.async { [weak self] in
            self?.flushInternal()
        }
    }

    // MARK: - Internal flush

    private func flushInternal() {
        guard !isFlushing, !items.isEmpty else { return }
        isFlushing = true
        AdSparkleLogger.debug("RetryQueue: flushing \(items.count) item(s)")

        let pending = items
        var successes: Set<String> = []
        let group = DispatchGroup()

        for event in pending {
            group.enter()
            send(event) { [weak self] succeeded in
                self?.networkingQueue.async {
                    if succeeded {
                        successes.insert(event.id)
                        AdSparkleLogger.debug("RetryQueue: retry succeeded for \(event.id)")
                    } else {
                        AdSparkleLogger.debug("RetryQueue: retry failed for \(event.id)")
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: networkingQueue) { [weak self] in
            guard let self = self else { return }
            self.items.removeAll { successes.contains($0.id) }
            self.persist()
            self.isFlushing = false
            AdSparkleLogger.debug("RetryQueue: flush done. Remaining: \(self.items.count)")
        }
    }

    // MARK: - Network monitoring

    private func startMonitor() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            if path.status == .satisfied {
                AdSparkleLogger.debug("RetryQueue: network available — scheduling flush")
                self.networkingQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.flushInternal()
                }
            }
        }
        m.start(queue: networkingQueue)
        self.monitor = m
    }

    // MARK: - Persistence

    private func persist() {
        Storage.set(items, forKey: Storage.Key.retryQueue)
    }

    private static func load() -> [QueuedEvent] {
        Storage.get([QueuedEvent].self, forKey: Storage.Key.retryQueue) ?? []
    }
}
