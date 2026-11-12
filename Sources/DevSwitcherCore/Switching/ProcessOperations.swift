import Foundation

/// プロセス単体の API は、保存モデルのプロセス定義からも呼べる。
extension SwitchCoordinator {
    public func startService(_ service: ServiceDefinition, in project: ProjectDefinition, progress: @escaping ProgressSink = { _ in }, events: @escaping EventSink = { _, _ in }) async throws -> ProjectFact {
        try await startService(.process(service), in: project, progress: progress, events: events)
    }
    public func restart(_ service: ServiceDefinition, in project: ProjectDefinition, progress: @escaping ProgressSink = { _ in }, events: @escaping EventSink = { _, _ in }) async throws -> ProjectFact {
        try await restart(.process(service), in: project, progress: progress, events: events)
    }
    public func servicePhase(_ service: ServiceDefinition, in project: ProjectDefinition) async -> ServicePhase {
        await servicePhase(.process(service), in: project)
    }
    public func stopAfterUnsavedServiceStart(_ service: ServiceDefinition, in project: ProjectDefinition, progress: @escaping ProgressSink = { _ in }) async throws {
        try await stopAfterUnsavedServiceStart(.process(service), in: project, progress: progress)
    }
    public func adopt(_ candidate: HandoffCandidate, service: ServiceDefinition, in project: ProjectDefinition, events: @escaping EventSink = { _, _ in }) async throws {
        try await adopt(candidate, service: .process(service), in: project, events: events)
    }
    public func stopAdopted(_ candidate: HandoffCandidate, service: ServiceDefinition, in project: ProjectDefinition) async throws -> ServiceStopOutcome {
        try await stopAdopted(candidate, service: .process(service), in: project)
    }
    public func stopWithoutAdopting(_ finding: StoppableProcessFinding, service: ServiceDefinition, in project: ProjectDefinition) async throws -> ServiceStopOutcome {
        try await stopWithoutAdopting(finding, service: .process(service), in: project)
    }
}
