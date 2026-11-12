import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("設定の検証")
struct ProjectValidationTests {
    @Test("必須項目が揃っていればエラーにならない")
    func validProjectPasses() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(directory: directory)
        #expect(ProjectValidator.validate(project).isEmpty)
    }

    @Test("プロジェクト名が空なら拒否する")
    func emptyNameRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(name: "   ", directory: directory)
        #expect(ProjectValidator.structuralErrors(project).contains(.projectNameEmpty))
    }

    @Test("サービスが1つもなければ拒否する")
    func noServicesRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(directory: directory, services: [])
        #expect(ProjectValidator.structuralErrors(project).contains(.noServices))
    }

    @Test("実行ファイルが空なら拒否する")
    func emptyExecutableRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(executable: "  ", workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        #expect(ProjectValidator.structuralErrors(project).contains(.executableEmpty(service: "Web")))
    }

    @Test("引数に空文字があれば拒否する")
    func emptyArgumentRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(arguments: ["run", ""], workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        #expect(
            ProjectValidator.structuralErrors(project)
                .contains(.emptyArgument(service: "Web", argumentIndex: 1))
        )
    }

    @Test("ポートを持つサービスに代表ポートがなければ拒否する")
    func missingPrimaryPortRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(
            ports: [PortSpec(label: "API", port: 54_321, isPrimary: false)],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        #expect(ProjectValidator.structuralErrors(project).contains(.missingPrimaryPort(service: "Web")))
    }

    @Test("代表ポートが複数あれば拒否する")
    func multiplePrimaryPortsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(
            ports: [
                PortSpec(label: "API", port: 54_321, isPrimary: true),
                PortSpec(label: "DB", port: 54_322, isPrimary: true),
            ],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        #expect(ProjectValidator.structuralErrors(project).contains(.multiplePrimaryPorts(service: "Web")))
    }

    @Test("ポートを持たないサービスは代表ポートを要求しない")
    func portlessServiceIsValid() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(name: "Worker", kind: .worker, ports: [], workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        #expect(ProjectValidator.validate(project).isEmpty)
    }

    @Test("範囲外のポートを拒否する")
    func portOutOfRangeRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(ports: [PortSpec(port: 70_000, isPrimary: true)], workingDirectory: directory)
        let project = makeProject(directory: directory, services: [service])
        #expect(
            ProjectValidator.structuralErrors(project)
                .contains(.portOutOfRange(service: "Web", port: 70_000))
        )
    }

    @Test("同一サービス内のポート重複を拒否する")
    func duplicatePortInServiceRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(
            ports: [
                PortSpec(label: "API", port: 54_321, isPrimary: true),
                PortSpec(label: "DB", port: 54_321, isPrimary: false),
            ],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        #expect(
            ProjectValidator.structuralErrors(project)
                .contains(.duplicatePortInService(service: "Web", port: 54_321))
        )
    }

    @Test("同一プロセス内のポートID重複を具体的なエラーで返す")
    func duplicatePortIDInServiceRejected() {
        let sharedID = UUID()
        let errors = ProjectValidator.portErrors(for: [
            PortSpec(id: sharedID, port: 3000, isPrimary: true),
            PortSpec(id: sharedID, port: 3001, isPrimary: false),
        ], serviceLabel: "Web")
        #expect(errors == [.duplicatePortIDInService(service: "Web", id: sharedID)])
    }

    @Test("ポートIDの一意性はプロセスごとに検証する")
    func portIDUniquenessIsScopedToService() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sharedID = UUID()
        let first = makeService(name: "First", ports: [
            PortSpec(id: sharedID, port: 3000, isPrimary: true),
        ], workingDirectory: directory)
        let second = makeService(name: "Second", ports: [
            PortSpec(id: sharedID, port: 3001, isPrimary: true),
        ], workingDirectory: directory)
        #expect(ProjectValidator.validate(makeProject(directory: directory, services: [first, second])).isEmpty)
    }

    @Test("起動対象サービス間で同じポートを設定していても保存を拒否しない")
    func duplicatePortAcrossEnabledServicesIsAccepted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // どちらがポートを取るかは OS が決める。DevSwitcher は保存も起動も拒否しない。
        let web = makeService(name: "Web", ports: [PortSpec(port: 3000, isPrimary: true)], workingDirectory: directory)
        let studio = makeService(
            name: "Studio",
            ports: [PortSpec(port: 3000, isPrimary: true)],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [web, studio])
        #expect(ProjectValidator.validate(project).isEmpty)
    }

    @Test("ポートを1つも入力しないサービスを保存できる")
    func servicesWithoutPortsAreAccepted() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ポートは全種別で任意。代表ポートの検証はポートを入力した場合にだけ働く。
        let web = makeService(name: "Web", kind: .web, ports: [], workingDirectory: directory)
        let inngest = makeService(name: "Inngest", kind: .inngest, ports: [], workingDirectory: directory)
        let project = makeProject(directory: directory, services: [web, inngest])
        #expect(ProjectValidator.validate(project).isEmpty)
    }

    @Test("http / https 以外の開く URL を拒否する")
    func invalidOpenURLRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(
            ports: [PortSpec(port: 3000, isPrimary: true, openURL: "file:///tmp")],
            workingDirectory: directory
        )
        let project = makeProject(directory: directory, services: [service])
        #expect(
            ProjectValidator.structuralErrors(project)
                .contains(.invalidOpenURL(service: "Web", value: "file:///tmp"))
        )
    }

    @Test("存在しないディレクトリを拒否する")
    func missingDirectoryRejected() throws {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.removeItem(at: directory)

        let project = makeProject(directory: directory)
        #expect(
            ProjectValidator.filesystemErrors(project).contains(
                .namedWorkingDirectoryMissing(name: directory.lastPathComponent, url: directory)
            )
        )
        #expect(ProjectValidator.structuralErrors(project).isEmpty)
    }

    @Test("名前付き作業ディレクトリの名前とパスの重複を拒否する")
    func duplicateNamedWorkingDirectoryRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let web = makeService(name: "Web", workingDirectory: directory)
        let worker = makeService(name: "Worker", kind: .worker, workingDirectory: directory)
        let project = ProjectDefinition(
            name: "Demo",
            color: .blue,
            workingDirectories: [
                WorkingDirectoryDefinition(name: "App", directory: directory, serviceIDs: [web.id]),
                WorkingDirectoryDefinition(name: "app", directory: directory, serviceIDs: [worker.id]),
            ],
            services: [web, worker]
        )

        let errors = ProjectValidator.structuralErrors(project)
        #expect(errors.contains(.duplicateWorkingDirectoryName("app")))
        #expect(errors.contains(.duplicateWorkingDirectoryPath(directory)))
    }

    @Test("プロセスの所属先と実行ディレクトリの不一致を拒否する")
    func processWorkingDirectoryMismatchRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let otherDirectory = directory.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)

        let web = makeService(name: "Web", workingDirectory: otherDirectory)
        let project = ProjectDefinition(
            name: "Demo",
            color: .blue,
            workingDirectories: [
                WorkingDirectoryDefinition(name: "Web", directory: directory, serviceIDs: [web.id]),
            ],
            services: [web]
        )

        #expect(
            ProjectValidator.structuralErrors(project).contains(
                .serviceWorkingDirectoryMismatch(
                    service: "Web",
                    expected: directory,
                    actual: otherDirectory
                )
            )
        )
    }

    @Test("プロジェクト名の重複を拒否する")
    func duplicateProjectNameRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = makeProject(name: "Demo", directory: directory)
        let added = makeProject(name: "demo", directory: directory)
        #expect(
            ProjectValidator.structuralErrors(added, existingProjects: [existing])
                .contains(.duplicateProjectName("Demo"))
        )
    }

    @Test("別プロジェクトとのサービスID重複を拒否する")
    func duplicateServiceIDAcrossProjectsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let serviceID = UUID()
        let firstService = LaunchUnit(
            id: serviceID,
            name: "First",
            kind: .worker,
            ports: [],
            start: CommandSpec(
                executable: "/bin/sleep",
                arguments: ["30"],
                workingDirectory: directory
            ),
            enabledByDefault: true,
            failurePolicy: .block
        )
        let secondService = LaunchUnit(
            id: serviceID,
            name: "Second",
            kind: .worker,
            ports: [],
            start: CommandSpec(
                executable: "/bin/sleep",
                arguments: ["30"],
                workingDirectory: directory
            ),
            enabledByDefault: true,
            failurePolicy: .block
        )
        let existing = makeProject(name: "Existing", directory: directory, services: [firstService])
        let added = makeProject(name: "Added", directory: directory, services: [secondService])

        #expect(
            ProjectValidator.structuralErrors(added, existingProjects: [existing])
                .contains(.duplicateServiceIDAcrossProjects(serviceID))
        )
    }

    @Test("check はエラーをまとめて投げる")
    func checkThrowsValidationFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = makeService(name: "", executable: "", workingDirectory: directory)
        let project = makeProject(name: "", directory: directory, services: [service])

        #expect(throws: ValidationFailure.self) {
            try ProjectValidator.check(project)
        }
    }

    @Test("Supabaseの起動コマンドにstartがなければ拒否する")
    func rejectsSupabaseWithoutStartSubcommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["status"],
            workingDirectory: directory
        )

        let errors = ProjectValidator.validate(
            makeProject(directory: directory, services: [service])
        )

        #expect(errors.contains(.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.startSubcommandMissing))))
    }

    @Test("ラッパーのscript名startをSupabaseサブコマンドとして受け付けない")
    func rejectsAmbiguousSupabaseWrapperCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "npm",
            arguments: ["run", "start"],
            workingDirectory: directory
        )

        let errors = ProjectValidator.validate(
            makeProject(directory: directory, services: [service])
        )

        #expect(errors.contains(.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.commandUnsupported))))
        #expect(service.derivedSupabaseConfiguration == nil)
    }

    @Test("Supabaseのラッパー引数を維持してstatusとstopを導出する")
    func derivesSupabaseLifecycleFromWrappedCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "pnpm",
            arguments: ["exec", "supabase@latest", "start", "--exclude", "studio"],
            workingDirectory: directory
        )

        let configuration = try #require(service.derivedSupabaseConfiguration)
        let projectID = try #require(SupabaseProjectID(rawValue: "demo"))

        #expect(configuration.configDirectory == directory.standardizedFileURL)
        #expect(configuration.statusCommand.executable == "pnpm")
        #expect(configuration.statusCommand.arguments == [
            "exec", "supabase@latest", "status",
            "--workdir", directory.standardizedFileURL.path,
            "--output", "json",
        ])
        // 停止は必ず対象`project_id`を明示する。`--all`と`--no-backup`は生成できない。
        #expect(configuration.stopCommand(projectID: projectID).arguments == [
            "exec", "supabase@latest", "stop",
            "--workdir", directory.standardizedFileURL.path,
            "--project-id", "demo",
        ])
    }

    @Test("停止コマンドに --all と --no-backup を生成しない")
    func neverGeneratesForbiddenSupabaseStopOptions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["start"],
            workingDirectory: directory
        )
        let configuration = try #require(service.derivedSupabaseConfiguration)
        let projectID = try #require(SupabaseProjectID(rawValue: "demo"))

        for command in [configuration.statusCommand, configuration.stopCommand(projectID: projectID)] {
            #expect(!command.arguments.contains("--all"))
            #expect(!command.arguments.contains("--no-backup"))
        }
    }

    @Test("起動コマンドの --all と --no-backup を保存時に拒否する")
    func rejectsForbiddenSupabaseStopOptionsInStartCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["start", "--no-backup"],
            workingDirectory: directory
        )

        let errors = ProjectValidator.validate(
            makeProject(directory: directory, services: [service])
        )

        #expect(errors.contains(
            .managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.forbiddenStopOption("--no-backup")))
        ))
        #expect(service.derivedSupabaseConfiguration == nil)
    }

    @Test("startより後ろのSupabase workdirをstatusとstopへ引き継ぐ")
    func preservesTrailingSupabaseWorkdirInLifecycleCommands() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("repo-a", isDirectory: true)
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "pnpm",
            arguments: [
                "exec", "supabase@latest", "start", "--exclude", "studio",
                "--workdir", target.path,
            ],
            workingDirectory: directory
        )

        let configuration = try #require(service.derivedSupabaseConfiguration)
        let projectID = try #require(SupabaseProjectID(rawValue: "demo"))

        // `--workdir`があれば、そこが`project_id`を読む設定ディレクトリになる。
        #expect(configuration.configDirectory.path == target.standardizedFileURL.path)
        #expect(configuration.statusCommand.arguments == [
            "exec", "supabase@latest", "status", "--workdir", configuration.configDirectory.path,
            "--output", "json",
        ])
        #expect(configuration.stopCommand(projectID: projectID).arguments == [
            "exec", "supabase@latest", "stop", "--workdir", configuration.configDirectory.path,
            "--project-id", "demo",
        ])
    }

    @Test("Supabase workdirの値が欠けていれば拒否する")
    func rejectsSupabaseWithMissingTrailingWorkdirValue() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["start", "--workdir"],
            workingDirectory: directory
        )

        let errors = ProjectValidator.validate(
            makeProject(directory: directory, services: [service])
        )

        #expect(errors.contains(.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.workdirValueMissing))))
    }

    @Test("Supabaseのカスタム終了コマンドを拒否する")
    func rejectsCustomSupabaseStopCommand() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "supabase",
            arguments: ["start"],
            workingDirectory: directory,
            stop: CommandSpec(
                executable: "/usr/bin/true",
                arguments: [],
                workingDirectory: directory
            )
        )

        let errors = ProjectValidator.validate(
            makeProject(directory: directory, services: [service])
        )

        #expect(errors.contains(.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.customStopUnsupported))))
        #expect(service.derivedSupabaseConfiguration == nil)
    }
}
