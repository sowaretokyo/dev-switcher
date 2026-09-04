import DevSwitcherCore
import Foundation
import Observation

/// 解釈できない入力を空文字や0へ補完せず、入力元を示すエラーとして返す。
///
/// 追加と編集で同じモデルを使う。ウィザードへ分割しないので、段階ごとの状態を持たない。
@MainActor
@Observable
final class ProjectFormModel {
    struct PortDraft: Identifiable, Equatable {
        let id: UUID
        var label: String
        var port: String
        var isPrimary: Bool
        var openURL: String

        init(
            id: UUID = UUID(),
            label: String = "",
            port: String = "",
            isPrimary: Bool = false,
            openURL: String = ""
        ) {
            self.id = id
            self.label = label
            self.port = port
            self.isPrimary = isPrimary
            self.openURL = openURL
        }

        var isBlank: Bool {
            label.trimmed.isEmpty && port.trimmed.isEmpty && openURL.trimmed.isEmpty
        }
    }

    /// 1サービス分の入力。
    ///
    /// `id` は編集・並べ替え・削除を通して維持し、新規追加のときだけ発行する。
    /// Milestone 3 で編集しない `stop` もここへ持たせる。配列位置ではなくサービスへ
    /// 結び付けておかないと、並べ替えた瞬間に別サービスの終了コマンドになる。
    struct ServiceDraft: Identifiable, Equatable {
        let id: UUID
        var name: String
        var kind: ServiceKind
        var executable: String
        var argumentsText: String
        /// nil は「プロジェクトディレクトリに従う」という指定。
        /// 保存時にプロジェクトディレクトリを埋めるので、空文字で補完することはない。
        var workingDirectory: URL?
        var ports: [PortDraft]
        var enabledByDefault: Bool
        var failurePolicy: FailurePolicy
        /// Milestone 3 の編集対象外。保存時に欠落させないためだけに持ち回る。
        let preservedStop: CommandSpec?

        init(
            id: UUID = UUID(),
            name: String = "",
            kind: ServiceKind = .web,
            executable: String = "",
            argumentsText: String = "",
            workingDirectory: URL? = nil,
            ports: [PortDraft] = [PortDraft(isPrimary: true)],
            enabledByDefault: Bool = true,
            failurePolicy: FailurePolicy = .block,
            preservedStop: CommandSpec? = nil
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.executable = executable
            self.argumentsText = argumentsText
            self.workingDirectory = workingDirectory
            self.ports = ports
            self.enabledByDefault = enabledByDefault
            self.failurePolicy = failurePolicy
            self.preservedStop = preservedStop
        }

        /// 保存済みの定義を読み込む。
        ///
        /// 作業ディレクトリがプロジェクトと同じなら「プロジェクトに従う」として持つ。
        /// 具体値のまま抱えると、プロジェクトディレクトリを移したときに古い場所が残る。
        init(service: ServiceDefinition, projectDirectory: URL) {
            let workingDirectory = service.start.workingDirectory
            let followsProject = workingDirectory.standardizedFileURL
                == projectDirectory.standardizedFileURL
            // ポートは全サービスで任意。種別から既定値を自動入力しない。
            // 入力された番号は表示と「開く」URL の補助情報であり、起動可否の根拠にしない。
            let existingPorts = service.ports.map { port in
                PortDraft(
                    id: port.id,
                    label: port.label ?? "",
                    port: String(port.port),
                    isPrimary: port.isPrimary,
                    openURL: port.openURL ?? ""
                )
            }
            self.init(
                id: service.id,
                name: service.name,
                kind: service.kind,
                executable: service.start.executable,
                argumentsText: service.start.arguments.joined(separator: "\n"),
                workingDirectory: followsProject ? nil : workingDirectory,
                // 空の行を1つ置くのは入力欄を出すためで、既定値ではない。
                // 空欄のまま保存すれば、ポートを持たないサービスとして保存する。
                ports: existingPorts.isEmpty ? [PortDraft(isPrimary: true)] : existingPorts,
                enabledByDefault: service.enabledByDefault,
                failurePolicy: service.failurePolicy,
                preservedStop: service.stop
            )
        }

