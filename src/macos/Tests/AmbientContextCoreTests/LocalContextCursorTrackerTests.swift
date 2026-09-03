import Foundation
import Testing
@testable import AmbientContextCore

@Suite("LocalContextCursorTracker")
struct LocalContextCursorTrackerTests {
    @Test("Advance_records_client_position")
    func advanceRecordsClientPosition() {
        let tracker = LocalContextCursorTracker()
        let now = Date()

        tracker.advance(clientId: "client-a", sequence: 42, now: now)
        let result = tracker.resolve(
            clientId: "client-a", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: now)

        #expect(result.sequence == 42)
        #expect(result.expired == false)
    }

    @Test("PruneStale_removes_entries_past_ttl")
    func pruneStaleRemovesEntriesPastTtl() {
        let tracker = LocalContextCursorTracker()
        let t0 = Date(timeIntervalSince1970: 1_777_593_600) // 2026-05-01T00:00:00Z
        let day: TimeInterval = 24 * 60 * 60

        tracker.advance(clientId: "old-client", sequence: 10, now: t0)
        tracker.advance(clientId: "fresh-client", sequence: 20, now: t0.addingTimeInterval(6 * day))

        let removed = tracker.pruneStale(now: t0.addingTimeInterval(8 * day), ttl: 7 * day)

        #expect(removed == 1)
        #expect(tracker.trackedClientCount == 1)

        // fresh-client は残っているので Resolve で過去の sequence を返す
        let fresh = tracker.resolve(
            clientId: "fresh-client", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: t0.addingTimeInterval(8 * day))
        #expect(fresh.sequence == 20)

        // old-client は落ちているので latestSequence を新規割当する
        let old = tracker.resolve(
            clientId: "old-client", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: t0.addingTimeInterval(8 * day))
        #expect(old.sequence == 100)
    }

    @Test("Resolve_touches_lastSeen_so_active_client_is_not_pruned")
    func resolveTouchesLastSeenSoActiveClientIsNotPruned() {
        let tracker = LocalContextCursorTracker()
        let t0 = Date(timeIntervalSince1970: 1_777_593_600)
        let day: TimeInterval = 24 * 60 * 60

        // 古い時刻で登録
        tracker.advance(clientId: "client-a", sequence: 5, now: t0)

        // 取得 0 件パスでも lastSeen が touch されて、その後 pruning から守られる必要がある。
        _ = tracker.resolve(
            clientId: "client-a", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: t0.addingTimeInterval(6 * day))

        // touch により lastSeen は 6 日地点にあるので、TTL 2 日 / 現在 8 日ではまだ残る。
        let removed = tracker.pruneStale(now: t0.addingTimeInterval(8 * day), ttl: 2 * day)
        #expect(removed == 0)
        #expect(tracker.trackedClientCount == 1)
    }
}
