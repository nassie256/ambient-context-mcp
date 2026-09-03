import AppKit
import Foundation

import AmbientContextCore

/// C# `WindowsAmbientContextService` の macOS 版。
///
/// Windows は message-only window スレッドで OS イベントと capture を直列化していた。
/// macOS では `actor` がその役割を担う (設計書 §3.2)。OS 通知はメインスレッドで受け取り、
/// Sendable な値に分解してから actor へ転送する。
///
/// 遷移ロジックそのものは Core の `TransitionEvaluator` / `AmbientSnapshotBuilder` にあるので、
/// この型の責務は「収集 → 評価 → 書き出し → 通知」の配線だけ。
///
/// **一時停止 (pause) はこの型の責務ではない。** Windows 版はトレイの `IsPaused` を見てから
/// `hub.Ingest` していたので、macOS でも `snapshotUpdated` コールバックの受け手 (Phase 4 の
/// StatusBar) が Ingest するかどうかを決める。
public actor MacAmbientContextService {
    /// C# `SnapshotIntervalSeconds`。
    public static let captureIntervalSeconds = 60

    /// 遅い capture として診断ログに残すしきい値 (C# と同値)。
    private static let slowCaptureMilliseconds = 2000.0

    /// MainActor 上の収集 (ForegroundAppCollector / DisplayCollector) の締切。
    ///
    /// 設計書 §7.1 バグ 1: モーダルや TCC の同意ダイアログが出ている間、メインの run loop は
    /// 進まない。AX 呼び出し自体にメッセージングタイムアウトを掛けても、そもそも MainActor に
    /// ホップできなければ意味が無いので、**ホップ自体に締切を置く**。超過時は直近の既知の値
    /// (無ければ空) で degrade して capture を完了させる。
    private static let mainActorCollectDeadline: TimeInterval = 2.0

    /// 定期 capture の間隔がこの秒数以上空いたら診断ログに残す (App Nap / スリープ / 詰まりの検知)。
    private static let cadenceDriftSeconds: Double = 90

    private let settingsStore: any SettingsStore
    private let snapshotWriter: AmbientSnapshotWriter
    private let snapshotPathValue: String

    private let presenceCollector = PresenceCollector()
    private let batteryCollector = BatteryCollector()
    private let networkCollector = NetworkCollector()
    private let systemCollector = SystemCollector()
    private let systemLoadCollector = SystemLoadCollector()
    private let mediaCollector = MediaCollector()
    private let powerSettingsMonitor = PowerSettingsMonitor()
    private let scheduler = CaptureScheduler(intervalSeconds: MacAmbientContextService.captureIntervalSeconds)

    private let evaluator: TransitionEvaluator
    private let privacyClassifications: [PrivacyClassification]
    private var transmissionPolicy: AmbientTransmissionPolicy
    private var titleCaptureEnabled = false
    private var mediaCaptureEnabled = false

    private var eventBridge: ServiceEventBridge?
    private var snapshotUpdatedHandler: (@Sendable (AmbientContextSnapshot) -> Void)?
    /// 収集中かどうか。`stop()` は終端ではないので「一度止めたら二度と動かない」フラグは持たない
    /// (`NetworkCollector` / `PowerSettingsMonitor` / `CaptureScheduler` はいずれも
    /// start で資源を作り直すので、start → stop → start が成立する)。
    private var started = false

    /// C# の `_captureGate` (SemaphoreSlim(1,1)) 相当。actor は await をまたぐと再入するため、
    /// capture の開始順 = 完了順 = `latestSnapshot` 反映順を明示的に保証する。
    private var captureBusy = false
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []

    /// 直近の送信用スナップショット。
    public private(set) var latestSnapshot = AmbientContextSnapshot()

    /// MainActor 収集が締切超過したときに使う直近の既知の値。
    private var lastForegroundApp = ForegroundAppContext()
    private var lastDisplays: [DisplayContext] = []

    /// 直近の定期 capture の要求時刻 (cadence drift の計測用)。
    private var lastPeriodicCaptureAt: Date?

    public init(settingsStore: any SettingsStore, snapshotPath: String? = nil) {
        self.settingsStore = settingsStore
        let path = snapshotPath ?? Self.defaultSnapshotPath()
        snapshotPathValue = path
        snapshotWriter = AmbientSnapshotWriter(path: path)

        let classifications = AmbientContextCatalog.getPrivacyClassifications()
        privacyClassifications = classifications
        let policy = AmbientTransmissionPolicy.load(
            store: settingsStore,
            privacyClassifications: classifications)
        transmissionPolicy = policy

        // 初期化フェーズの終了判定に使う件数は、この機種で実際に報告する setting 名の数
        // (クラムシェルを持たない Mac では lid_switch_state が無いので 7 件になる)。
        let monitor = powerSettingsMonitor
        let configuration = TransitionEvaluator.Configuration(
            expectedInitialPowerSettingCount: monitor.expectedInitialSettingCount)

        // lastActivityDate の永続化は C# と同じく設定ストア経由 (best-effort)。
        let store = settingsStore
        evaluator = TransitionEvaluator(
            configuration: configuration,
            lastActivityDate: settingsStore.loadTransientStateSettings().lastActivityDate,
            persistLastActivityDate: { date in
                store.saveTransientStateSettings(
                    TransientStateSettings(schemaVersion: 1, lastActivityDate: date))
            })

        titleCaptureEnabled = CaptureFeatureFlags.isTitleCaptureEnabled(
            policy: policy, privacyClassifications: classifications)
        mediaCaptureEnabled = CaptureFeatureFlags.isMediaCaptureEnabled(
            policy: policy, privacyClassifications: classifications)
    }

    /// C# `GetDefaultSnapshotPath`。設定ファイルと同じディレクトリ
    /// (`~/Library/Application Support/AmbientContextMcp/`) に置く。
    public static func defaultSnapshotPath() -> String {
        let directory = (JsonFileSettingsStore.defaultPath as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("ambient-context.json")
    }

    public var snapshotPath: String { snapshotPathValue }

    /// スナップショット更新の通知先を設定する (C# の `SnapshotUpdated` イベント相当)。
    /// Phase 4 のシェルはここで Hub への Ingest と StatusBar 更新を行う。
    public func setSnapshotUpdatedHandler(_ handler: (@Sendable (AmbientContextSnapshot) -> Void)?) {
        snapshotUpdatedHandler = handler
    }

    /// 収集中かどうか (`stop()` 後は false)。
    public var isStarted: Bool { started }

    // MARK: - ライフサイクル

    /// 収集を開始する。`stop()` の後に呼び直しても再開できる (各モニタは start で作り直す)。
    public func start() async {
        guard !started else { return }
        started = true

        AppDiagnosticLog.shared.configure(settingsPath: settingsStore.settingsPath)
        // NWPathMonitor の最初のパスは非同期に届く。待たずに capture すると起動直後が
        // 必ず offline になり、次の capture で嘘の network_connectivity_changed
        // (offline → online) が出てしまう。上限付きで最初のパスを待つ。
        await networkCollector.startAndWaitForFirstPath()

        let bridge = await ServiceEventBridge(service: self)
        eventBridge = bridge
        await bridge.attach(powerSettingsMonitor: powerSettingsMonitor)

        evaluator.recordMonitorsAttached([
            ("session", "registered"),
            ("foreground", "registered"),
            ("power_setting_notifications", String(powerSettingsMonitor.expectedInitialSettingCount))
        ])

        scheduler.start { [weak self] in
            await self?.requestPeriodicCapture()
        }

        await captureAndStore(reason: "startup")
    }

    /// 収集を止める。終端ではない: `start()` を呼べば再開できる。
    public func stop() async {
        guard started else { return }
        started = false

        scheduler.stop()
        networkCollector.stop()
        if let bridge = eventBridge {
            await bridge.detach(powerSettingsMonitor: powerSettingsMonitor)
        }
        eventBridge = nil
    }

    /// 定期 capture (60 秒) の受け口。
    public func requestPeriodicCapture() async {
        guard started else { return }
        recordPeriodicCadence(at: Date())
        await captureAndStore(reason: "timer")
    }

    /// 定期 capture の到着間隔を見て、`cadenceDriftSeconds` 以上空いていたら記録する。
    /// App Nap でタイマーが間引かれた / capture が詰まっていた / スリープしていた、の
    /// いずれかを後から切り分けるための手掛かり (設計書 §7.1 バグ 1-d)。
    private func recordPeriodicCadence(at now: Date) {
        defer { lastPeriodicCaptureAt = now }
        guard let previous = lastPeriodicCaptureAt else { return }
        let elapsed = now.timeIntervalSince(previous)
        guard elapsed >= Self.cadenceDriftSeconds else { return }
        AppDiagnosticLog.shared.log(
            category: "capture",
            event: "cadence_drift",
            detail: [
                "elapsedSeconds": .int(Int(elapsed.rounded())),
                "intervalSeconds": .int(Self.captureIntervalSeconds)
            ])
    }

    /// 設定保存後に呼ぶ。ポリシーと収集可否フラグを読み直して 1 回 capture する。
    public func reloadTransmissionPolicy() async {
        let policy = AmbientTransmissionPolicy.load(
            store: settingsStore,
            privacyClassifications: privacyClassifications)
        transmissionPolicy = policy
        titleCaptureEnabled = CaptureFeatureFlags.isTitleCaptureEnabled(
            policy: policy, privacyClassifications: privacyClassifications)
        mediaCaptureEnabled = CaptureFeatureFlags.isMediaCaptureEnabled(
            policy: policy, privacyClassifications: privacyClassifications)

        guard started else { return }
        await captureAndStore(reason: "transmission_policy_reloaded")
    }

    /// ウィンドウタイトルを収集する設定になっているか (Phase 4 の権限誘導が参照する)。
    public var isTitleCaptureEnabled: Bool { titleCaptureEnabled }

    /// メディアを収集する設定になっているか (同上)。
    public var isMediaCaptureEnabled: Bool { mediaCaptureEnabled }

    // MARK: - OS イベントの取り込み (ServiceEventBridge から呼ばれる)

    func handleSessionChange(_ change: TransitionEvaluator.SessionChange) async {
        guard started else { return }
        evaluator.recordSessionChange(change)
        let reason: String
        switch change {
        case .locked: reason = "session_locked"
        case .unlocked: reason = "session_unlocked"
        case .logon: reason = "session_logon"
        case .logoff: reason = "session_logoff"
        }
        await captureAndStore(reason: reason)
    }

    func handlePowerBroadcast(_ change: TransitionEvaluator.PowerBroadcast) async {
        guard started else { return }
        evaluator.recordPowerBroadcast(change)
        let reason: String
        switch change {
        case .suspend: reason = "system_suspend"
        case .resumeUser: reason = "system_resume_user"
        case .resumeAutomatic: reason = "system_resume_automatic"
        }
        await captureAndStore(reason: reason)
    }

    /// C# の `OnForegroundEvent` 相当。1000 ms スロットルは evaluator 側が持つ。
    func handleForegroundActivation(at date: Date) async {
        guard started else { return }
        guard evaluator.recordForegroundActivation(at: date) else { return }
        // foreground_changed の emit 点は評価側のみ。ここでは capture を要求するだけ。
        await captureAndStore(reason: "foreground_changed")
    }

    /// 電源系の変化通知。実際の差分は capture 内の `readAll` 比較で求める。
    func handlePowerSettingsChanged() async {
        guard started else { return }
        await captureAndStore(reason: "power_setting_changed")
    }

    /// ディスプレイ構成の変化 (`NSApplication.didChangeScreenParameters`)。
    /// Windows には対応する reason が無いので macOS 固有の理由文字列を使う
    /// (reason は診断ログ専用で、MCP 契約には現れない)。
    func handleDisplayConfigurationChanged() async {
        guard started else { return }
        await captureAndStore(reason: "display_changed")
    }

    // MARK: - capture

    /// C# `CaptureAndStoreAsync`。ゲートで直列化し、遅延と失敗を診断ログに残す。
    func captureAndStore(reason: String) async {
        guard started else { return }

        await acquireCaptureGate()
        defer { releaseCaptureGate() }

        guard started else { return }
        let startedAt = Date()
        let snapshot = await capture()
        guard started else { return }

        latestSnapshot = snapshot
        if !snapshotWriter.write(snapshot) {
            AppDiagnosticLog.shared.log(
                category: "capture",
                event: "snapshot_write_failed",
                detail: ["reason": .string(reason), "path": .string(snapshotPathValue)])
        }
        snapshotUpdatedHandler?(snapshot)

        let durationMs = Date().timeIntervalSince(startedAt) * 1000
        if durationMs >= Self.slowCaptureMilliseconds {
            AppDiagnosticLog.shared.log(
                category: "capture",
                event: "slow",
                detail: [
                    "reason": .string(reason),
                    "durationMs": .int(Int(durationMs.rounded())),
                    "outboundEvents": .int(snapshot.outboundEvents.count)
                ])
        }
    }

    /// C# `CaptureAsync`。収集 → 電源設定の差分取り込み → 評価 → 投影 → ポリシー適用。
    public func capture() async -> AmbientContextSnapshot {
        let observedAt = Date()

        let presence = presenceCollector.collect(sessionLocked: evaluator.sessionLocked)

        let titleEnabled = titleCaptureEnabled
        // MainActor へのホップにも締切を掛ける。同意ダイアログや応答しないアプリで
        // メインの run loop が止まっても、capture (と get_states) は先へ進む。
        let foreground = await boundedOnMainActor(collector: "foreground_app", fallback: lastForegroundApp) {
            ForegroundAppCollector().collect(titleCaptureEnabled: titleEnabled)
        }
        lastForegroundApp = foreground

        let battery = batteryCollector.collect()
        let network = networkCollector.collect()
        // media.* を 1 つも送信しない設定なら Apple Events を送らない
        // (オートメーション権限プロンプトを opt-in していないユーザに出さないため)。
        let media = mediaCaptureEnabled
            ? await mediaCollector.collect()
            : MediaContext(error: "media capture disabled by transmission policy")
        let system = systemCollector.collect(now: observedAt)
        let systemLoad = systemLoadCollector.collect()
        let displays = await boundedOnMainActor(collector: "displays", fallback: lastDisplays) {
            DisplayCollector().collect()
        }
        lastDisplays = displays

        // Windows は OS が個別に push してくる電源設定を、macOS では毎 capture 読み直す。
        // `recordPowerSetting` は初期化フェーズ後は**呼ぶたびに** power_setting_changed を出す
        // (Windows では OS が変化時にしか通知しないため) ので、ここで差分を取ってから渡す。
        // 初期化フェーズでは evaluator 側が空なので全件が 1 度ずつ記録され、
        // expectedInitialPowerSettingCount に到達して初期化が完了する。
        let knownSettings = evaluator.power().lastKnownSettings
        for reading in powerSettingsMonitor.readAll(idleSeconds: presence.idleSeconds)
        where knownSettings[reading.0] != reading.1 {
            evaluator.recordPowerSetting(name: reading.0, value: reading.1)
        }

        let power = evaluator.power()
        let activity = evaluator.activity(at: observedAt)
        let wellness = evaluator.wellness(presence: presence, at: observedAt)

        return AmbientSnapshotBuilder.capture(
            observedAt: observedAt,
            evaluator: evaluator,
            presence: presence,
            foreground: foreground,
            battery: battery,
            network: network,
            media: media,
            power: power,
            system: system,
            systemLoad: systemLoad,
            activity: activity,
            wellness: wellness,
            displays: displays,
            privacyClassifications: privacyClassifications,
            transmissionPolicy: transmissionPolicy)
    }

    /// MainActor 上の収集を `mainActorCollectDeadline` で打ち切る。
    /// 超過したら直近の既知の値 (無ければ空) を返し、診断ログに残す。
    /// 遅れて到着した MainActor の実行結果は捨てる (次の capture で取り直す)。
    private func boundedOnMainActor<Value: Sendable>(
        collector: String,
        fallback: Value,
        _ work: @escaping @MainActor @Sendable () -> Value
    ) async -> Value {
        let value = await BoundedWork.run(seconds: Self.mainActorCollectDeadline) {
            await MainActor.run { work() }
        }
        if let value { return value }
        AppDiagnosticLog.shared.log(
            category: "capture",
            event: "collector_timed_out",
            detail: [
                "collector": .string(collector),
                "deadlineMs": .int(Int(Self.mainActorCollectDeadline * 1000))
            ])
        return fallback
    }

    // MARK: - capture ゲート

    private func acquireCaptureGate() async {
        if !captureBusy {
            captureBusy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            captureWaiters.append(continuation)
        }
    }

    private func releaseCaptureGate() {
        if captureWaiters.isEmpty {
            captureBusy = false
        } else {
            captureWaiters.removeFirst().resume()
        }
    }
}

/// OS 通知をメインスレッドで受け、Sendable な値に分解して actor へ転送する橋渡し。
///
/// `Notification` / `NSRunningApplication` は Sendable でないため、ブロック内で値に落として
/// から `Task` で actor に渡す (設計書 §3.2 / PoC 2 の Swift 6 の罠)。
@MainActor
final class ServiceEventBridge {
    private let service: MacAmbientContextService
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var defaultCenterObservers: [NSObjectProtocol] = []

    init(service: MacAmbientContextService) {
        self.service = service
    }

    func attach(powerSettingsMonitor: PowerSettingsMonitor) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let service = self.service

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            let now = Date()
            Task { await service.handleForegroundActivation(at: now) }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await service.handleSessionChange(.logon) }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await service.handleSessionChange(.logoff) }
        })

        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await service.handlePowerBroadcast(.suspend) }
        })

        // macOS では dark wake がユーザプロセスに届かないため、常に resume_user を発火する
        // (設計書 §3.3 の既知の差分)。
        workspaceObservers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await service.handlePowerBroadcast(.resumeUser) }
        })

        // ロック / アンロックは非公式だが長年安定している DistributedNotificationCenter 経由。
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            distributedObservers.append(distributed.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { notification in
                let locked = notification.name.rawValue == "com.apple.screenIsLocked"
                Task { await service.handleSessionChange(locked ? .locked : .unlocked) }
            })
        }

        defaultCenterObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await service.handleDisplayConfigurationChanged() }
        })

        powerSettingsMonitor.start {
            Task { await service.handlePowerSettingsChanged() }
        }
    }

    func detach(powerSettingsMonitor: PowerSettingsMonitor) {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        distributedObservers.removeAll()

        for observer in defaultCenterObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultCenterObservers.removeAll()

        powerSettingsMonitor.stop()
    }
}
