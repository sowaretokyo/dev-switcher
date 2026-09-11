import Foundation

/// リポジトリの移動で保存済み設定まで読めなくならないよう、構造検証と実在確認を分ける。
/// ディレクトリが見つからない場合は登録時または起動時に失敗させる。
public enum ProjectValidator {
    public static func validate(
        _ project: ProjectDefinition,
        existingProjects: [ProjectDefinition] = []
    ) -> [ValidationError] {
        structuralErrors(project, existingProjects: existingProjects)
            + filesystemErrors(project)
            + supabaseStackErrors(project, existingProjects: existingProjects)
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

        if project.workingDirectories.isEmpty {
            errors.append(.noWorkingDirectories)
        }

        var seenWorkingDirectoryIDs: Set<UUID> = []
        var seenWorkingDirectoryNames: Set<String> = []
        var seenWorkingDirectoryPaths: Set<String> = []
        var serviceMembership: [UUID: WorkingDirectoryDefinition] = [:]

        for (index, workingDirectory) in project.workingDirectories.enumerated() {
            let directoryName = workingDirectory.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = directoryName.isEmpty ? "#\(index + 1)" : directoryName
            if directoryName.isEmpty {
                errors.append(.workingDirectoryNameEmpty(directoryIndex: index))
            } else if !seenWorkingDirectoryNames.insert(directoryName.lowercased()).inserted {
                errors.append(.duplicateWorkingDirectoryName(directoryName))
            }
            if !seenWorkingDirectoryIDs.insert(workingDirectory.id).inserted {
                errors.append(.duplicateWorkingDirectoryID(workingDirectory.id))
            }

            let directoryPath = workingDirectory.directory.path
            if directoryPath.isEmpty {
                errors.append(.workingDirectoryPathEmpty(name: label))
            } else if !directoryPath.hasPrefix("/") {
                errors.append(.workingDirectoryPathNotAbsolute(name: label, path: directoryPath))
            } else if !seenWorkingDirectoryPaths.insert(
                workingDirectory.directory.standardizedFileURL.path
            ).inserted {
                errors.append(.duplicateWorkingDirectoryPath(workingDirectory.directory))
            }

            if workingDirectory.serviceIDs.isEmpty {
                errors.append(.workingDirectoryHasNoServices(name: label))
            }
            for serviceID in workingDirectory.serviceIDs {
                guard let service = project.service(id: serviceID) else {
                    errors.append(.workingDirectoryUnknownService(name: label, id: serviceID))
                    continue
                }
                if serviceMembership.updateValue(workingDirectory, forKey: serviceID) != nil {
                    errors.append(.serviceInMultipleWorkingDirectories(service: service.name))
                }
            }
        }

        if project.services.isEmpty {
            errors.append(.noServices)
        }

        var seenServiceIDs: Set<UUID> = []
        let existingServiceIDs = Set(existingProjects.flatMap { $0.services.map(\.id) })
        var seenServiceNames: Set<String> = []

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

            if let workingDirectory = serviceMembership[service.id] {
                if service.start.workingDirectory.standardizedFileURL.path
                    != workingDirectory.directory.standardizedFileURL.path {
                    errors.append(
                        .serviceWorkingDirectoryMismatch(
                            service: label,
                            expected: workingDirectory.directory,
                            actual: service.start.workingDirectory
                        )
                    )
                }
            } else {
                errors.append(.serviceWithoutWorkingDirectory(service: label))
            }

            if service.start.executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.executableEmpty(service: label))
            }
            for (argumentIndex, argument) in service.start.arguments.enumerated()
            where argument.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.emptyArgument(service: label, argumentIndex: argumentIndex))
            }
            if service.kind == .supabase {
                if service.stop != nil {
                    errors.append(.supabaseCustomStopUnsupported(service: label))
                } else if !service.hasSupportedSupabaseInvocation {
                    errors.append(.supabaseCommandUnsupported(service: label))
                } else if !service.hasSupabaseStartSubcommand {
                    errors.append(.supabaseStartSubcommandMissing(service: label))
                } else if let forbidden = ServiceDefinition.forbiddenStopOptions
                    .sorted()
                    .first(where: service.start.arguments.contains) {
                    errors.append(
                        .supabaseForbiddenStopOption(service: label, option: forbidden)
                    )
                } else if service.supabaseConfiguration == nil {
                    errors.append(.supabaseWorkdirValueMissing(service: label))
                }
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

            // サービス間で同じポートを設定していても拒否しない。
            // どちらがポートを取るかは OS が決める（先に bind したプロセスが取る）。
            // 取れなかった側は起動失敗として `failurePolicy` に従って扱う。
            errors.append(contentsOf: portErrors(for: service.ports, serviceLabel: label))
        }

        // `enabled`にかかわらず、1開発環境に登録できるSupabaseは1件まで。
        let supabaseServices = project.services.filter { $0.kind == .supabase }
        if supabaseServices.count > 1 {
            errors.append(
                .multipleSupabaseServices(services: supabaseServices.map(\.name))
            )
        }

        errors.append(contentsOf: orderErrors(project))

        return errors
    }

    /// 登録済み開発環境全体で`project_id`が一意かを確認する。
    ///
    /// 1件でも解決できない場合は「重複なし」と扱わず、保存を失敗させる。
    /// ディレクトリ名やコンテナ名から`project_id`を補完しない。
    public static func supabaseStackErrors(
        _ project: ProjectDefinition,
        existingProjects: [ProjectDefinition]
    ) -> [ValidationError] {
        var errors: [ValidationError] = []
        var owners: [SupabaseProjectID: String] = [:]

        // 候補を含む全開発環境を、名前順ではなく登録順で解決する。
        let candidates = existingProjects.filter { $0.id != project.id } + [project]
        for candidate in candidates {
            for service in candidate.services where service.kind == .supabase {
                guard let configuration = service.supabaseConfiguration else {
                    // 起動コマンドの形式エラーは構造検証が出す。ここでは重複判定だけを止める。
                    if candidate.id == project.id {
                        errors.append(
                            .supabaseProjectIDUnresolved(
                                service: service.name,
                                reason: service.supabaseConfigurationFailureReason
                            )
                        )
                    }
                    continue
                }
                do {
                    let projectID = try configuration.resolveProjectID()
                    if let owner = owners[projectID], owner != candidate.name {
                        errors.append(
                            .duplicateSupabaseProjectID(
                                projectID: projectID.rawValue,
                                otherProject: owner
                            )
                        )
                    } else {
                        owners[projectID] = candidate.name
                    }
                } catch {
                    errors.append(
                        .supabaseProjectIDUnresolved(
                            service: service.name,
                            reason: "\(error)"
                        )
                    )
                }
            }
        }
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
        let namedDirectoryPaths = Set(
            project.workingDirectories.map { $0.directory.standardizedFileURL.path }
        )

        for workingDirectory in project.workingDirectories {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(
                atPath: workingDirectory.directory.path,
                isDirectory: &isDirectory
            ) {
                if !isDirectory.boolValue {
                    errors.append(
                        .namedWorkingDirectoryNotADirectory(
                            name: workingDirectory.name,
                            url: workingDirectory.directory
                        )
                    )
                }
            } else {
                errors.append(
                    .namedWorkingDirectoryMissing(
                        name: workingDirectory.name,
                        url: workingDirectory.directory
                    )
                )
            }
        }

        for service in project.services {
            // 起動側は名前付き作業ディレクトリで検証済み。ここでは旧形式から保持する
            // 終了コマンドが別の場所を使う場合だけ追加で確認する。
            guard let stopDirectory = service.stop?.workingDirectory,
                  !namedDirectoryPaths.contains(stopDirectory.standardizedFileURL.path) else {
                continue
            }
            var stopIsDirectory: ObjCBool = false
            let stopExists = fileManager.fileExists(
                atPath: stopDirectory.path,
                isDirectory: &stopIsDirectory
            )
            if !stopExists || !stopIsDirectory.boolValue {
                errors.append(
                    .workingDirectoryMissing(service: service.name, url: stopDirectory)
                )
            }
        }

        return errors
    }

    /// フォームで他の必須値が欠けているときも、入力済みポートの問題を同時に返す。
    public static func portErrors(
        for ports: [PortSpec],
        serviceLabel: String
    ) -> [ValidationError] {
        var errors: [ValidationError] = []
        var seenPorts: Set<Int> = []

        for port in ports {
            if !PortSpec.validRange.contains(port.port) {
                errors.append(.portOutOfRange(service: serviceLabel, port: port.port))
            }
            if !seenPorts.insert(port.port).inserted {
                errors.append(.duplicatePortInService(service: serviceLabel, port: port.port))
            }
            if let portLabel = port.label,
               portLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.portLabelEmpty(service: serviceLabel, port: port.port))
            }
            if let openURL = port.openURL {
                let trimmed = openURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = URL(string: trimmed)
                let scheme = parsed?.scheme?.lowercased()
                if trimmed.isEmpty || parsed == nil || (scheme != "http" && scheme != "https") {
                    errors.append(.invalidOpenURL(service: serviceLabel, value: openURL))
                }
            }
        }

        if !ports.isEmpty {
            let primaryCount = ports.filter(\.isPrimary).count
            if primaryCount == 0 {
                errors.append(.missingPrimaryPort(service: serviceLabel))
            } else if primaryCount > 1 {
                errors.append(.multiplePrimaryPorts(service: serviceLabel))
            }
        }

        return errors
    }
}
