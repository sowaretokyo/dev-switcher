import Foundation

/// Compose の JSON Lines と旧 JSON 配列を受け付ける。欠落・別プロジェクト・未知状態は停止中にしない。
public enum ComposePsParser {
    private struct Container: Decodable {
        let ID: String
        let Project: String
        let State: String
        let Health: String
    }
    public static func observation(_ text: String, identity: ManagedStackIdentity) -> ManagedStackObservation {
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let containers: [Container]
            if trimmed.isEmpty { containers = [] }
            else if trimmed.hasPrefix("[") { containers = try JSONDecoder().decode([Container].self, from: Data(trimmed.utf8)) }
            else {
                containers = try trimmed.split(whereSeparator: \.isNewline).map {
                    try JSONDecoder().decode(Container.self, from: Data($0.utf8))
                }
            }
            var normal = 0, abnormal = 0, stopped = 0
            var ids: Set<String> = []
            for container in containers {
                guard !container.ID.isEmpty, ids.insert(container.ID).inserted, container.Project == identity.value else {
                    throw ComposeConfigurationError.invalid(L10n.text("コンテナの ID またはプロジェクト名が不正です。"))
                }
                switch (container.State, container.Health) {
                case ("running", ""), ("running", "healthy"): normal += 1
                case ("running", "unhealthy"), ("restarting", _), ("paused", _): abnormal += 1
                case ("exited", _), ("created", _), ("dead", _): stopped += 1
                default: throw ComposeConfigurationError.invalid(L10n.text("コンテナ「\(container.ID)」の状態を確定できません（\(container.State), health: \(container.Health)）。"))
                }
            }
            let state: ManagedStackState = normal + abnormal == 0 ? .notRunning : (abnormal > 0 || stopped > 0 ? .degraded : .running)
            return ManagedStackObservation(identity: identity, state: state)
        } catch {
            return ManagedStackObservation(identity: identity, state: .unknown, detail: L10n.text("Compose の観測結果を解釈できません。\n\(error)"))
        }
    }
}
