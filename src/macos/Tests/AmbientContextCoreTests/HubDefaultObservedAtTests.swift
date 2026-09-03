import Foundation
import Testing
@testable import AmbientContextCore

/// `LocalContextHub` の `observedAt` 既定値が C# の `default(DateTimeOffset)` と一致すること。
///
/// C# は `_latestObservedAt` が `default(DateTimeOffset)` = 0001-01-01T00:00:00+00:00 で始まる。
/// Swift 側が Unix epoch (1970-01-01) だと、まだ ingest していない Hub の応答が
/// 「1970 年に観測した」ように見えてしまい、Windows と食い違う。
@Suite("HubDefaultObservedAt")
struct HubDefaultObservedAtTests {
    /// `Date.distantPast` は 0001-01-01T00:00:00Z ちょうど (C# の default と同じ瞬間)。
    @Test("distant_past_is_the_dotnet_default_datetimeoffset")
    func distantPastIsTheDotnetDefault() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date.distantPast)

        #expect(parts.year == 1)
        #expect(parts.month == 1)
        #expect(parts.day == 1)
        #expect(parts.hour == 0)
        #expect(parts.minute == 0)
        #expect(parts.second == 0)
    }

    /// ingest 前の応答は epoch ではなく 0001 年を返す。
    @Test("hub_reports_year_one_before_the_first_ingest")
    func hubReportsYearOneBeforeTheFirstIngest() {
        let hub = LocalContextHubTestFactory.createInMemory()

        let states = hub.getContextStates(LocalContextStateRequest())
        let policy = hub.getPolicy()

        #expect(states.observedAt == Date.distantPast)
        #expect(policy.observedAt == Date.distantPast)
        #expect(states.observedAt != Date(timeIntervalSince1970: 0))
    }

    /// ISO 8601 の書き出しがどのタイムゾーンでも「0001 年の読み戻せる文字列」になること。
    ///
    /// 注意 (既知の差分): この値は Date が表せる下限の番兵なので、書式化には 2 つの癖がある。
    /// 1. 年 1 のオフセットは LMT (例: Asia/Tokyo は +09:18:59) になり、秒は書式上切り捨てられる。
    /// 2. UTC より **西** のゾーンではローカル時刻が紀元前に落ちる。Foundation の
    ///    `dateComponents` は era を落として年を 1 と報告するため、
    ///    `0001-12-31T19:03:58-04:56` のように「1 年後の AD」として読み戻る。
    /// どちらも「まだ何も観測していない」ことを伝える用途では実害が無く、C# が出す
    /// `0001-01-01T00:00:00+00:00` と同じ「0001 年 = 番兵」の読み方ができる。
    /// ここでは (a) 常に 0001 年で始まること (b) 必ず読み戻せること
    /// (c) epoch (1970) には決してならないこと を固定する。
    @Test("year_one_serialises_to_a_parseable_iso8601_string")
    func yearOneSerialisesToAParseableIso8601String() throws {
        for identifier in ["UTC", "Asia/Tokyo", "America/New_York"] {
            let zone = try #require(TimeZone(identifier: identifier))
            let text = AmbientDateFormat.string(from: Date.distantPast, timeZone: zone)

            #expect(text.hasPrefix("0001-"), "\(identifier): 0001 年で始まらない (\(text))")
            _ = try #require(
                AmbientDateFormat.parse(text), "\(identifier): 読み戻せない (\(text))")
        }

        // UTC 以東 (オフセット >= 0) はほぼそのまま往復する。
        for identifier in ["UTC", "Asia/Tokyo"] {
            let zone = try #require(TimeZone(identifier: identifier))
            let text = AmbientDateFormat.string(from: Date.distantPast, timeZone: zone)
            let parsed = try #require(AmbientDateFormat.parse(text))
            // LMT の「秒」が書式で落ちる分だけずれる (1 分未満)。
            #expect(
                abs(parsed.timeIntervalSince(Date.distantPast)) < 60,
                "\(identifier): 往復で 1 分以上ずれた (\(text))")
        }
    }

    /// ingest すればその observedAt に置き換わる (既定値が居座らないこと)。
    @Test("ingest_replaces_the_default_observed_at")
    func ingestReplacesTheDefaultObservedAt() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = try #require(AmbientDateFormat.parse("2026-05-04T10:15:00.123+09:00"))

        hub.ingest(AmbientContextSnapshot(observedAt: observedAt))

        #expect(hub.getContextStates(LocalContextStateRequest()).observedAt == observedAt)
    }
}
