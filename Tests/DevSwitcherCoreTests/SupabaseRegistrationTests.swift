import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("Supabaseの登録制約")
struct SupabaseRegistrationTests {
    private func makeSupabaseProject(
        name: String,
        projectID: String,
        directory: URL,
        extraServices: [LaunchUnit] = []
    ) throws -> ProjectDefinition {
        try writeSupabaseConfig(projectID: projectID, in: directory)
        return makeProject(
            name: name,
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)] + extraServices
        )
    }

    @Test("1開発環境に2件のSupabaseを登録できない（片方がdisabledでも）")
    func rejectsTwoSupabaseServicesInOneProject() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeSupabaseConfig(projectID: "demo", in: directory)

        var disabled = makeSupabaseService(name: "Supabase 2", workingDirectory: directory)
        disabled.enabledByDefault = false
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory), disabled]
        )

        let errors = ProjectValidator.validate(project)

        #expect(errors.contains(
            .managedStackLimitExceeded(type: .supabase, limit: 1, stacks: ["Supabase", "Supabase 2"])
        ))
    }

    @Test("開発環境をまたぐ project_id の重複を拒否し、異なるIDは保存できる")
    func rejectsDuplicateProjectIDAcrossProjects() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let demoDirectory = root.appendingPathComponent("demo", isDirectory: true)
        let sampleDirectory = root.appendingPathComponent("sample", isDirectory: true)
        for directory in [demoDirectory, sampleDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        let demo = try makeSupabaseProject(name: "Demo", projectID: "demo", directory: demoDirectory)
        let duplicate = try makeSupabaseProject(
            name: "Sample",
            projectID: "demo",
            directory: sampleDirectory
        )

        let duplicateErrors = ProjectValidator.validate(duplicate, existingProjects: [demo])
        #expect(duplicateErrors.contains(
            .duplicateManagedStackIdentity(
                identity: try ManagedStackIdentity(type: .supabase, value: "demo"),
                otherProject: "Demo"
            )
        ))

        // 別IDなら保存できる。
        try writeSupabaseConfig(projectID: "sample", in: sampleDirectory)
        let distinct = try makeSupabaseProject(
            name: "Sample",
            projectID: "sample",
            directory: sampleDirectory
        )
        #expect(ProjectValidator.validate(distinct, existingProjects: [demo]).isEmpty)
    }

    @Test("project_id を解決できない開発環境があれば、一意性を確認できたことにしない")
    func rejectsSaveWhenProjectIDCannotBeResolved() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let demoDirectory = root.appendingPathComponent("demo", isDirectory: true)
        let brokenDirectory = root.appendingPathComponent("broken", isDirectory: true)
        for directory in [demoDirectory, brokenDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        // 既存側の設定ファイルが無い状態で、新しい開発環境を保存しようとする。
        let broken = makeProject(
            name: "Broken",
            directory: brokenDirectory,
            services: [makeSupabaseService(workingDirectory: brokenDirectory)]
        )
        let demo = try makeSupabaseProject(
            name: "Demo",
            projectID: "demo",
            directory: demoDirectory
        )

        let errors = ProjectValidator.validate(demo, existingProjects: [broken])

        #expect(errors.contains { error in
            if case .managedStackIdentityUnresolved = error { return true }
            return false
        })
    }

    @Test("既存の開発環境のSupabase構成が構造不備なら、一意性を確認できず保存を拒否する")
    func ignoresStructuralIssuesOfExistingProjectsForCandidate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let demoDirectory = root.appendingPathComponent("demo", isDirectory: true)
        let sampleDirectory = root.appendingPathComponent("sample", isDirectory: true)
        for directory in [demoDirectory, sampleDirectory] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        // 既存側は config.toml があり、start サブコマンドだけが欠けている。
        try writeSupabaseConfig(projectID: "demo", in: demoDirectory)
        let broken = makeProject(
            name: "Demo",
            directory: demoDirectory,
            services: [makeSupabaseService(workingDirectory: demoDirectory, arguments: [])]
        )
        let candidate = try makeSupabaseProject(
            name: "Sample",
            projectID: "sample",
            directory: sampleDirectory
        )

        // 既存側の構造不備が実際に構造エラーとして現れる前提を固定する（空振り防止）。
        #expect(ProjectValidator.validate(broken).contains { error in
            if case .managedStackConfigurationInvalid = error { return true }
            return false
        })

        let errors = ProjectValidator.validate(candidate, existingProjects: [broken])

        #expect(errors.contains { if case .managedStackIdentityUnresolved = $0 { true } else { false } })
    }
}
