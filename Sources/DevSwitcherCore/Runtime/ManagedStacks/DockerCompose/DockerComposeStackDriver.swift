import Foundation

public actor DockerComposeStackDriver: ManagedStackDriver {
    public struct Options: Sendable {
        public var startConfirmationWindow: Duration
        public var stopConfirmationWindow: Duration
        public var pollInterval: Duration
        public init(startConfirmationWindow: Duration = .seconds(60), stopConfirmationWindow: Duration = .seconds(60), pollInterval: Duration = .milliseconds(250)) {
            self.startConfirmationWindow = startConfirmationWindow
            self.stopConfirmationWindow = stopConfirmationWindow
            self.pollInterval = pollInterval
        }
    }
    public nonisolated let type: ManagedStackType = .dockerCompose
    private let runner: any ManagedStackCommandRunning
    private let options: Options
    public private(set) var latestSnapshot: ManagedStackSnapshot?
    private var logID: UInt64 = 0

    public init(runner: any ManagedStackCommandRunning, options: Options = Options()) {
        self.runner = runner; self.options = options
    }
    static func policy(timeout: Duration) -> ManagedStackCommandPolicy {
        ManagedStackCommandPolicy(forbiddenArguments: ComposeCommandRules.forbiddenArguments,
            removedEnvironmentKeys: ComposeCommandRules.removedEnvironmentKeys,
            composeCommandsOnly: true, timeout: timeout)
    }
    public func observe(known: [ResolvedManagedStack]) async -> ManagedStackSnapshot {
        var observations: [ManagedStackObservation] = []
        for stack in known where stack.type == type {
            observations.append(await inspect(stack))
        }
        let result = ManagedStackSnapshot(type: type, observations: observations)
        latestSnapshot = result
        return result
    }
    private func inspect(_ stack: ResolvedManagedStack) async -> ManagedStackObservation {
        do {
            let configuration = try configuration(stack)
            let result = try await runner.run(configuration.observationCommand, policy: Self.policy(timeout: .seconds(60)))
            guard result.isSuccess else {
                return ManagedStackObservation(identity: stack.identity, state: .unknown, detail: L10n.text("Compose の状態確認に失敗しました（\(result.status.description)）。\n\(result.combinedOutput)"))
            }
            return ComposePsParser.observation(result.standardOutput, identity: stack.identity)
        } catch {
            return ManagedStackObservation(identity: stack.identity, state: .unknown, detail: L10n.text("Compose の状態を観測できません。\n\(error)"))
        }
    }
    public func start(_ stack: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine] {
        try await execute(try configuration(stack).startCommand, stack: stack, expected: .running, action: L10n.text("起動"), window: options.startConfirmationWindow)
    }
    public func stop(_ identity: ManagedStackIdentity, using context: ResolvedManagedStack, known: [ResolvedManagedStack]) async throws -> [LogLine] {
        guard identity == context.identity else {
            throw ManagedStackOperationError.commandUnavailable(action: L10n.text("停止"), identity: identity, reason: L10n.text("Compose は設定と同じ ID だけを停止できます。"))
        }
        return try await execute(try configuration(context).stopCommand, stack: context, expected: .notRunning, action: L10n.text("停止"), window: options.stopConfirmationWindow)
    }
    private func configuration(_ stack: ResolvedManagedStack) throws -> DockerComposeResolvedConfiguration {
        guard case let .dockerCompose(configuration) = stack.configuration else {
            throw ManagedStackIdentityError.typeMismatch(expected: type, actual: stack.type)
        }
        try ComposeCommandRules.validateUpArguments(configuration.fingerprint.upArguments)
        return configuration
    }
    private func execute(_ command: CommandSpec, stack: ResolvedManagedStack, expected: ManagedStackState, action: String, window: Duration) async throws -> [LogLine] {
        let result: ManagedStackCommandResult
        do { result = try await runner.run(command, policy: Self.policy(timeout: .seconds(300))) }
        catch { throw ManagedStackOperationError.commandUnavailable(action: action, identity: stack.identity, reason: "\(error)") }
        guard result.isSuccess else {
            throw ManagedStackOperationError.commandFailed(action: action, identity: stack.identity, status: result.status, output: result.combinedOutput)
        }
        let deadline = ContinuousClock.now + window
        var observation = await inspect(stack)
        while observation.state != expected, ContinuousClock.now < deadline {
            try await Task.sleep(for: min(options.pollInterval, deadline - ContinuousClock.now))
            observation = await inspect(stack)
        }
        latestSnapshot = ManagedStackSnapshot(type: type, observations: (latestSnapshot?.observations.filter { $0.identity != observation.identity } ?? []) + [observation])
        guard observation.state == expected else {
            throw ManagedStackOperationError.stateNotConfirmed(action: action, identity: stack.identity, expected: expected, actual: observation.state, detail: observation.detail)
        }
        return [(result.standardOutput, LogLine.Stream.stdout), (result.standardError, .stderr)].flatMap { text, stream in
            text.split(whereSeparator: \.isNewline).map {
                defer { logID += 1 }
                return LogLine(id: logID, timestamp: Date(), stream: stream, text: String($0))
            }
        }
    }
}
