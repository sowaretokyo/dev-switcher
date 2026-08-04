import Foundation

/// リポジトリの移動で保存済み設定まで読めなくならないよう、構造検証と実在確認を分ける。
/// ディレクトリが見つからない場合は登録時または起動時に失敗させる。
public enum ProjectValidator {
    public static func validate(
        _ project: ProjectDefinition,
        existingProjects: [ProjectDefinition] = []
    ) -> [ValidationError] {
        structuralErrors(project, existingProjects: existingProjects) + filesystemErrors(project)
    }

    public static func check(
        _ project: ProjectDefinition,
        existingProjects: [ProjectDefinition] = []
    ) throws {
        let errors = validate(project, existingProjects: existingProjects)
        guard errors.isEmpty else { throw ValidationFailure(errors: errors) }
    }

    public static func structuralErrors(
        _ project: ProjectDefinition,
        existingProjects: [ProjectDefinition] = []
    ) -> [ValidationError] {
        var errors: [ValidationError] = []

        let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            errors.append(.projectNameEmpty)
        }

        for other in existingProjects where other.id != project.id {
            if other.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame,
               !name.isEmpty {
                errors.append(.duplicateProjectName(other.name))
            }
        }
        if existingProjects.contains(where: { $0.id == project.id }) {
            errors.append(.duplicateProjectID(project.id))
        }

        let directoryPath = project.directory.path
        if directoryPath.isEmpty {
            errors.append(.projectDirectoryEmpty)
        } else if !directoryPath.hasPrefix("/") {
            errors.append(.projectDirectoryNotAbsolute(directoryPath))
        }

        if project.services.isEmpty {
            errors.append(.noServices)
        }

        var seenServiceIDs: Set<UUID> = []
        let existingServiceIDs = Set(existingProjects.flatMap { $0.services.map(\.id) })
        var seenServiceNames: Set<String> = []
        var portOwners: [Int: [String]] = [:]

        for (index, service) in project.services.enumerated() {
            let serviceName = service.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if serviceName.isEmpty {
                errors.append(.serviceNameEmpty(serviceIndex: index))
            } else if !seenServiceNames.insert(serviceName.lowercased()).inserted {
                errors.append(.duplicateServiceName(serviceName))
            }
            if !seenServiceIDs.insert(service.id).inserted {
                errors.append(.duplicateServiceID(service.id))
            }
            if existingServiceIDs.contains(service.id) {
                errors.append(.duplicateServiceIDAcrossProjects(service.id))
            }

            let label = serviceName.isEmpty ? "#\(index + 1)" : serviceName

            if service.start.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.executableEmpty(service: label))
            }
            for (argumentIndex, argument) in service.start.arguments.enumerated()
            where argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyArgument(service: label, argumentIndex: argumentIndex))
            }

            if let stop = service.stop {
                if stop.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append(.stopExecutableEmpty(service: label))
                }
                for (argumentIndex, argument) in stop.arguments.enumerated()
                where argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append(.stopEmptyArgument(service: label, argumentIndex: argumentIndex))
                }
            }

            errors.append(contentsOf: portErrors(for: service, label: label))

            // 重複を見るのは今回の起動対象どうし。対象外のサービスは同時に listen しない。
            if project.isEnabledNow(service.id) {
                for port in service.ports {
                    portOwners[port.port, default: []].append(label)
                }
            }
        }

        for (port, owners) in portOwners.sorted(by: { $0.key < $1.key }) {
            let distinctOwners = Array(Set(owners)).sorted()
            if distinctOwners.count > 1 {
                errors.append(.duplicatePortAcrossServices(port: port, services: distinctOwners))
            }
        }

        errors.append(contentsOf: orderErrors(project))

        return errors
    }

    /// 終了順と起動対象の指定が、実在するサービスと過不足なく対応しているかを見る。
    /// 欠落を「起動順の逆」で黙って補うと、利用者が並べた終了順と実際の停止順がずれる。
    private static func orderErrors(_ project: ProjectDefinition) -> [ValidationError] {
        var errors: [ValidationError] = []
        let serviceIDs = Set(project.services.map(\.id))

        if let stopOrder = project.stopOrder {
            var seen: Set<UUID> = []
            for serviceID in stopOrder {
                guard let service = project.service(id: serviceID) else {
                    errors.append(.stopOrderUnknownService(id: serviceID))
                    continue
                }
                if !seen.insert(serviceID).inserted {
                    errors.append(.stopOrderDuplicate(service: service.name))
                }
            }
            for service in project.services where !seen.contains(service.id) {
                errors.append(.stopOrderMissingService(service: service.name))
            }
        }

        for serviceID in project.enabledNow.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where !serviceIDs.contains(serviceID) {
            errors.append(.enabledNowUnknownService(id: serviceID))
        }

        return errors
    }

    public static func filesystemErrors(_ project: ProjectDefinition) -> [ValidationError] {
        var errors: [ValidationError] = []
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: project.directory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                errors.append(.projectDirectoryNotADirectory(project.directory))
            }
        } else {
            errors.append(.projectDirectoryMissing(project.directory))
        }

        for service in project.services {
            // 起動と終了で同じディレクトリを指すことが多いため、同じ指摘を二度出さない。
            var checked: Set<String> = []
            let directories = [service.start.workingDirectory, service.stop?.workingDirectory]
                .compactMap { $0 }
            for workingDirectory in directories where checked.insert(workingDirectory.path).inserted {
                var serviceIsDirectory: ObjCBool = false
                let exists = fileManager.fileExists(
                    atPath: workingDirectory.path,
                    isDirectory: &serviceIsDirectory
                )
                if !exists || !serviceIsDirectory.boolValue {
                    errors.append(
                        .workingDirectoryMissing(service: service.name, url: workingDirectory)
                    )
                }
            }
        }

        return errors
    }

    private static func portErrors(for service: ServiceDefinition, label: String) -> [ValidationError] {
        var errors: [ValidationError] = []
        var seenPorts: Set<Int> = []

        for port in service.ports {
            if !PortSpec.validRange.contains(port.port) {
                errors.append(.portOutOfRange(service: label, port: port.port))
            }
            if !seenPorts.insert(port.port).inserted {
                errors.append(.duplicatePortInService(service: label, port: port.port))
            }
            if let portLabel = port.label,
               portLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.portLabelEmpty(service: label, port: port.port))
            }
            if let openURL = port.openURL {
                let trimmed = openURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = URL(string: trimmed)
                let scheme = parsed?.scheme?.lowercased()
                if trimmed.isEmpty || parsed == nil || (scheme != "http" && scheme != "https") {
                    errors.append(.invalidOpenURL(service: label, value: openURL))
                }
            }
        }

        if !service.ports.isEmpty {
            let primaryCount = service.ports.filter(\.isPrimary).count
            if primaryCount == 0 {
                errors.append(.missingPrimaryPort(service: label))
            } else if primaryCount > 1 {
                errors.append(.multiplePrimaryPorts(service: label))
            }
        }

        return errors
    }
}
