import Foundation
import Testing
@testable import DevSwitcherCore

@Suite("lsof 出力の解析")
struct PortInspectorTests {
    @Test("フィールド出力から実測ポートを取り出す")
    func parsesFieldOutput() throws {
        let output = """
        p26713
        g26713
        f3
        n*:9977
        """
        let ports = try PortInspector.parse(output)
        #expect(ports == [ObservedPort(port: 9977, pid: 26_713, address: "*")])
    }

    @Test("複数プロセス・複数ポートを解析する")
    func parsesMultipleEntries() throws {
        let output = """
        p100
        g100
        f3
        n127.0.0.1:54321
        f4
        n[::1]:54322
        p101
        g100
        f5
        n*:3000
        """
        let ports = try PortInspector.parse(output)
        #expect(ports.count == 3)
        #expect(ports.contains(ObservedPort(port: 54_321, pid: 100, address: "127.0.0.1")))
        #expect(ports.contains(ObservedPort(port: 54_322, pid: 100, address: "[::1]")))
        #expect(ports.contains(ObservedPort(port: 3000, pid: 101, address: "*")))
    }

    @Test("該当なし（空出力）は空配列")
    func emptyOutputIsEmptyList() throws {
        #expect(try PortInspector.parse("").isEmpty)
    }

    @Test("解析できない出力をポートなしとして扱わない")
    func unparsableOutputThrows() {
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("p100\nf3\nn*:not-a-port")
        }
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("pXYZ\nn*:3000")
        }
        // プロセス行より先にアドレス行が来る出力も受け付けない。
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parse("n*:3000")
        }
    }

    @Test("listen していないプロセスグループでは空配列を返す")
    func noListeningPortsForCurrentProcess() async throws {
        // テストプロセス自身のプロセスグループ。listen していなくてもエラーにしない。
        let ports = try await PortInspector.listeningPorts(processGroupID: getpgrp())
        #expect(ports.allSatisfy { $0.port > 0 })
    }

    @Test("ポート占有者の PID・コマンド・利用者・プロセスグループを取り出す")
    func parsesPortHolders() throws {
        let output = """
        p26877
        g26872
        cnc
        Lshoheiyamada
        f3
        n*:51777
        """
        let holders = try PortInspector.parseHolders(output)
        #expect(holders.count == 1)
        #expect(holders[0].port == 51_777)
        #expect(holders[0].pid == 26_877)
        #expect(holders[0].processGroupID == 26_872)
        #expect(holders[0].command == "nc")
        #expect(holders[0].loginName == "shoheiyamada")
    }

    @Test("プロセスが変われば属性を引き継がない")
    func doesNotCarryAttributesAcrossProcesses() throws {
        let output = """
        p100
        g100
        cnode
        Lalice
        f3
        n127.0.0.1:3000
        p200
        f4
        n127.0.0.1:3001
        """
        let holders = try PortInspector.parseHolders(output)
        #expect(holders.count == 2)
        #expect(holders[1].pid == 200)
        // 直前のプロセスのコマンド名や利用者を流用しない。
        #expect(holders[1].command == nil)
        #expect(holders[1].loginName == nil)
        // プロセスグループが分からない場合、PID で代用しない。
        #expect(holders[1].processGroupID == nil)
    }

    @Test("解析できない占有者の出力は「空き」と扱わない")
    func unparsableHolderOutputThrows() {
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parseHolders("p100\nf3\nn*:not-a-port")
        }
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parseHolders("n*:3000")
        }
        #expect(throws: PortInspectorError.self) {
            _ = try PortInspector.parseHolders("p100\ngXYZ\nn*:3000")
        }
    }

    @Test("問い合わせるポートが無ければ lsof を実行しない")
    func emptyPortListReturnsEmpty() async throws {
        #expect(try await PortInspector.holders(ofPorts: []).isEmpty)
    }

    @Test("該当なしの終了コード 1 は正常系として扱う")
    func exitCodeOneIsNotAnError() throws {
        // lsof は該当プロセスがない場合も 1 を返す。
        #expect(throws: Never.self) {
            try PortInspector.checkTermination(
                CapturedOutput(status: .exited(code: 1), standardOutput: Data(), standardError: Data())
            )
        }
        #expect(throws: Never.self) {
            try PortInspector.checkTermination(
                CapturedOutput(status: .exited(code: 0), standardOutput: Data(), standardError: Data())
            )
        }
    }

    @Test("lsof の異常終了は、出力が空でも「ポートなし」と扱わない")
    func abnormalTerminationIsNotTreatedAsEmpty() throws {
        // シグナル終了。空出力を「空き」と読むと、2段階ゲートの根拠が崩れる。
        #expect(throws: PortInspectorError.self) {
            try PortInspector.checkTermination(
                CapturedOutput(
                    status: .signaled(signal: SIGSEGV),
                    standardOutput: Data(),
                    standardError: Data()
                )
            )
        }
        // 該当なし以外の終了コード。
        #expect(throws: PortInspectorError.self) {
            try PortInspector.checkTermination(
                CapturedOutput(status: .exited(code: 9), standardOutput: Data(), standardError: Data())
            )
        }
        // 終了状態を取得できなかった場合も成功と区別する。
        #expect(throws: PortInspectorError.self) {
            try PortInspector.checkTermination(
                CapturedOutput(status: .unknown, standardOutput: Data(), standardError: Data())
            )
        }
    }

    @Test("実際に listen しているポートの占有者を実測できる")
    func findsRealPortHolder() async throws {
        let server = try LocalTCPServer(behavior: .silent)
        defer { server.stop() }

        let holders = try await PortInspector.holders(ofPorts: [server.port])
        #expect(holders.count >= 1)
        #expect(holders.allSatisfy { $0.port == server.port })
        // テストプロセス自身が握っている。
        #expect(holders.contains { $0.pid == getpid() })
    }

    @Test("解放されたポートは占有者なしとして返す")
    func releasedPortHasNoHolder() async throws {
        let server = try LocalTCPServer(behavior: .silent)
        let port = server.port
        server.stop()

        #expect(await waitUntil {
            let holders = try? await PortInspector.holders(ofPorts: [port])
            return holders?.isEmpty == true
        })
    }
}
