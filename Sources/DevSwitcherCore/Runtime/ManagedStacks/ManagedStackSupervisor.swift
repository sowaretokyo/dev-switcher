import Foundation

/// 1つの管理対象スタックに対する管理handle。
///
/// 停止してよいかどうかは、実測状態ではなくここに登録された管理関係が決める。
/// 実測結果は明示的な再観測でのみ更新する（定期ポーリングは行わない）。
actor ManagedStackSupervisor {
    let stack: ResolvedManagedStack
    let relationship: ManagedStackRelationship

    private let driver: any ManagedStackDriver
    private(set) var observation: ManagedStackObservation
    private var continuation: AsyncStream<ServiceSupervisor.Event>.Continuation?

    init(
        stack: ResolvedManagedStack,
        relationship: ManagedStackRelationship,
        observation: ManagedStackObservation,
        driver: any ManagedStackDriver
    ) {
        self.stack = stack
        self.relationship = relationship
        self.observation = observation
        self.driver = driver
    }

    nonisolated var identity: ManagedStackIdentity { stack.identity }

    /// 稼働中と言えるのは`running`だけ。`degraded`と`unknown`は起動済みにしない。
    var isRunning: Bool { observation.state == .running }

    /// 停止導線を出すかどうか。観測できないスタックを「居ない」と決めつけない。
    var isOccupyingResources: Bool { observation.state != .notRunning }

    func makeEventStream() -> AsyncStream<ServiceSupervisor.Event> {
        let (stream, continuation) = AsyncStream<ServiceSupervisor.Event>.makeStream(
            of: ServiceSupervisor.Event.self,
            bufferingPolicy: .unbounded
        )
        self.continuation?.finish()
        self.continuation = continuation
        return stream
    }

    func emit(logs: [LogLine]) {
        guard !logs.isEmpty else { return }
        continuation?.yield(.log(logs))
    }

    func update(observation: ManagedStackObservation) {
        self.observation = observation
    }

    func finishEvents() {
        continuation?.finish()
        continuation = nil
    }

    /// 管理関係のあるスタックだけを、対象限定の停止で停止する。
    /// `known`は同じ種類の、設定が分かっているスタック。
    func stop(known: [ResolvedManagedStack]) async throws -> ServiceStopOutcome {
        do {
            let logs = try await driver.stop(identity, using: stack, known: known)
            emit(logs: logs)
            observation = ManagedStackObservation(identity: identity, state: .notRunning)
            continuation?.yield(
                .exited(status: .exited(code: 0), requestedByUser: true, startupConfirmed: false)
            )
            finishEvents()
            return .stopped(nil)
        } catch {
            // 停止できたかどうかを終了コードだけで決めない。実測し直して状態を残す。
            observation = await driver.observe(known: known).observation(of: identity)
            throw error
        }
    }
}
