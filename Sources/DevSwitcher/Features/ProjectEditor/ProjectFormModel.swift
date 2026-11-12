import DevSwitcherCore
import Foundation
import Observation

/// 解釈できない入力を空文字や0へ補完せず、入力元を示すエラーとして返す。
///
/// 開発環境の下に名前付き作業ディレクトリを置き、その中へプロセスをまとめる。
/// 同じ場所から起動するプロセスごとにディレクトリを繰り返し入力させない。
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

    /// 起動・停止・状態・ログを個別に持つ1プロセス分の入力。
    struct ServiceDraft: Identifiable, Equatable {
        enum ArgumentsFormat {
            case lines
            case json
        }

        let id: UUID
        var name: String
        var tag: String
        var executable: String
        var argumentsText: String
        /// 改行や前後の空白を含む既存引数は、境界を失わないJSON配列で編集する。
        let argumentsFormat: ArgumentsFormat
        var ports: [PortDraft]
        var enabledByDefault: Bool
        var failurePolicy: FailurePolicy
        var hasStopCommand: Bool
        var stopExecutable: String
        var stopArgumentsJSON: String
        var stopDirectory: URL?

        init(
            id: UUID = UUID(),
            name: String = "",
            tag: String = "",
            executable: String = "",
            argumentsText: String = "",
            argumentsFormat: ArgumentsFormat = .lines,
            ports: [PortDraft] = [PortDraft(isPrimary: true)],
            enabledByDefault: Bool = true,
            failurePolicy: FailurePolicy = .block,
            preservedStop: CommandSpec? = nil
        ) {
            self.id = id
            self.name = name
            self.tag = tag
            self.executable = executable
            self.argumentsText = argumentsText
            self.argumentsFormat = argumentsFormat
            self.ports = ports
            self.enabledByDefault = enabledByDefault
            self.failurePolicy = failurePolicy
            self.hasStopCommand = preservedStop != nil
            self.stopExecutable = preservedStop?.executable ?? ""
            self.stopArgumentsJSON = String(decoding: try! JSONEncoder().encode(preservedStop?.arguments ?? []), as: UTF8.self)
            self.stopDirectory = preservedStop?.workingDirectory
        }

        init(service: ServiceDefinition) {
            let arguments = service.start.arguments
            let lines = arguments.joined(separator: "\n")
            let needsJSON = arguments.contains { $0.rangeOfCharacter(from: .newlines) != nil }
                || Self.parseLines(lines) != arguments
            let argumentsText: String
            if needsJSON {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                    argumentsText = String(decoding: try encoder.encode(arguments), as: UTF8.self)
                } catch {
                    // 文字列配列は常にJSONで表現できる。変換不能を空欄へ置き換えない。
                    preconditionFailure("引数をJSONへ変換できませんでした。\(error)")
                }
            } else {
                argumentsText = lines
            }
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
                tag: service.tag ?? "",
                executable: service.start.executable,
                argumentsText: argumentsText,
                argumentsFormat: needsJSON ? .json : .lines,
                ports: existingPorts.isEmpty ? [PortDraft(isPrimary: true)] : existingPorts,
                enabledByDefault: service.enabledByDefault,
                failurePolicy: service.failurePolicy,
                preservedStop: service.stop
            )
        }

        var parsedArguments: [String] {
            get throws {
                switch argumentsFormat {
                case .lines:
                    return Self.parseLines(argumentsText)
                case .json:
                    do {
                        return try JSONDecoder().decode([String].self, from: Data(argumentsText.utf8))
                    } catch {
                        throw ValidationFailure(errors: [
                            .invalidArgumentsJSON(service: name.trimmed, reason: String(describing: error)),
                        ])
                    }
                }
            }
        }

        private static func parseLines(_ text: String) -> [String] {
            text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    /// 同じ場所から起動するプロセスをまとめる、名前付き作業ディレクトリ。
    struct WorkingDirectoryDraft: Identifiable, Equatable {
        let id: UUID
        var name: String
        var directory: URL?
        var services: [ServiceDraft]
        var stacks: [StackDraft]

        init(
            id: UUID = UUID(),
            name: String = "",
            directory: URL? = nil,
            services: [ServiceDraft] = [ServiceDraft()],
            stacks: [StackDraft] = []
        ) {
            self.id = id
            self.name = name
            self.directory = directory
            self.services = services
            self.stacks = stacks
        }

        init(definition: WorkingDirectoryDefinition, project: ProjectDefinition) {
            self.init(
                id: definition.id,
                name: definition.name,
                directory: definition.directory,
                services: definition.serviceIDs.map { serviceID in
                    guard let service = project.service(id: serviceID) else {
                        preconditionFailure("作業ディレクトリに存在しないプロセス ID が含まれています。")
                    }
                    return ServiceDraft(service: service)
                },
                stacks: definition.stackIDs.map { id in
                    guard let stack = project.managedStacks.first(where: { $0.id == id }) else { preconditionFailure("スタックの定義がありません。") }
                    return StackDraft(stack)
                }
            )
        }
    }

    private let projectID: UUID
    private let preservedStopOrder: [UUID]?
    private let preservedEnabledNow: [UUID: Bool]
    /// schema v1/v2 からの移行時も、作業ディレクトリをまたぐ既存の起動順を保つ。
    private var serviceOrder: [UUID]
    private var stackOrder: [UUID]

    var name: String
    var color: ProjectColor
    var workingDirectories: [WorkingDirectoryDraft]
    var errorMessages: [String] = []

    init(project: ProjectDefinition? = nil) {
        projectID = project?.id ?? UUID()
        preservedStopOrder = project?.stopOrder
        preservedEnabledNow = project?.enabledNow ?? [:]
        name = project?.name ?? ""
        color = project?.color ?? .blue
        if let project {
            workingDirectories = project.workingDirectories.map {
                WorkingDirectoryDraft(definition: $0, project: project)
            }
            serviceOrder = project.services.map(\.id)
            stackOrder = project.managedStacks.map(\.id)
        } else {
            let workingDirectory = WorkingDirectoryDraft()
            workingDirectories = [workingDirectory]
            serviceOrder = workingDirectory.services.map(\.id)
            stackOrder = []
        }
    }

    var hasExplicitStopOrder: Bool { preservedStopOrder != nil }

    /// 旧設定の起動順が、作業ディレクトリ単位の表示順と一致しないか。
    var hasCrossDirectoryServiceOrder: Bool {
        serviceOrder != workingDirectories.flatMap(\.services).map(\.id)
    }

    /// 起動順。新規設定はカードの並びに従い、旧設定の既存順は編集だけで変えない。
    var services: [ServiceDraft] {
        get {
            let groupedServices = workingDirectories.flatMap(\.services)
            let groupedIDs = groupedServices.map(\.id)
            precondition(
                Set(groupedIDs).count == groupedIDs.count
                    && groupedIDs.count == serviceOrder.count
                    && Set(groupedIDs) == Set(serviceOrder),
                "作業ディレクトリのプロセスと起動順が一致していません。"
            )
            let drafts = Dictionary(uniqueKeysWithValues: groupedServices.map { ($0.id, $0) })
            return serviceOrder.map { serviceID in
                guard let service = drafts[serviceID] else {
                    preconditionFailure("起動順に存在しないプロセス ID が含まれています。")
                }
                return service
            }
        }
        set {
            let currentIDs = workingDirectories.flatMap(\.services).map(\.id)
            let newIDs = newValue.map(\.id)
            precondition(
                Set(currentIDs).count == currentIDs.count
                    && Set(newIDs).count == newIDs.count
                    && currentIDs.count == newIDs.count
                    && Set(currentIDs) == Set(newIDs),
                "プロセスの追加・削除は専用の操作を使用してください。"
            )
            var updatedByID = Dictionary(uniqueKeysWithValues: newValue.map { ($0.id, $0) })
            for directoryIndex in workingDirectories.indices {
                for serviceIndex in workingDirectories[directoryIndex].services.indices {
                    let serviceID = workingDirectories[directoryIndex].services[serviceIndex].id
                    if let updated = updatedByID.removeValue(forKey: serviceID) {
                        workingDirectories[directoryIndex].services[serviceIndex] = updated
                    }
                }
            }
            precondition(updatedByID.isEmpty, "更新したプロセスを作業ディレクトリへ反映できませんでした。")
            serviceOrder = newValue.map(\.id)
        }
    }

    // MARK: - 作業ディレクトリ

    func addWorkingDirectory() {
        let workingDirectory = WorkingDirectoryDraft()
        workingDirectories.append(workingDirectory)
        serviceOrder.append(contentsOf: workingDirectory.services.map(\.id))
    }

    func removeWorkingDirectory(_ id: UUID) {
        guard let workingDirectory = workingDirectories.first(where: { $0.id == id }) else {
            preconditionFailure("存在しない作業ディレクトリを削除できません。")
        }
        let removedServiceIDs = Set(workingDirectory.services.map(\.id))
        workingDirectories.removeAll { $0.id == id }
        serviceOrder.removeAll { removedServiceIDs.contains($0) }
        let removedStackIDs = Set(workingDirectory.stacks.map(\.id))
        stackOrder.removeAll { removedStackIDs.contains($0) }
    }

    func moveWorkingDirectory(_ id: UUID, by offset: Int) {
        guard let index = workingDirectories.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard workingDirectories.indices.contains(destination) else { return }
        workingDirectories.swapAt(index, destination)
        serviceOrder = workingDirectories.flatMap(\.services).map(\.id)
        stackOrder = workingDirectories.flatMap(\.stacks).map(\.id)
    }

    func canMoveWorkingDirectory(_ id: UUID, by offset: Int) -> Bool {
        guard let index = workingDirectories.firstIndex(where: { $0.id == id }) else { return false }
        return workingDirectories.indices.contains(index + offset)
    }

    // MARK: - プロセス

    func addService(to workingDirectoryID: UUID) {
        guard let index = workingDirectories.firstIndex(where: { $0.id == workingDirectoryID }) else {
            preconditionFailure("存在しない作業ディレクトリへプロセスを追加できません。")
        }
        let service = ServiceDraft()
        let existingIDs = workingDirectories[index].services.map(\.id)
        workingDirectories[index].services.append(service)

        if let lastID = existingIDs.last {
            guard let lastIndex = serviceOrder.firstIndex(of: lastID) else {
                preconditionFailure("作業ディレクトリ内のプロセスが起動順に含まれていません。")
            }
            serviceOrder.insert(service.id, at: lastIndex + 1)
        } else {
            let followingServiceIDs = Set(
                workingDirectories
                    .dropFirst(index + 1)
                    .flatMap(\.services)
                    .map(\.id)
            )
            let insertionIndex = serviceOrder.firstIndex {
                followingServiceIDs.contains($0)
            } ?? serviceOrder.endIndex
            serviceOrder.insert(service.id, at: insertionIndex)
        }
    }

    /// 先頭の作業ディレクトリへ追加する簡便API。
    func addService() {
        guard let firstID = workingDirectories.first?.id else {
            preconditionFailure("作業ディレクトリが無い状態でプロセスを追加できません。")
        }
        addService(to: firstID)
    }

    func removeService(_ id: UUID) {
        guard serviceOrder.contains(id), workingDirectories.contains(where: {
            $0.services.contains { $0.id == id }
        }) else {
            preconditionFailure("存在しないプロセスを削除できません。")
        }
        for index in workingDirectories.indices {
            workingDirectories[index].services.removeAll { $0.id == id }
        }
        serviceOrder.removeAll { $0 == id }
    }

    func moveService(_ id: UUID, by offset: Int) {
        guard let directoryIndex = workingDirectories.firstIndex(where: {
            $0.services.contains { $0.id == id }
        }), let serviceIndex = workingDirectories[directoryIndex].services.firstIndex(where: {
            $0.id == id
        }) else { return }
        let destination = serviceIndex + offset
        guard workingDirectories[directoryIndex].services.indices.contains(destination) else { return }
        let otherID = workingDirectories[directoryIndex].services[destination].id
        workingDirectories[directoryIndex].services.swapAt(serviceIndex, destination)
        guard let orderIndex = serviceOrder.firstIndex(of: id),
              let otherOrderIndex = serviceOrder.firstIndex(of: otherID) else {
            preconditionFailure("プロセスの起動順が破損しています。")
        }
        serviceOrder.swapAt(orderIndex, otherOrderIndex)
    }

    func canMoveService(_ id: UUID, by offset: Int) -> Bool {
        guard let directory = workingDirectories.first(where: {
            $0.services.contains { $0.id == id }
        }), let index = directory.services.firstIndex(where: { $0.id == id }) else { return false }
        return directory.services.indices.contains(index + offset)
    }

    /// SwiftUI が削除アニメーション中の行を再評価する間は、削除済み ID なら nil を返す。
    /// 保存時のデータ整合性は `services` の precondition で別途保証する。
    func positionIfPresent(of serviceID: UUID) -> Int? {
        serviceOrder.firstIndex(of: serviceID).map { $0 + 1 }
    }

    // MARK: - ポート

    func addPort(to serviceID: UUID) {
        updateService(serviceID) { service in
            service.ports.append(PortDraft(isPrimary: service.ports.isEmpty))
        }
    }

    func removePort(_ portID: UUID, from serviceID: UUID) {
        updateService(serviceID) { service in
            guard service.ports.contains(where: { $0.id == portID }) else {
                preconditionFailure("存在しないポートを削除できません。")
            }
            service.ports.removeAll { $0.id == portID }
        }
    }

    func makePrimary(_ portID: UUID, in serviceID: UUID) {
        updateService(serviceID) { service in
            guard service.ports.contains(where: { $0.id == portID }) else {
                preconditionFailure("存在しないポートを代表に設定できません。")
            }
            for portIndex in service.ports.indices {
                service.ports[portIndex].isPrimary = service.ports[portIndex].id == portID
            }
        }
    }

    private func updateService(_ id: UUID, _ update: (inout ServiceDraft) -> Void) {
        for directoryIndex in workingDirectories.indices {
            guard let serviceIndex = workingDirectories[directoryIndex].services.firstIndex(where: {
                $0.id == id
            }) else { continue }
            update(&workingDirectories[directoryIndex].services[serviceIndex])
            return
        }
        preconditionFailure("存在しないプロセスを更新できません。")
    }

    func addStack(_ type: ManagedStackType, to directoryID: UUID) {
        guard let index = workingDirectories.firstIndex(where: { $0.id == directoryID }) else { preconditionFailure("作業ディレクトリがありません。") }
        let draft = StackDraft(type: type)
        workingDirectories[index].stacks.append(draft)
        stackOrder.append(draft.id)
    }
    func removeStack(_ id: UUID) {
        precondition(stackOrder.contains(id), "スタックがありません。")
        for index in workingDirectories.indices { workingDirectories[index].stacks.removeAll { $0.id == id } }
        stackOrder.removeAll { $0 == id }
    }
    func moveStack(_ id: UUID, by offset: Int) {
        guard let index = stackOrder.firstIndex(of: id), stackOrder.indices.contains(index + offset) else { return }
        stackOrder.swapAt(index, index + offset)
        let positions = Dictionary(uniqueKeysWithValues: stackOrder.enumerated().map { ($0.element, $0.offset) })
        for index in workingDirectories.indices {
            workingDirectories[index].stacks.sort { positions[$0.id]! < positions[$1.id]! }
        }
    }
    func stackPosition(_ id: UUID) -> Int? { stackOrder.firstIndex(of: id).map { $0 + 1 } }

    // MARK: - 保存

    func build() throws -> ProjectDefinition {
        var parsedPorts: [UUID: [PortSpec]] = [:]
        var portErrors: [ValidationError] = []
        for (index, draft) in services.enumerated() {
            let (ports, errors) = parsePorts(of: draft, serviceLabel: label(for: draft, at: index))
            parsedPorts[draft.id] = ports
            portErrors += errors
        }

        let requiredErrors = missingRequiredFieldErrors()
        guard requiredErrors.isEmpty else {
            let structuralPortErrors = services.enumerated().flatMap { index, draft in
                guard let ports = parsedPorts[draft.id] else {
                    preconditionFailure("解析済みのポートが見つかりません。")
                }
                return ProjectValidator.portErrors(
                    for: ports,
                    serviceLabel: label(for: draft, at: index)
                )
            }
            throw ValidationFailure(errors: requiredErrors + portErrors + structuralPortErrors)
        }

        var definitionsByID: [UUID: ServiceDefinition] = [:]
        var stacksByID: [UUID: ManagedStackDefinition] = [:]
        var directoryDefinitions: [WorkingDirectoryDefinition] = []

        for directoryDraft in workingDirectories {
            guard let directory = directoryDraft.directory else {
                preconditionFailure("必須項目の検証後に作業ディレクトリが欠落しています。")
            }
            var serviceIDs: [UUID] = []
            for draft in directoryDraft.services {
                guard let ports = parsedPorts[draft.id] else {
                    preconditionFailure("解析済みのポートが見つかりません。")
                }
                let service = ServiceDefinition(
                    id: draft.id,
                    name: draft.name.trimmed,
                    tag: draft.tag.trimmed.isEmpty ? nil : draft.tag.trimmed,
                    ports: ports,
                    start: CommandSpec(
                        executable: draft.executable.trimmed,
                        arguments: try draft.parsedArguments,
                        workingDirectory: directory
                    ),
                    stop: try draft.stopCommand(workingDirectory: directory),
                    enabledByDefault: draft.enabledByDefault,
                    failurePolicy: draft.failurePolicy
                )
                definitionsByID[service.id] = service
                serviceIDs.append(service.id)
            }
            for draft in directoryDraft.stacks {
                stacksByID[draft.id] = try draft.build(directory: directory)
            }
            directoryDefinitions.append(
                WorkingDirectoryDefinition(
                    id: directoryDraft.id,
                    name: directoryDraft.name.trimmed,
                    directory: directory,
                    serviceIDs: serviceIDs,
                    stackIDs: directoryDraft.stacks.map(\.id)
                )
            )
        }

        let definitions = serviceOrder.map { serviceID in
            guard let service = definitionsByID[serviceID] else {
                preconditionFailure("起動順に存在しないプロセス ID が含まれています。")
            }
            return service
        }

        let serviceIDs = definitions.map(\.id)
        let remaining = Set(serviceIDs + stackOrder)
        let project = ProjectDefinition(
            id: projectID,
            name: name.trimmed,
            color: color,
            workingDirectories: directoryDefinitions,
            services: definitions,
            managedStacks: stackOrder.map { id in
                guard let stack = stacksByID[id] else { preconditionFailure("スタックの起動順が不正です。") }
                return stack
            },
            stopOrder: ProjectFormModel.stopOrder(
                preserving: preservedStopOrder,
                for: serviceIDs
            ),
            enabledNow: preservedEnabledNow.filter { remaining.contains($0.key) }
        )

        let errors = portErrors + ProjectValidator.validate(project)
        guard errors.isEmpty else { throw ValidationFailure(errors: errors) }
        return project
    }

    static func stopOrder(preserving preserved: [UUID]?, for services: [UUID]) -> [UUID]? {
        guard let preserved else { return nil }
        let remaining = Set(services)
        var updated = preserved.filter { remaining.contains($0) }

        let known = Set(preserved)
        let added = services.enumerated()
            .filter { !known.contains($0.element) }
            .map { (destination: services.count - 1 - $0.offset, id: $0.element) }
            .sorted { $0.destination < $1.destination }
        for entry in added {
            updated.insert(entry.id, at: min(max(entry.destination, 0), updated.count))
        }
        return updated
    }

    private func label(for draft: ServiceDraft, at index: Int) -> String {
        let trimmed = draft.name.trimmed
        return trimmed.isEmpty ? "#\(index + 1)" : trimmed
    }

    private func missingRequiredFieldErrors() -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmed.isEmpty { errors.append(.projectNameEmpty) }
        if workingDirectories.isEmpty { errors.append(.noWorkingDirectories) }
        if services.isEmpty && workingDirectories.flatMap(\.stacks).isEmpty { errors.append(.noServices) }

        var serviceIndex = 0
        for (directoryIndex, directory) in workingDirectories.enumerated() {
            let directoryName = directory.name.trimmed
            let directoryLabel = directoryName.isEmpty ? "#\(directoryIndex + 1)" : directoryName
            if directoryName.isEmpty {
                errors.append(.workingDirectoryNameEmpty(directoryIndex: directoryIndex))
            }
            if directory.directory == nil {
                errors.append(.workingDirectoryPathEmpty(name: directoryLabel))
            }
            if directory.services.isEmpty && directory.stacks.isEmpty {
                errors.append(.workingDirectoryHasNoServices(name: directoryLabel))
            }
            for stack in directory.stacks where stack.name.trimmed.isEmpty {
                errors.append(.serviceNameEmpty(serviceIndex: serviceIndex))
                serviceIndex += 1
            }
            for service in directory.services {
                if service.name.trimmed.isEmpty {
                    errors.append(.serviceNameEmpty(serviceIndex: serviceIndex))
                }
                if service.executable.trimmed.isEmpty {
                    errors.append(.executableEmpty(service: label(for: service, at: serviceIndex)))
                }
                serviceIndex += 1
            }
        }
        return errors
    }

    private func parsePorts(
        of draft: ServiceDraft,
        serviceLabel: String
    ) -> ([PortSpec], [ValidationError]) {
        Self.tryParsePorts(draft.ports, serviceLabel: serviceLabel)
    }

    static func tryParsePorts(_ drafts: [PortDraft], serviceLabel: String) -> ([PortSpec], [ValidationError]) {
        var portSpecs: [PortSpec] = []
        var errors: [ValidationError] = []
        for port in drafts where !port.isBlank {
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