        var parsedArguments: [String] {
            argumentsText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    private let projectID: UUID
    /// 編集画面が扱わない値。保存時に落とすと利用者の指定が黙って消える。
    /// サービスの増減で参照先が変わる場合だけ、決められた規則で更新する。
    private let preservedStopOrder: [UUID]?
    private let preservedEnabledNow: [UUID: Bool]

    var name: String
    var color: ProjectColor
    var directory: URL?
    /// 配列順が起動順。終了順は既定でこの逆。
    var services: [ServiceDraft]

    var errorMessages: [String] = []

    init(project: ProjectDefinition? = nil) {
        projectID = project?.id ?? UUID()
        preservedStopOrder = project?.stopOrder
        preservedEnabledNow = project?.enabledNow ?? [:]
        name = project?.name ?? ""
        color = project?.color ?? .blue
        directory = project?.directory
        if let project {
            services = project.services.map {
                ServiceDraft(service: $0, projectDirectory: project.directory)
            }
        } else {
            services = [ServiceDraft()]
        }
    }

    /// 終了順を明示的に指定しているか。編集画面では変えないので、表示のためだけに使う。
    var hasExplicitStopOrder: Bool { preservedStopOrder != nil }

    // MARK: - サービスの追加・削除・並べ替え

    func addService() {
        services.append(ServiceDraft())
    }

    func removeService(_ id: UUID) {
        services.removeAll { $0.id == id }
    }

    func moveService(_ id: UUID, by offset: Int) {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard services.indices.contains(destination) else { return }
        services.swapAt(index, destination)
    }

    func canMoveService(_ id: UUID, by offset: Int) -> Bool {
        guard let index = services.firstIndex(where: { $0.id == id }) else { return false }
        return services.indices.contains(index + offset)
    }

    // MARK: - ポート

    func addPort(to serviceID: UUID) {
        guard let index = services.firstIndex(where: { $0.id == serviceID }) else { return }
        services[index].ports.append(PortDraft(isPrimary: services[index].ports.isEmpty))
    }

    func removePort(_ portID: UUID, from serviceID: UUID) {
        guard let index = services.firstIndex(where: { $0.id == serviceID }) else { return }
        services[index].ports.removeAll { $0.id == portID }
    }

    /// 代表ポートは同じサービス内で1つだけ。別サービスの指定には触れない。
    func makePrimary(_ portID: UUID, in serviceID: UUID) {
        guard let index = services.firstIndex(where: { $0.id == serviceID }) else { return }
        for portIndex in services[index].ports.indices {
            services[index].ports[portIndex].isPrimary =
                services[index].ports[portIndex].id == portID
        }
    }

    // MARK: - 保存

    /// 不正値をドメイン型へ持ち込まないよう、フォームとの境界で検証する。
    func build() throws -> ProjectDefinition {
        var portErrors: [ValidationError] = []
        var parsedPorts: [[PortSpec]] = []
        for (index, draft) in services.enumerated() {
            let (ports, errors) = parsePorts(of: draft, serviceLabel: label(at: index))
            parsedPorts.append(ports)
            portErrors += errors
        }

        guard let directory else {
            throw ValidationFailure(errors: missingRequiredFieldErrors() + portErrors)
        }

        let serviceDefinitions = services.enumerated().map { index, draft in
            ServiceDefinition(
                id: draft.id,
                name: draft.name.trimmed,
                kind: draft.kind,
                ports: parsedPorts[index],
                start: CommandSpec(
                    executable: draft.executable.trimmed,
                    arguments: draft.parsedArguments,
                    // 未指定はプロジェクトディレクトリに従うという指定。
                    // 空文字やカレントディレクトリへは倒さない。
                    workingDirectory: draft.workingDirectory ?? directory
                ),
                stop: draft.preservedStop,
                enabledByDefault: draft.enabledByDefault,
                failurePolicy: draft.failurePolicy
            )
        }

        let serviceIDs = serviceDefinitions.map(\.id)
        let remaining = Set(serviceIDs)
        let project = ProjectDefinition(
            id: projectID,
            name: name.trimmed,
            color: color,
            directory: directory,
            services: serviceDefinitions,
            stopOrder: ProjectFormModel.stopOrder(
                preserving: preservedStopOrder,
                for: serviceIDs
            ),
            // 消えたサービスの指定だけを外す。残ったサービスの指定はそのまま持ち越す。
            enabledNow: preservedEnabledNow.filter { remaining.contains($0.key) }
        )

        let errors = portErrors + ProjectValidator.validate(project)
        guard errors.isEmpty else { throw ValidationFailure(errors: errors) }
        return project
    }

    /// 明示的な終了順を、サービスの増減に合わせて更新する。
    ///
    /// 既定（起動順の逆）を使う nil はそのまま nil。指定がある場合は、
    /// 削除されたサービスを外し、追加されたサービスを「起動順の逆」の位置へ入れる。
    /// 全サービスを過不足なく含めないと `ProjectValidator` が拒否するため、
    /// 黙って nil や空配列へ落とさずに作り直す。
    /// 終了順そのものを編集する UI は Milestone 3 の対象外。
    static func stopOrder(preserving preserved: [UUID]?, for services: [UUID]) -> [UUID]? {
        guard let preserved else { return nil }
        let remaining = Set(services)
        var updated = preserved.filter { remaining.contains($0) }

        let known = Set(preserved)
        // 起動順インデックス k のサービスは、既定なら終了順の (n-1-k) 番目に来る。
        // 挿入位置の小さいものから入れると、後続の目標位置がずれない。
        let added = services.enumerated()
            .filter { !known.contains($0.element) }
            .map { (destination: services.count - 1 - $0.offset, id: $0.element) }
            .sorted { $0.destination < $1.destination }
        for entry in added {
            updated.insert(entry.id, at: min(max(entry.destination, 0), updated.count))
        }
        return updated
    }

    private func label(at index: Int) -> String {
        let trimmed = services[index].name.trimmed
        return trimmed.isEmpty ? "#\(index + 1)" : trimmed
    }

    /// ディレクトリ未選択で `ProjectDefinition` を組み立てられないときに、
    /// 欠けている必須値をまとめて返す。1件ずつ直させないための併記。
    private func missingRequiredFieldErrors() -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmed.isEmpty {
            errors.append(.projectNameEmpty)
        }
        errors.append(.projectDirectoryEmpty)
        if services.isEmpty {
            errors.append(.noServices)
        }
        for (index, draft) in services.enumerated() {
            if draft.name.trimmed.isEmpty {
                errors.append(.serviceNameEmpty(serviceIndex: index))
            }
            if draft.executable.trimmed.isEmpty {
                errors.append(.executableEmpty(service: label(at: index)))
            }
        }
        return errors
    }

    private func parsePorts(
        of draft: ServiceDraft,
        serviceLabel: String
    ) -> ([PortSpec], [ValidationError]) {
        var portSpecs: [PortSpec] = []
        var errors: [ValidationError] = []

        for port in draft.ports where !port.isBlank {
            let portText = port.port.trimmed
            guard let portNumber = Int(portText), !portText.isEmpty else {
                errors.append(.portNotANumber(service: serviceLabel, value: port.port))
                continue
            }
            portSpecs.append(
                PortSpec(
                    id: port.id,
                    label: port.label.trimmed.isEmpty ? nil : port.label.trimmed,
                    port: portNumber,
                    isPrimary: port.isPrimary,
                    openURL: port.openURL.trimmed.isEmpty ? nil : port.openURL.trimmed
                )
            )
        }
        return (portSpecs, errors)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
