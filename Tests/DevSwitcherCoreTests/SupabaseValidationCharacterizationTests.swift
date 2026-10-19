import Foundation
import Testing
@testable import DevSwitcherCore

/// Supabase サービスの検証結果（文言と優先順位）を固定する特性テスト。
@Suite("Supabase検証の特性（文言・優先順位）")
struct SupabaseValidationCharacterizationTests {
    @Test("ValidationError の Supabase 系ケースの description")
    func validationErrorText() throws {
        #expect(
            ValidationError.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.customStopUnsupported)).description
                == "Supabase「Supabase」の終了コマンドは個別に指定できません。起動コマンドから導出した `supabase stop` を使用します。"
        )
        #expect(
            ValidationError.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.commandUnsupported)).description
                == "Supabase「Supabase」の起動コマンドは `supabase start`、`pnpm exec supabase start`、`npx supabase start`、`pnpx supabase start`のいずれかの形式で指定してください。"
        )
        #expect(
            ValidationError.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.startSubcommandMissing)).description
                == "Supabase「Supabase」の起動コマンドに `start` サブコマンドがありません。"
        )
        #expect(
            ValidationError.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.workdirValueMissing)).description
                == "Supabase「Supabase」の `--workdir` にディレクトリが指定されていません。"
        )
        #expect(
            ValidationError.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.forbiddenStopOption("--all"))).description
                == "Supabase「Supabase」の起動コマンドに `--all` は指定できません。複数プロジェクトやバックアップを巻き込むため、Dev Switcherでは実行しません。"
        )
        #expect(
            ValidationError.managedStackLimitExceeded(type: .supabase, limit: 1, stacks: ["Supabase", "Supabase 2"]).description
                == "1つの開発環境に登録できる Supabase は1件までです（Supabase / Supabase 2）。起動対象から外していても登録できません。"
        )
        #expect(
            ValidationError.managedStackIdentityUnresolved(stack: "Supabase", type: .supabase, reason: "理由です。").description
                == "Supabase「Supabase」の `project_id` を取得できません。\n理由です。"
        )
        #expect(
            ValidationError.duplicateManagedStackIdentity(
                identity: try ManagedStackIdentity(type: .supabase, value: "bell"),
                otherProject: "Bell"
            ).description
                == "Supabase の `project_id`「bell」は開発環境「Bell」で既に使用されています。同じスタックを複数の開発環境から扱う構成は対象外です。"
        )
    }

    private func structuralErrors(
        for service: ServiceDefinition,
        directory: URL
    ) -> [ValidationError] {
        ProjectValidator.structuralErrors(
            makeProject(directory: directory, services: [service])
        )
    }

    @Test("不備が重なる Supabase サービスは、優先順位どおり1件だけエラーを返す")
    func structuralErrorPriority() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stop = CommandSpec(
            executable: "/bin/echo", arguments: ["stop"], workingDirectory: directory
        )

        // 1. 終了コマンドの指定が最優先。他の不備（未対応形式・禁止オプション）は報告しない。
        var everything = makeSupabaseService(
            workingDirectory: directory, executable: "foo", arguments: ["status", "--all"]
        )
        everything.stop = stop
        #expect(
            structuralErrors(for: everything, directory: directory)
                == [.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.customStopUnsupported))]
        )

        // 2. 未対応の形式。start欠落や禁止オプションより優先する。
        let unsupported = makeSupabaseService(
            workingDirectory: directory, executable: "foo", arguments: ["status", "--all"]
        )
        #expect(
            structuralErrors(for: unsupported, directory: directory)
                == [.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.commandUnsupported))]
        )

        // 3. start欠落。禁止オプションより優先する。
        let noStart = makeSupabaseService(
            workingDirectory: directory, arguments: ["status", "--all", "--no-backup"]
        )
        #expect(
            structuralErrors(for: noStart, directory: directory)
                == [.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.startSubcommandMissing))]
        )

        // 4. 禁止オプション。複数あれば辞書順で最初の1件だけを報告する。
        let forbidden = makeSupabaseService(
            workingDirectory: directory, arguments: ["start", "--no-backup", "--all"]
        )
        #expect(
            structuralErrors(for: forbidden, directory: directory)
                == [.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.forbiddenStopOption("--all")))]
        )

        // 5. 上のどれでもなくても設定を導出できなければ、workdir の値欠落。
        let noWorkdirValue = makeSupabaseService(
            workingDirectory: directory, arguments: ["start", "--workdir"]
        )
        #expect(
            structuralErrors(for: noWorkdirValue, directory: directory)
                == [.managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.workdirValueMissing))]
        )
    }

    @Test("2件のSupabaseは、サービス名を登録順に並べた managedStackLimitExceeded を返す")
    func managedStackLimitExceededOrder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var disabled = makeSupabaseService(name: "Second", workingDirectory: directory)
        disabled.enabledByDefault = false
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(name: "First", workingDirectory: directory), disabled]
        )

        #expect(
            ProjectValidator.structuralErrors(project)
                == [.managedStackLimitExceeded(type: .supabase, limit: 1, stacks: ["First", "Second"])]
        )
    }

    // MARK: - config.toml が読めない場合

    @Test("config.toml が無ければ、validate は project_id を取得できないエラーにする")
    func missingConfigFileIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )

        let path = directory.standardizedFileURL.path + "/supabase/config.toml"
        let expected = ValidationError.managedStackIdentityUnresolved(
            stack: "Supabase",
            type: .supabase,
            reason: "Supabaseの設定ファイルがありません（\(path)）。"
        )
        #expect(ProjectValidator.validate(project) == [expected])
        #expect(throws: ValidationFailure.self) { try ProjectValidator.check(project) }
    }

    @Test("config.toml を UTF-8 として読めなければエラーにする")
    func unreadableConfigFileIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeSupabaseConfig(projectID: "bell", in: directory)
        try Data([0xFF, 0xFE, 0xFD]).write(to: configURL)
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )

        let path = directory.standardizedFileURL.path + "/supabase/config.toml"
        #expect(
            ProjectValidator.validate(project) == [
                .managedStackIdentityUnresolved(
                    stack: "Supabase",
                    type: .supabase,
                    reason: "Supabaseの設定ファイルを読めません（\(path)）。\nUTF-8として解釈できません。"
                ),
            ]
        )
    }

    @Test("config.toml にトップレベルの project_id が無ければエラーにする")
    func missingProjectIDInConfigIsAnError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = try writeSupabaseConfig(projectID: "bell", in: directory)
        try Data("[db]\nport = 54322\n".utf8).write(to: configURL)
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory)]
        )

        let path = directory.standardizedFileURL.path + "/supabase/config.toml"
        #expect(
            ProjectValidator.validate(project) == [
                .managedStackIdentityUnresolved(
                    stack: "Supabase",
                    type: .supabase,
                    reason: "Supabaseの設定ファイルにトップレベルの `project_id` がありません（\(path)）。"
                ),
            ]
        )
    }

    @Test("構造不備がある Supabase は、validate で構造エラーと project_id 未解決の両方を返す")
    func structuralDefectAlsoReportsUnresolvedProjectID() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = makeProject(
            directory: directory,
            services: [makeSupabaseService(workingDirectory: directory, arguments: ["status"])]
        )

        #expect(
            ProjectValidator.validate(project) == [
                .managedStackConfigurationInvalid(stack: "Supabase", issue: .supabase(.startSubcommandMissing)),
                .managedStackIdentityUnresolved(
                    stack: "Supabase",
                    type: .supabase,
                    reason: "起動コマンドに `start` サブコマンドがありません。"
                ),
            ]
        )
    }
}
