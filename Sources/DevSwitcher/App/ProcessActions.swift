import DevSwitcherCore

extension AppState {
    func setEnabledNow(_ enabled: Bool, for service: ServiceDefinition, in project: ProjectDefinition) {
        setEnabledNow(enabled, for: .process(service), in: project)
    }
    func serviceStartBlockedReason(for service: ServiceDefinition, in project: ProjectDefinition) -> String? {
        serviceStartBlockedReason(for: .process(service), in: project)
    }
    func canStartService(_ service: ServiceDefinition, in project: ProjectDefinition) -> Bool {
        canStartService(.process(service), in: project)
    }
    func restartBlockedReason(for service: ServiceDefinition, in project: ProjectDefinition) -> String? {
        restartBlockedReason(for: .process(service), in: project)
    }
    func canRestart(_ service: ServiceDefinition, in project: ProjectDefinition) -> Bool {
        canRestart(.process(service), in: project)
    }
    func restart(_ service: ServiceDefinition, in project: ProjectDefinition) {
        restart(.process(service), in: project)
    }
    func startService(_ service: ServiceDefinition, in project: ProjectDefinition) {
        startService(.process(service), in: project)
    }
}
