@testable import DevSwitcherCore
import Foundation
import Testing
@testable import DevSwitcherApp

/// 単一シートの開発環境追加・編集フォームの検証。
///
/// ポートは全サービスで任意。種別から既定値を自動入力しない。
/// 入力された番号は表示と「開く」URL の補助情報であり、起動可否の根拠にしない。
/// 編集画面が扱わない終了順・今回の起動対象・終了コマンドは保存時に落とさない。
@Suite("開発環境フォーム")
@MainActor
struct ProjectFormModelTests {
    private func makeService(
        name: String = "Inngest",
        kind: ServiceKind = .inngest,
        port: Int? = nil,
        executable: String = "/usr/bin/true",
        arguments: [String] = [],
        workingDirectory: URL,
        stop: CommandSpec? = nil,
        enabledByDefault: Bool = true,
        failurePolicy: FailurePolicy = .continue
    ) -> ServiceDefinition {
        ServiceDefinition(
            name: name,
            kind: kind,
            ports: port.map { [PortSpec(port: $0, isPrimary: true)] } ?? [],
            start: CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory
            ),
            stop: stop,
            enabledByDefault: enabledByDefault,
            failurePolicy: failurePolicy
        )
    }

    private func makeProject(
        with services: [ServiceDefinition],
        directory: URL,
        stopOrder: [UUID]? = nil,
        enabledNow: [UUID: Bool] = [:]
    ) -> ProjectDefinition {
        ProjectDefinition(
            name: "Bell",
            color: .blue,
            directory: directory,
            services: services,
            stopOrder: stopOrder,
            enabledNow: enabledNow
        )
    }

    /// 3件のサービスを持つプロジェクト。全フィールドを別々の値にして取り違えを検出する。
    private func makeThreeServiceProject(directory: URL) throws -> ProjectDefinition {
        let supabaseDirectory = directory.appendingPathComponent("supabase", isDirectory: true)
        try FileManager.default.createDirectory(
            at: supabaseDirectory,
            withIntermediateDirectories: true
        )

        let supabase = makeService(
            name: "Supabase",
            kind: .supabase,
            executable: "/usr/bin/env",
            arguments: ["supabase", "dev"],
            workingDirectory: supabaseDirectory,
            enabledByDefault: true,
            failurePolicy: .block
        )
        var web = makeService(
            name: "Web",
            kind: .web,
            executable: "pnpm",
            arguments: ["dev"],
            workingDirectory: directory,
            enabledByDefault: true,
            failurePolicy: .block
        )
        web.ports = [
            PortSpec(label: "App", port: 3000, isPrimary: true, openURL: "http://localhost:3000"),
            PortSpec(label: "HMR", port: 3001, isPrimary: false),
        ]
        let worker = makeService(
            name: "Worker",
            kind: .worker,
            executable: "/bin/sleep",
            arguments: ["120"],
            workingDirectory: directory,
            enabledByDefault: false,
            failurePolicy: .continue
        )
        return makeProject(with: [supabase, web, worker], directory: directory)
    }

    // MARK: - 読み込みと保持

    @Test("3件のサービスを読み込み、全フィールドと ID を維持する")
    func multipleServicesRoundTripThroughTheForm() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = try makeThreeServiceProject(directory: directory)
        let model = ProjectFormModel(project: project)

        #expect(model.services.map(\.id) == project.services.map(\.id))
        #expect(model.services.map(\.name) == ["Supabase", "Web", "Worker"])
        #expect(model.services.map(\.kind) == [.supabase, .web, .worker])
        #expect(model.services.map(\.executable) == ["/usr/bin/env", "pnpm", "/bin/sleep"])
        #expect(model.services.map(\.argumentsText) == ["supabase\ndev", "dev", "120"])
        #expect(model.services.map(\.enabledByDefault) == [true, true, false])
        #expect(model.services.map(\.failurePolicy) == [.block, .block, .continue])
        #expect(model.workingDirectories.count == 2)
        let supabaseDirectory = try #require(
            model.workingDirectories.first { $0.directory?.lastPathComponent == "supabase" }
        )
        #expect(supabaseDirectory.name == "supabase")
        #expect(supabaseDirectory.services.map(\.name) == ["Supabase"])
        let rootDirectory = try #require(
            model.workingDirectories.first { $0.directory == directory }
        )
        #expect(rootDirectory.services.map(\.name) == ["Web", "Worker"])
        #expect(model.services.map { $0.ports.map(\.port) } == [[""], ["3000", "3001"], [""]])

        let rebuilt = try model.build()
        #expect(rebuilt == project)
        #expect(rebuilt.services.map(\.id) == project.services.map(\.id))
        #expect(rebuilt.services.map { $0.ports.map(\.id) } == project.services.map { $0.ports.map(\.id) })
    }

    @Test("旧設定の起動順が作業ディレクトリをまたいでいても編集だけで変えない")
    func interleavedLegacyOrderSurvivesAnOrdinaryEdit() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nativeDirectory = directory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        let web = makeService(name: "Web", workingDirectory: directory)
        let native = makeService(name: "Native", kind: .expo, workingDirectory: nativeDirectory)
        let worker = makeService(name: "Worker", kind: .worker, workingDirectory: directory)
        let project = makeProject(with: [web, native, worker], directory: directory)

        let model = ProjectFormModel(project: project)
        #expect(model.workingDirectories[0].services.map(\.name) == ["Web", "Worker"])
        #expect(model.workingDirectories[1].services.map(\.name) == ["Native"])
        #expect(model.services.map(\.name) == ["Web", "Native", "Worker"])
        #expect(model.hasCrossDirectoryServiceOrder)

        model.name = "Bell 2"
        let rebuilt = try model.build()
        #expect(rebuilt.services.map(\.id) == [web.id, native.id, worker.id])
        #expect(rebuilt.startupOrder.map(\.name) == ["Web", "Native", "Worker"])
    }

    @Test("作業ディレクトリを並べ替えるとディレクトリ単位の起動順へ揃える")
    func movingAWorkingDirectoryNormalizesAnInterleavedOrder() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nativeDirectory = directory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        let web = makeService(name: "Web", workingDirectory: directory)
        let native = makeService(name: "Native", kind: .expo, workingDirectory: nativeDirectory)
        let worker = makeService(name: "Worker", kind: .worker, workingDirectory: directory)
        let model = ProjectFormModel(
            project: makeProject(with: [web, native, worker], directory: directory)
        )
        let webDirectoryID = model.workingDirectories[0].id

        model.moveWorkingDirectory(webDirectoryID, by: 1)

        #expect(model.workingDirectories.map(\.name) == ["native", directory.lastPathComponent])
        #expect(model.services.map(\.name) == ["Native", "Web", "Worker"])
        #expect(!model.hasCrossDirectoryServiceOrder)
        let rebuilt = try model.build()
        #expect(rebuilt.startupOrder.map(\.name) == ["Native", "Web", "Worker"])
    }

    @Test("空にした作業ディレクトリへ追加したプロセスは次のディレクトリより前に起動する")
    func addingAProcessBackToAnEmptyDirectoryKeepsDirectoryOrder() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nativeDirectory = directory.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeDirectory, withIntermediateDirectories: true)
        let web = makeService(name: "Web", workingDirectory: directory)
        let native = makeService(name: "Native", kind: .expo, workingDirectory: nativeDirectory)
        let model = ProjectFormModel(project: makeProject(with: [web, native], directory: directory))
        let webDirectoryID = model.workingDirectories[0].id

        model.removeService(web.id)
        #expect(model.positionIfPresent(of: web.id) == nil)
        model.addService(to: webDirectoryID)
        model.workingDirectories[0].services[0].name = "Web 2"
        model.workingDirectories[0].services[0].executable = "/usr/bin/true"

        #expect(model.services.map(\.name) == ["Web 2", "Native"])
        #expect(!model.hasCrossDirectoryServiceOrder)
        let rebuilt = try model.build()
        #expect(rebuilt.startupOrder.map(\.name) == ["Web 2", "Native"])
    }

    @Test("サービスを追加・削除・並べ替えて保存し、同じ順序で復元できる")
    func servicesCanBeAddedRemovedAndReordered() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(
            with: [
                makeService(name: "Supabase", kind: .supabase, workingDirectory: directory),
                makeService(name: "Web", kind: .web, workingDirectory: directory),
                makeService(name: "Worker", kind: .worker, workingDirectory: directory),
            ],
            directory: directory
        )
        let store = ProjectStore(directory: directory)
        try store.save([project])

        let model = ProjectFormModel(project: project)
        let webID = model.services[1].id

        // Worker を削除し、Inngest を追加し、Web を先頭へ動かす。
        model.removeService(model.services[2].id)
        model.addService()
        model.services[2].name = "Inngest"
        model.services[2].kind = .inngest
        model.services[2].executable = "npx"
        model.services[2].argumentsText = "inngest-cli\ndev"
        model.moveService(webID, by: -1)

        #expect(model.services.map(\.name) == ["Web", "Supabase", "Inngest"])

        let rebuilt = try model.build()
        try store.save([rebuilt])
        let loaded = try store.load()

        #expect(loaded.count == 1)
        #expect(loaded[0].services.map(\.name) == ["Web", "Supabase", "Inngest"])
        // 並べ替えても既存 ID は変わらない。新規追加のときだけ新しい ID を発行する。
        #expect(loaded[0].services[0].id == webID)
        #expect(loaded[0].services[1].id == project.services[0].id)
        #expect(!project.services.map(\.id).contains(loaded[0].services[2].id))
        // 起動順は配列順そのもの。終了順は既定でその逆。
        #expect(loaded[0].startupOrder.map(\.name) == ["Web", "Supabase", "Inngest"])
        #expect(loaded[0].shutdownOrder.map(\.name) == ["Inngest", "Supabase", "Web"])
    }

    @Test("名前付き作業ディレクトリごとに複数プロセスを保存できる")
    func processesAreGroupedByNamedWorkingDirectory() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let apiDirectory = directory.appendingPathComponent("api", isDirectory: true)
        let webDirectory = directory.appendingPathComponent("web", isDirectory: true)
        for url in [apiDirectory, webDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].name = "API"
        model.workingDirectories[0].directory = apiDirectory
        model.workingDirectories[0].services[0].name = "API Server"
        model.workingDirectories[0].services[0].executable = "/usr/bin/true"
        model.addService(to: model.workingDirectories[0].id)
        model.workingDirectories[0].services[1].name = "Worker"
        model.workingDirectories[0].services[1].executable = "/usr/bin/true"

        model.addWorkingDirectory()
        model.workingDirectories[1].name = "Web"
        model.workingDirectories[1].directory = webDirectory
        model.workingDirectories[1].services[0].name = "Web"
        model.workingDirectories[1].services[0].executable = "/usr/bin/true"

        let project = try model.build()
        #expect(project.workingDirectories.map(\.name) == ["API", "Web"])
        #expect(project.workingDirectories.map(\.directory) == [apiDirectory, webDirectory])
        #expect(project.services[0].start.workingDirectory == apiDirectory)
        #expect(project.services[1].start.workingDirectory == apiDirectory)
        #expect(project.services[2].start.workingDirectory == webDirectory)
        #expect(project.workingDirectories[0].serviceIDs == project.services[0 ... 1].map(\.id))
        #expect(project.workingDirectories[1].serviceIDs == [project.services[2].id])

        let store = ProjectStore(directory: directory)
        try store.save([project])
        let loaded = try store.load()
        #expect(loaded[0].services.map(\.start.workingDirectory) == [
            apiDirectory, apiDirectory, webDirectory,
        ])

        // 開き直しても取り違えない。
        let reopened = ProjectFormModel(project: loaded[0])
        #expect(reopened.workingDirectories.map(\.name) == ["API", "Web"])
        #expect(reopened.workingDirectories[0].services.map(\.name) == ["API Server", "Worker"])
        #expect(reopened.workingDirectories[1].services.map(\.name) == ["Web"])
    }

    @Test("編集画面が扱わない stop・enabledNow・stopOrder を通常編集で保持する")
    func outOfScopeValuesSurviveAnOrdinaryEdit() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stop = CommandSpec(
            executable: "/usr/bin/true",
            arguments: ["stop"],
            workingDirectory: directory
        )
        let first = makeService(name: "Supabase", kind: .supabase, workingDirectory: directory, stop: stop)
        let second = makeService(name: "Web", kind: .web, workingDirectory: directory)
        let third = makeService(name: "Worker", kind: .worker, workingDirectory: directory)
        // 既定（起動順の逆）ではない終了順を明示している。
        let stopOrder = [second.id, third.id, first.id]
        let project = makeProject(
            with: [first, second, third],
            directory: directory,
            stopOrder: stopOrder,
            enabledNow: [first.id: false, third.id: true]
        )

        let model = ProjectFormModel(project: project)
        #expect(model.hasExplicitStopOrder)
        model.name = "Bell 2"

        let rebuilt = try model.build()
        #expect(rebuilt.services[0].stop == stop)
        #expect(rebuilt.services[1].stop == nil)
        #expect(rebuilt.stopOrder == stopOrder)
        #expect(rebuilt.enabledNow == [first.id: false, third.id: true])

        let store = ProjectStore(directory: directory)
        try store.save([rebuilt])
        let loaded = try store.load()
        #expect(loaded[0].services[0].stop == stop)
        #expect(loaded[0].stopOrder == stopOrder)
        #expect(loaded[0].enabledNow == [first.id: false, third.id: true])
    }

    @Test("並べ替えても stop はサービス ID に付いたまま動く")
    func stopCommandFollowsTheServiceNotThePosition() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stop = CommandSpec(
            executable: "/usr/bin/true",
            arguments: ["supabase", "stop"],
            workingDirectory: directory
        )
        let supabase = makeService(name: "Supabase", kind: .supabase, workingDirectory: directory, stop: stop)
        let web = makeService(name: "Web", kind: .web, workingDirectory: directory)
        let project = makeProject(with: [supabase, web], directory: directory)

        let model = ProjectFormModel(project: project)
        model.moveService(supabase.id, by: 1)

        let rebuilt = try model.build()
        #expect(rebuilt.services.map(\.name) == ["Web", "Supabase"])
        #expect(rebuilt.services[0].stop == nil)
        #expect(rebuilt.services[1].stop == stop)
    }

    @Test("サービスの増減で終了順と起動対象の参照先を壊さない")
    func stopOrderAndEnabledNowFollowServiceChanges() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = makeService(name: "Supabase", kind: .supabase, workingDirectory: directory)
        let second = makeService(name: "Web", kind: .web, workingDirectory: directory)
        let third = makeService(name: "Worker", kind: .worker, workingDirectory: directory)
        let project = makeProject(
            with: [first, second, third],
            directory: directory,
            stopOrder: [second.id, third.id, first.id],
            enabledNow: [first.id: false, third.id: true]
        )

        let model = ProjectFormModel(project: project)
        // Worker を削除して、末尾へ Inngest を足す。
        model.removeService(third.id)
        model.addService()
        model.services[2].name = "Inngest"
        model.services[2].kind = .inngest
        model.services[2].executable = "npx"
        let addedID = model.services[2].id

        let rebuilt = try model.build()
        // 削除したサービスの参照だけを外す。残りは黙って捨てない。
        #expect(rebuilt.enabledNow == [first.id: false])
        // 追加したサービスは起動順の逆の位置（末尾追加なら最初に停止）へ入る。
        #expect(rebuilt.stopOrder == [addedID, second.id, first.id])
        // 全サービスを過不足なく含むので、保存時の検証を通る。
        #expect(ProjectValidator.validate(rebuilt).isEmpty)

        let store = ProjectStore(directory: directory)
        try store.save([rebuilt])
        #expect(try store.load() == [rebuilt])
    }

    @Test("終了順が既定のままなら、サービスを増やしても明示指定を作らない")
    func defaultStopOrderStaysDefault() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = try makeThreeServiceProject(directory: directory)
        let model = ProjectFormModel(project: project)
        #expect(!model.hasExplicitStopOrder)

        let rootDirectory = try #require(
            model.workingDirectories.first { $0.directory == directory }
        )
        model.addService(to: rootDirectory.id)
        let rootIndex = try #require(
            model.workingDirectories.firstIndex { $0.id == rootDirectory.id }
        )
        model.workingDirectories[rootIndex].services[2].name = "Inngest"
        model.workingDirectories[rootIndex].services[2].executable = "npx"

        let rebuilt = try model.build()
        #expect(rebuilt.stopOrder == nil)
        #expect(rebuilt.shutdownOrder.map(\.name) == ["Inngest", "Worker", "Web", "Supabase"])
    }

    // MARK: - ポート

    @Test("Inngest を選んでもポートは空のまま")
    func inngestDoesNotFillDefaultPort() {
        let model = ProjectFormModel()
        #expect(model.services[0].ports.map(\.port) == [""])

        model.services[0].kind = .inngest

        #expect(model.services[0].ports.map(\.port) == [""])
    }

    @Test("どの種別でも既定ポートを自動入力しない")
    func noKindFillsADefaultPort() {
        for kind in ServiceKind.allCases {
            let model = ProjectFormModel()
            model.services[0].kind = kind
            #expect(
                model.services[0].ports.map(\.port) == [""],
                "\(kind.displayName) で既定ポートが入った"
            )
        }
    }

    @Test("入力済みのポートは種別変更で上書きしない")
    func customPortSurvivesKindChange() {
        let model = ProjectFormModel()
        model.services[0].ports = [ProjectFormModel.PortDraft(port: "9999", isPrimary: true)]

        model.services[0].kind = .inngest
        model.services[0].kind = .web

        #expect(model.services[0].ports.map(\.port) == ["9999"])
    }

    @Test("ポート未入力の Web・Inngest・worker を1つのプロジェクトへ保存できる")
    func servicesWithoutPortsAreSaved() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.services[0].name = "Web"
        model.services[0].kind = .web
        model.services[0].executable = "pnpm"
        model.services[0].argumentsText = "dev"
        model.addService()
        model.services[1].name = "Inngest"
        model.services[1].kind = .inngest
        model.services[1].executable = "npx"
        model.services[1].argumentsText = "inngest-cli\ndev"
        model.addService()
        model.services[2].name = "Worker"
        model.services[2].kind = .worker
        model.services[2].executable = "/bin/sleep"
        model.services[2].argumentsText = "120"

        let project = try model.build()
        #expect(project.services.allSatisfy { $0.ports.isEmpty })
        // 起動コマンドへ --port を足さない。
        #expect(project.services.map(\.start.arguments) == [
            ["dev"], ["inngest-cli", "dev"], ["120"],
        ])

        let store = ProjectStore(directory: directory)
        try store.save([project])
        #expect(try store.load() == [project])
    }

    @Test("ポートを入力すれば、保存され読み戻しても維持される")
    func enteredPortRoundTripsThroughStore() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.services[0].name = "Inngest"
        model.services[0].kind = .inngest
        model.services[0].executable = "/usr/bin/true"
        model.services[0].ports = [ProjectFormModel.PortDraft(port: "8288", isPrimary: true)]

        let project = try model.build()
        #expect(project.services[0].ports.map(\.port) == [8288])
        #expect(project.services[0].primaryPort?.port == 8288)

        let store = ProjectStore(directory: directory)
        try store.save([project])
        let loaded = try store.load()
        #expect(loaded == [project])

        // 編集で開き直しても値が変わらない。
        let editing = ProjectFormModel(project: loaded[0])
        #expect(editing.services[0].ports.map(\.port) == ["8288"])
    }

    @Test("ポートを持たない既存サービスを開いても、候補ポートを入れない")
    func existingServiceWithoutPortStaysEmpty() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(
            with: [makeService(port: nil, workingDirectory: directory)],
            directory: directory
        )
        let model = ProjectFormModel(project: project)

        #expect(model.services[0].ports.map(\.port) == [""])
    }

    @Test("既存サービスのカスタムポートは編集画面でも維持する")
    func existingCustomPortIsPreserved() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let project = makeProject(
            with: [makeService(port: 9999, workingDirectory: directory)],
            directory: directory
        )
        let model = ProjectFormModel(project: project)

        #expect(model.services[0].ports.map(\.port) == ["9999"])

        model.services[0].kind = .web
        model.services[0].kind = .inngest
        #expect(model.services[0].ports.map(\.port) == ["9999"])
    }

    @Test("別サービスへ同じポートを設定してもフォームから保存できる")
    func servicesSharingAPortAreSaved() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.services[0].name = "Web"
        model.services[0].kind = .web
        model.services[0].executable = "/usr/bin/true"
        model.services[0].ports = [ProjectFormModel.PortDraft(port: "3000", isPrimary: true)]
        model.addService()
        model.services[1].name = "Docs"
        model.services[1].kind = .web
        model.services[1].executable = "/usr/bin/true"
        model.services[1].ports = [ProjectFormModel.PortDraft(port: "3000", isPrimary: true)]

        let project = try model.build()
        #expect(project.services.map { $0.ports.map(\.port) } == [[3000], [3000]])
        #expect(ProjectValidator.validate(project).isEmpty)

        let store = ProjectStore(directory: directory)
        try store.save([project])
        #expect(try store.load() == [project])
    }

    @Test("代表ポートの指定は同じサービス内で1件に閉じる")
    func primaryPortIsScopedToItsService() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.services[0].name = "Supabase"
        model.services[0].executable = "/usr/bin/true"
        model.services[0].ports = [
            ProjectFormModel.PortDraft(label: "API", port: "54321", isPrimary: true),
            ProjectFormModel.PortDraft(label: "DB", port: "54322", isPrimary: false),
        ]
        model.addService()
        model.services[1].name = "Web"
        model.services[1].executable = "/usr/bin/true"
        model.services[1].ports = [ProjectFormModel.PortDraft(port: "3000", isPrimary: true)]

        // 2件目のサービスの代表指定を変えても、1件目の指定は動かない。
        let dbPortID = model.services[0].ports[1].id
        model.makePrimary(dbPortID, in: model.services[0].id)

        let project = try model.build()
        #expect(project.services[0].ports.map(\.isPrimary) == [false, true])
        #expect(project.services[1].primaryPort?.port == 3000)
    }

    // MARK: - 検証エラー

    @Test("不正なサービス入力を、入力箇所が分かる検証エラーとして返す")
    func invalidServiceInputProducesSpecificErrors() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        // 1件目: 名前あり、実行ファイルなし、ポートが数値でない。
        model.services[0].name = "Web"
        model.services[0].executable = "  "
        model.services[0].ports = [ProjectFormModel.PortDraft(port: "３０００", isPrimary: true)]
        // 2件目: 名前が空、ポート範囲外。
        model.addService()
        model.services[1].executable = "/usr/bin/true"
        model.services[1].ports = [ProjectFormModel.PortDraft(port: "70000", isPrimary: true)]
        // 3件目: ポートを入力しているのに代表が無い。
        model.addService()
        model.services[2].name = "Worker"
        model.services[2].executable = "/usr/bin/true"
        model.services[2].ports = [
            ProjectFormModel.PortDraft(port: "9000", isPrimary: false),
            ProjectFormModel.PortDraft(port: "9000", isPrimary: false),
        ]

        let failure = #expect(throws: ValidationFailure.self) { try model.build() }
        let errors = try #require(failure?.errors)

        #expect(errors.contains(.executableEmpty(service: "Web")))
        #expect(errors.contains(.portNotANumber(service: "Web", value: "３０００")))
        #expect(errors.contains(.serviceNameEmpty(serviceIndex: 1)))
        #expect(errors.contains(.portOutOfRange(service: "#2", port: 70_000)))
        #expect(errors.contains(.duplicatePortInService(service: "Worker", port: 9000)))
        #expect(errors.contains(.missingPrimaryPort(service: "Worker")))
        // 空文字や 0 で補完していない。
        #expect(!errors.contains(.portOutOfRange(service: "Web", port: 0)))

        // 設定ファイルは作られていない。
        #expect(!FileManager.default.fileExists(atPath: ProjectStore(directory: directory).fileURL.path))
    }

    @Test("ディレクトリ未選択でも、欠けている必須値をまとめて返す")
    func missingDirectoryStillReportsEveryMissingField() {
        let model = ProjectFormModel()
        model.services[0].name = "Web"

        let failure = #expect(throws: ValidationFailure.self) { try model.build() }
        let errors = failure?.errors ?? []

        #expect(errors.contains(.projectNameEmpty))
        #expect(errors.contains(.workingDirectoryNameEmpty(directoryIndex: 0)))
        #expect(errors.contains(.workingDirectoryPathEmpty(name: "#1")))
        #expect(errors.contains(.executableEmpty(service: "Web")))
    }

    @Test("サービスを全部消したら保存できない")
    func projectWithoutServicesIsRejected() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = ProjectFormModel()
        model.name = "Bell"
        model.workingDirectories[0].directory = directory
        model.workingDirectories[0].name = "App"
        model.removeService(model.services[0].id)

        let failure = #expect(throws: ValidationFailure.self) { try model.build() }
        #expect(failure?.errors.contains(.noServices) == true)
    }

    @Test("起動確認はポートの有無によらずプロセスの生存だけを見る")
    func startupObservationDoesNotDependOnPorts() throws {
        let directory = try makeTemporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let withPort = try StartupObservationPolicy.spec(
            for: makeService(port: 8288, workingDirectory: directory)
        )
        let withoutPort = try StartupObservationPolicy.spec(
            for: makeService(port: nil, workingDirectory: directory)
        )
        #expect(withPort == withoutPort)
        #expect(!withPort.description.contains("8288"))
    }
}
