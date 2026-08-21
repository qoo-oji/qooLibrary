import Foundation
import QooKit
import Testing
@testable import QooInfrastructure

@Suite("差分スキャンの走査範囲 [SY-03][SY-04]")
struct ScanUnitPlannerTests {

    /// 実体の申告を表で与える。実 I/O を使わずに規則だけを試す。
    func planner(_ kinds: [String: ScanUnitPlanner.PathKind])
        -> (String) -> ScanUnitPlanner.PathKind
    {
        { kinds[$0] ?? .file }
    }

    // MARK: - 基本

    @Test("ファイルの変更は、その親を非再帰で見る")
    func fileChangeScansItsParentOnly() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A/作品/第01巻.cbz"], kind: planner([:])))
        #expect(units == [.enumerate(relativePath: "作者A/作品", recursive: false)])
    }

    /// **フォルダごと移動されてきた場合、中のファイルは 1 件も報告されない**
    /// （同一ボリューム内の `rename` はファイルを作らない）。親を非再帰で
    /// 見ると中身が 1 件も DB に載らない。
    @Test("ディレクトリの変更は、その中を再帰で見る")
    func directoryChangeScansItselfRecursively() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A/新しい作品"],
            kind: planner(["作者A/新しい作品": .directory])))
        #expect(units == [.enumerate(relativePath: "作者A/新しい作品", recursive: true)])
    }

    @Test("ライブラリ根の直下のファイルは、根を非再帰で見る（フルスキャンにしない）")
    func changeAtTheRootScansTheRootNonRecursively() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["単独.cbz"], kind: planner([:])))
        #expect(units == [.enumerate(relativePath: "", recursive: false)])
    }

    @Test("根そのものの変更はフルスキャンへ落とす [SY-04]")
    func changeOfTheRootItselfFallsBackToFullScan() {
        #expect(ScanUnitPlanner.units(changedPaths: [""], kind: planner([:])) == nil)
        #expect(ScanUnitPlanner.units(changedPaths: ["/"], kind: planner([:])) == nil)
        #expect(ScanUnitPlanner.units(changedPaths: ["."], kind: planner([:])) == nil)
    }

    @Test("根を再帰で見る単位ができたらフルスキャンと同じなので落とす [SY-04]")
    func aRecursiveRootUnitFallsBackToFullScan() {
        // 変更のあったパスが根のディレクトリそのものを指す形は上で弾かれるが、
        // 念のため「根が directory と申告された」経路も塞いでおく。
        #expect(ScanUnitPlanner.units(changedPaths: ["", "a/b.cbz"], kind: planner([:])) == nil)
    }

    // MARK: - 剪定

    @Test("祖先に再帰の単位があれば、配下の単位は落とす")
    func nestedUnitsArePruned() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A", "作者A/作品/第01巻.cbz", "作者A/作品"],
            kind: planner(["作者A": .directory, "作者A/作品": .directory])))
        #expect(units == [.enumerate(relativePath: "作者A", recursive: true)])
    }

    /// **素の前方一致では誤る** — `作者AB` が `作者A` の配下に見える。
    @Test("名前の前方一致だけでは剪定しない")
    func siblingWithACommonPrefixIsNotPruned() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A", "作者AB"],
            kind: planner(["作者A": .directory, "作者AB": .directory])))
        #expect(units.count == 2)
        #expect(units.contains(.enumerate(relativePath: "作者A", recursive: true)))
        #expect(units.contains(.enumerate(relativePath: "作者AB", recursive: true)))
    }

    @Test("同じ場所の再帰と非再帰は、再帰に畳む")
    func recursiveAbsorbsNonRecursiveAtTheSamePath() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A/作品", "作者A/作品/第01巻.cbz"],
            kind: planner(["作者A/作品": .directory])))
        #expect(units == [.enumerate(relativePath: "作者A/作品", recursive: true)])
    }

    @Test("同じファイルが何度届いても単位は 1 つ")
    func duplicatePathsCollapse() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: Array(repeating: "作者A/作品/第01巻.cbz", count: 20),
            kind: planner([:])))
        #expect(units.count == 1)
    }

    // MARK: - 消えたもの [ID-06]

    /// 消えたのが**フォルダ**だった場合、その中身は親の「直下だけ」の照合では
    /// 拾えない。だから別の単位として持つ。
    @Test("確かに消えているパスは、配下を孤立にする単位を作る")
    func anAbsentPathProducesAVanishedUnit() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A/消えた作品"],
            kind: planner(["作者A/消えた作品": .absent])))
        #expect(units.contains(.enumerate(relativePath: "作者A", recursive: false)))
        #expect(units.contains(.vanished(relativePath: "作者A/消えた作品")))
    }

    /// **「読めなかった」を「無くなった」と読み替えない**［F2 が最悪の失敗様式］。
    /// 権限やネットワークの一時的な不調でラベルと評価を失う [R-01]。
    @Test("判定できないパスは孤立の単位を作らない")
    func anUnknownPathDoesNotProduceAVanishedUnit() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A/読めない"],
            kind: planner(["作者A/読めない": .unknown])))
        #expect(units == [.enumerate(relativePath: "作者A", recursive: false)])
        #expect(!units.contains { if case .vanished = $0 { return true }; return false })
    }

    @Test("再帰で列挙する範囲に含まれる消失は、別の単位にしない")
    func aVanishedPathInsideARecursiveUnitIsRedundant() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: ["作者A", "作者A/消えた作品"],
            kind: planner(["作者A": .directory, "作者A/消えた作品": .absent])))
        #expect(units == [.enumerate(relativePath: "作者A", recursive: true)])
    }

    // MARK: - 上限 [SY-04]

    @Test("単位が上限を超えたらフルスキャンへ落とす [SY-04]")
    func tooManyUnitsFallBackToFullScan() {
        let paths = (0..<200).map { "作者\($0)/作品.cbz" }
        #expect(ScanUnitPlanner.units(changedPaths: paths, kind: planner([:])) == nil)
    }

    @Test("上限ちょうどは通す")
    func exactlyTheLimitIsAccepted() throws {
        let paths = (0..<AppLimits.Watch.maxIncrementalUnits).map { "作者\($0)/作品.cbz" }
        let units = try #require(ScanUnitPlanner.units(changedPaths: paths, kind: planner([:])))
        #expect(units.count == AppLimits.Watch.maxIncrementalUnits)
    }

    @Test("変更が 1 件も無ければ単位も無い")
    func noChangesProduceNoUnits() {
        #expect(ScanUnitPlanner.units(changedPaths: [], kind: planner([:]))?.isEmpty == true)
    }

    // MARK: - 列挙が到達しない場所 [実機検証で発見]

    /// **差分の走査単位はその場所を起点に直接列挙する**ので、`LibraryEnumerator`
    /// が持つ「隠し項目を飛ばす」規則が効かない。実機で `.Trashes` 相当の
    /// 隠しフォルダの中身が蔵書として取り込まれた。
    @Test("隠しフォルダの中の変更は見ない")
    func changesInsideAHiddenFolderAreIgnored() {
        #expect(ScanUnitPlanner.units(
            changedPaths: [".Trashes/501/捨てた本.cbz"], kind: planner([:]))?.isEmpty == true)
        #expect(ScanUnitPlanner.units(
            changedPaths: ["作者A/.隠し/本.cbz"], kind: planner([:]))?.isEmpty == true)
        #expect(ScanUnitPlanner.units(
            changedPaths: [".DS_Store"], kind: planner([:]))?.isEmpty == true)
    }

    @Test("covers の中の変更は見ない")
    func changesInsideCoversAreIgnored() {
        #expect(ScanUnitPlanner.units(
            changedPaths: ["covers/x.png"], kind: planner([:]))?.isEmpty == true)
    }

    /// **0 件を「フルスキャンへ落とせ」と読んではならない。**
    @Test("走査対象外の変更しか無くてもフルスキャンへ落とさない")
    func onlyUnscannableChangesDoNotTriggerAFullScan() {
        let units = ScanUnitPlanner.units(
            changedPaths: [".fseventsd/0000", ".Trashes/x.cbz"], kind: planner([:]))
        #expect(units != nil, "nil はフルスキャンを意味する")
        #expect(units?.isEmpty == true)
    }

    @Test("対象と対象外が混ざっていれば、対象だけを見る")
    func scannableAndUnscannableChangesMix() throws {
        let units = try #require(ScanUnitPlanner.units(
            changedPaths: [".Trashes/捨てた.cbz", "作者A/残る.cbz"], kind: planner([:])))
        #expect(units == [.enumerate(relativePath: "作者A", recursive: false)])
    }

    // MARK: - 正規化

    @Test("前後のスラッシュは落とす")
    func normalizesSlashes() {
        #expect(ScanUnitPlanner.normalize("/a/b/") == "a/b")
        #expect(ScanUnitPlanner.normalize("a/b") == "a/b")
        #expect(ScanUnitPlanner.normalize("/") == "")
        #expect(ScanUnitPlanner.normalize(".") == "")
    }

    @Test("親の取り出し")
    func parentPaths() {
        #expect(ScanUnitPlanner.parent(of: "a/b/c") == "a/b")
        #expect(ScanUnitPlanner.parent(of: "a") == "")
        #expect(ScanUnitPlanner.parent(of: "") == "")
    }
}
