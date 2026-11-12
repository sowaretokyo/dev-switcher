import Foundation

public enum ProcessStopMethod: Equatable, Sendable {
    case signal
    case command(CommandSpec)
}

extension ProjectDefinition {
    /// 残存した停止コマンドは、保存時の設定と一致する親プロセスがある場合だけ再検証する。
    public func runtimeEntry(for hint: RuntimeHint) -> LaunchUnit? {
        guard let parentID = hint.stopCommandFor else { return entry(id: hint.serviceID) }
        guard let parent = service(id: parentID), let command = hint.stopCommand,
              parent.stop == command else { return nil }
        return .process(ServiceDefinition(id: hint.serviceID, name: hint.serviceName, ports: [], start: command, enabledByDefault: false, failurePolicy: .block))
    }
}
