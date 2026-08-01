import DevSwitcherCore
import Foundation
import Observation

/// 解釈できない入力を空文字や0へ補完せず、入力元を示すエラーとして返す。
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

    private let projectID: UUID
    private let serviceID: UUID
    private let preservedServices: [ServiceDefinition]

    var name: String
    var color: ProjectColor
    var directory: URL?

    var serviceName: String
    var serviceKind: ServiceKind
    var executable: String
    var argumentsText: String
    var enabledByDefault: Bool
    var failurePolicy: FailurePolicy
    var ports: [PortDraft]

    var errorMessages: [String] = []

    init(project: ProjectDefinition? = nil) {
        let service = project?.services.first

        projectID = project?.id ?? UUID()
        serviceID = service?.id ?? UUID()
        preservedServices = project.map { Array($0.services.dropFirst()) } ?? []
        name = project?.name ?? ""
        color = project?.color ?? .blue
        directory = project?.directory
        serviceName = service?.name ?? ""
        serviceKind = service?.kind ?? .web
        executable = service?.start.executable ?? ""
        argumentsText = service?.start.arguments.joined(separator: "\n") ?? ""
        enabledByDefault = service?.enabledByDefault ?? true
        failurePolicy = service?.failurePolicy ?? .block
        ports = service?.ports.map { port in
            PortDraft(
                id: port.id,
                label: port.label ?? "",
                port: String(port.port),
                isPrimary: port.isPrimary,
                openURL: port.openURL ?? ""
            )
        } ?? [PortDraft(isPrimary: true)]
    }

    func addPort() {
        ports.append(PortDraft(isPrimary: ports.isEmpty))
    }

    func removePort(_ id: UUID) {
        ports.removeAll { $0.id == id }
    }

    func makePrimary(_ id: UUID) {
        for index in ports.indices {
            ports[index].isPrimary = ports[index].id == id
        }
    }

    /// 不正値をドメイン型へ持ち込まないよう、フォームとの境界で検証する。
    func build() throws -> ProjectDefinition {
        let serviceLabel = serviceName.trimmed.isEmpty ? "#1" : serviceName.trimmed
        let (portSpecs, portErrors) = parsePorts(serviceLabel: serviceLabel)

        guard let directory else {
            throw ValidationFailure(
                errors: missingRequiredFieldErrors(serviceLabel: serviceLabel) + portErrors
            )
        }

        let service = ServiceDefinition(
            id: serviceID,
            name: serviceName.trimmed,
            kind: serviceKind,
            ports: portSpecs,
            start: CommandSpec(
                executable: executable.trimmed,
                arguments: parsedArguments,
                workingDirectory: directory
            ),
            enabledByDefault: enabledByDefault,
            failurePolicy: failurePolicy
        )

        let project = ProjectDefinition(
            id: projectID,
            name: name.trimmed,
            color: color,
            directory: directory,
            services: [service] + preservedServices
        )

        let errors = portErrors + ProjectValidator.validate(project)
        guard errors.isEmpty else { throw ValidationFailure(errors: errors) }
        return project
    }

    private var parsedArguments: [String] {
        argumentsText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func missingRequiredFieldErrors(serviceLabel: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.trimmed.isEmpty {
            errors.append(.projectNameEmpty)
        }
        errors.append(.projectDirectoryEmpty)
        if serviceName.trimmed.isEmpty {
            errors.append(.serviceNameEmpty(serviceIndex: 0))
        }
        if executable.trimmed.isEmpty {
            errors.append(.executableEmpty(service: serviceLabel))
        }
        return errors
    }

    private func parsePorts(serviceLabel: String) -> ([PortSpec], [ValidationError]) {
        var portSpecs: [PortSpec] = []
        var errors: [ValidationError] = []

        for draft in ports where !draft.isBlank {
            let portText = draft.port.trimmed
            guard let portNumber = Int(portText), !portText.isEmpty else {
                errors.append(.portNotANumber(service: serviceLabel, value: draft.port))
                continue
            }
            portSpecs.append(
                PortSpec(
                    id: draft.id,
                    label: draft.label.trimmed.isEmpty ? nil : draft.label.trimmed,
                    port: portNumber,
                    isPrimary: draft.isPrimary,
                    openURL: draft.openURL.trimmed.isEmpty ? nil : draft.openURL.trimmed
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
