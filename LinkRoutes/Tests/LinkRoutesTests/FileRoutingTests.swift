import XCTest
@testable import LinkRoutes

/// Stands in for Launch Services; never the real one.
final class FakeDefaults: FileDefaultsService {
    /// Keyed by content type. An ordinary extension is its own type; aliases share one.
    var defaults: [String: String] = [:]
    var aliases = ["jpeg": "jpg", "text": "txt", "htm": "html"]
    var undeclared: Set<String> = ["zzqx"]
    var installed: Set<String> = ["com.example.editor", "com.example.viewer", "com.example.old", "com.example.other"]
    var candidates: [String: [String]] = [:]
    var failingExtensions: Set<String> = []
    var setLog: [String] = []
    var canonicalizer: (String) -> String? = { _ in nil }
    var beforeSet: (String) -> Void = { _ in }
    func typeIdentifier(forExtension ext: String) -> String? { undeclared.contains(ext) ? nil : (aliases[ext] ?? ext) }
    func defaultApplication(forType type: String) -> String? { defaults[type] }
    func setDefaultApplication(_ id: String, forType type: String) throws {
        beforeSet(type)
        if failingExtensions.contains(type) { throw RouteError.invalid("refused") }
        defaults[type] = id; setLog.append("\(type)=\(id)")
    }
    func isInstalled(_ id: String) -> Bool { id != applicationIdentifier && installed.contains(id) }
    func candidateApplications(forType type: String) -> [String] { candidates[type] ?? [] }
    func canonicalPath(_ path: String) -> String? { canonicalizer(path) }
}

final class FileRoutingTests: XCTestCase {
    let home = "/Users/tester"
    var fake = FakeDefaults()
    var root: URL!
    override func setUpWithError() throws {
        fake = FakeDefaults()
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lr-files-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Work/sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func rule(_ id: String, _ ext: String = "md", folder: String? = nil, app: String = "com.example.editor") -> FileRule {
        FileRule(id: id, fileExtension: ext, folder: folder, applicationIdentifier: app)
    }
    func decide(_ path: String, _ rules: [FileRule], fallbacks: [String: TakenType] = [:]) -> FileDecision {
        FileRouting.decide(file: URL(fileURLWithPath: path), rules: rules, fallbacks: fallbacks, service: fake, home: home)
    }

    // MARK: Matching

    func testExtensionAndFolderMatch() {
        let rules = [rule("1", folder: "/Users/tester/Work")]
        XCTAssertEqual(decide("/Users/tester/Work/a.md", rules), .open(application: "com.example.editor", usedFallback: false))
        XCTAssertEqual(decide("/Users/tester/Work/deep/er/a.MD", rules), .open(application: "com.example.editor", usedFallback: false))
        guard case .unavailable = decide("/Users/tester/Work/a.txt", rules) else { return XCTFail("other extension must not match") }
        guard case .unavailable = decide("/Users/tester/Workshop/a.md", rules) else { return XCTFail("sibling folder with a shared prefix must not match") }
    }
    func testRuleWithoutFolderMatchesAnywhere() {
        XCTAssertEqual(decide("/anywhere/at/all.md", [rule("1")]), .open(application: "com.example.editor", usedFallback: false))
    }
    func testFirstMatchWinsInListOrder() {
        let specific = rule("1", folder: "/Users/tester/Work", app: "com.example.viewer")
        let general = rule("2")
        XCTAssertEqual(decide("/Users/tester/Work/a.md", [specific, general]), .open(application: "com.example.viewer", usedFallback: false))
        XCTAssertEqual(decide("/Users/tester/Work/a.md", [general, specific]), .open(application: "com.example.editor", usedFallback: false))
        XCTAssertEqual(decide("/Users/tester/Else/a.md", [specific, general]), .open(application: "com.example.editor", usedFallback: false))
    }
    func testTildeExpandsToCurrentUser() {
        XCTAssertEqual(decide("/Users/tester/Notes/a.md", [rule("1", folder: "~/Notes")]), .open(application: "com.example.editor", usedFallback: false))
        guard case .unavailable = decide("/Users/other/Notes/a.md", [rule("1", folder: "~/Notes")]) else { return XCTFail("another user's folder must not match") }
    }
    func testTrailingSlashIsIgnored() {
        XCTAssertEqual(decide("/Users/tester/Work/a.md", [rule("1", folder: "/Users/tester/Work/")]), .open(application: "com.example.editor", usedFallback: false))
    }
    func testRootFolderMatchesEverything() {
        XCTAssertEqual(decide("/Users/tester/a.md", [rule("1", folder: "/")]), .open(application: "com.example.editor", usedFallback: false))
    }
    func testDotDotAndSymlinkResolve() throws {
        let work = root.appendingPathComponent("Work"), other = root.appendingPathComponent("Other")
        let file = other.appendingPathComponent("a.md")
        try Data().write(to: file)
        try Data().write(to: work.appendingPathComponent("w.md"))
        // A link inside Work that points at Other must not make Other's file match a Work rule, and a
        // file reached through it belongs to Other.
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("alias"), withDestinationURL: other)
        let workRule = [rule("1", folder: work.path)], otherRule = [rule("1", folder: other.path)]
        func d(_ path: String, _ rules: [FileRule]) -> FileDecision { FileRouting.decide(file: URL(fileURLWithPath: path), rules: rules, fallbacks: [:], service: fake, home: home) }
        guard case .unavailable = d(work.path + "/alias/a.md", workRule) else { return XCTFail("alias path dodged to the wrong folder") }
        XCTAssertEqual(d(work.path + "/alias/a.md", otherRule), .open(application: "com.example.editor", usedFallback: false))
        // `..` that climbs out of the folder does not match; one that stays inside does.
        guard case .unavailable = d(work.path + "/sub/../../Other/a.md", workRule) else { return XCTFail(".. escaped the folder yet matched") }
        XCTAssertEqual(d(work.path + "/sub/../w.md", workRule), .open(application: "com.example.editor", usedFallback: false))
        // A rule whose folder is itself an alias matches files under the real folder.
        let aliasRule = [rule("1", folder: work.path + "/alias")]
        XCTAssertEqual(d(other.path + "/a.md", aliasRule), .open(application: "com.example.editor", usedFallback: false))
    }

    // MARK: Fallback, missing apps, self

    func testNoRuleGoesToFallback() {
        let fallbacks = ["md": TakenType(fallback: "com.example.old")]
        XCTAssertEqual(decide("/x/a.md", [rule("1", folder: "/Users/tester/Work")], fallbacks: fallbacks), .open(application: "com.example.old", usedFallback: true))
    }
    func testMissingTargetUsesFallbackAndMissingBothFails() {
        let fallbacks = ["md": TakenType(fallback: "com.example.old")]
        fake.installed.remove("com.example.editor")
        XCTAssertEqual(decide("/x/a.md", [rule("1")], fallbacks: fallbacks), .open(application: "com.example.old", usedFallback: true))
        fake.installed.remove("com.example.old")
        guard case .unavailable = decide("/x/a.md", [rule("1")], fallbacks: fallbacks) else { return XCTFail("no app is available") }
        guard case .unavailable = decide("/x/a.md", [rule("1")]) else { return XCTFail("no fallback recorded") }
    }
    func testNoRecordedFallbackUsesAnotherAppForTheType() {
        fake.candidates["md"] = [applicationIdentifier, "com.example.viewer"]
        XCTAssertEqual(decide("/x/a.md", []), .open(application: "com.example.viewer", usedFallback: true))
        fake.installed.remove("com.example.viewer")
        guard case .unavailable = decide("/x/a.md", []) else { return XCTFail("only LinkRoutes can open it") }
    }
    func testNeverRoutesToItself() {
        let selfRule = rule("1", app: applicationIdentifier)
        guard case .unavailable = decide("/x/a.md", [selfRule]) else { return XCTFail("a rule for itself was used") }
        let fallbacks = ["md": TakenType(fallback: applicationIdentifier)]
        guard case .unavailable = decide("/x/a.md", [selfRule], fallbacks: fallbacks) else { return XCTFail("a fallback of itself was used") }
        // A matching rule that cannot be used sends the file to the fallback, like a missing app.
        XCTAssertEqual(decide("/x/a.md", [selfRule, rule("2")], fallbacks: ["md": TakenType(fallback: "com.example.old")]), .open(application: "com.example.old", usedFallback: true))
    }
    func testBlockedAndEmptyExtensionsAreNotRouted() {
        guard case .unavailable = decide("/x/run.sh", [rule("1", "sh")]) else { return XCTFail() }
        guard case .unavailable = decide("/x/README", [rule("1")]) else { return XCTFail() }
    }

    // MARK: Validation

    func validate(_ rules: [FileRule]) throws -> [FileRule] { try FileRouting.validate(rules, service: fake, home: home) }

    func testRejectedExtensions() {
        for ext in ["app", "command", "sh", "zsh", "bash", "pkg", "dmg", "APP", "mpkg", "workflow", "scpt"] {
            XCTAssertThrowsError(try validate([rule("1", ext)]), ext)
        }
        for ext in ["", ".md", "m d", "md!", "a1234567890123456", "mé"] { XCTAssertThrowsError(try validate([rule("1", ext)]), ext) }
        XCTAssertEqual(try validate([rule("1", "MD")]).first?.fileExtension, "md")
        XCTAssertEqual(try validate([rule("1", String(repeating: "a", count: 16))]).count, 1)
    }
    func testDuplicatesAreSameExtensionAndResolvedFolder() throws {
        XCTAssertThrowsError(try validate([rule("1"), rule("2")]))
        XCTAssertThrowsError(try validate([rule("1", folder: "/Users/tester/Work"), rule("2", folder: "~/Work/")]))
        XCTAssertThrowsError(try validate([rule("1", folder: "/Users/tester/Work"), rule("2", folder: "/Users/tester/Work/sub/..")]))
        XCTAssertNoThrow(try validate([rule("1", folder: "/Users/tester/Work"), rule("2")]))
        XCTAssertNoThrow(try validate([rule("1"), rule("2", "txt")]))
        XCTAssertThrowsError(try validate([rule("1"), rule("1", "txt")]), "duplicate ids")
    }
    func testRejectsSelfMissingAppBadFolderAndTooMany() {
        XCTAssertThrowsError(try validate([rule("1", app: applicationIdentifier)]))
        XCTAssertThrowsError(try validate([rule("1", app: "com.example.ghost")]))
        XCTAssertThrowsError(try validate([rule("1", app: "bad id")]))
        XCTAssertThrowsError(try validate([rule("1", folder: "relative/path")]))
        XCTAssertThrowsError(try validate([rule("1", folder: "")]))
        let many = (0..<101).map { rule("\($0)", "x\($0)") }
        XCTAssertThrowsError(try validate(many))
        XCTAssertNoThrow(try validate(Array(many.prefix(100))))
    }

    // MARK: Taking over and releasing

    func testFirstRuleTakesOverAndRecordsFallback() throws {
        fake.defaults["md"] = "com.example.old"
        let outcome = try FileTakeover.apply(rules: [rule("1")], to: FileRoutingState(), service: fake)
        XCTAssertEqual(fake.defaults["md"], applicationIdentifier)
        XCTAssertEqual(outcome.state.taken["md"]?.fallback, "com.example.old")
        XCTAssertEqual(FileTakeover.takenOver(outcome.state, service: fake), ["md"])
        // A second rule for the same extension changes nothing and keeps the record.
        fake.setLog = []
        let again = try FileTakeover.apply(rules: [rule("1"), rule("2", folder: "/a")], to: outcome.state, service: fake)
        XCTAssertEqual(fake.setLog, [])
        XCTAssertEqual(again.state.taken["md"]?.fallback, "com.example.old")
    }
    func testLastRuleRemovedRestoresAndForgets() throws {
        fake.defaults["md"] = "com.example.old"; fake.defaults["txt"] = "com.example.other"
        var state = try FileTakeover.apply(rules: [rule("1"), rule("2", "txt")], to: FileRoutingState(), service: fake).state
        state = try FileTakeover.apply(rules: [rule("1")], to: state, service: fake).state
        XCTAssertEqual(fake.defaults["txt"], "com.example.other")
        XCTAssertEqual(fake.defaults["md"], applicationIdentifier)
        XCTAssertNil(state.taken["txt"])
        state = try FileTakeover.apply(rules: [], to: state, service: fake).state
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertTrue(state.taken.isEmpty)
    }
    func testFailedTakeOverUndoesEarlierTypesAndSavesNothing() throws {
        fake.defaults["md"] = "com.example.old"; fake.defaults["txt"] = "com.example.other"
        fake.failingExtensions = ["txt"]
        XCTAssertThrowsError(try FileTakeover.apply(rules: [rule("1"), rule("2", "txt")], to: FileRoutingState(), service: fake))
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertEqual(fake.defaults["txt"], "com.example.other")
    }
    func testAlreadyOursWithoutRecordKeepsNoFallback() throws {
        fake.defaults["md"] = applicationIdentifier
        let state = try FileTakeover.apply(rules: [rule("1")], to: FileRoutingState(), service: fake).state
        XCTAssertNil(state.taken["md"]?.fallback)
        XCTAssertTrue(fake.setLog.isEmpty)
    }
    func testDefaultChangedElsewhereIsTakenAgainWithNewFallback() throws {
        fake.defaults["md"] = "com.example.old"
        let state = try FileTakeover.apply(rules: [rule("1")], to: FileRoutingState(), service: fake).state
        fake.defaults["md"] = "com.example.other"  // user picked another app in Finder
        XCTAssertEqual(FileTakeover.takenOver(state, service: fake), [])
        let again = try FileTakeover.apply(rules: [rule("1")], to: state, service: fake).state
        XCTAssertEqual(fake.defaults["md"], applicationIdentifier)
        XCTAssertEqual(again.taken["md"]?.fallback, "com.example.other")
    }
    func testReleaseLeavesAUserChosenDefaultAlone() throws {
        fake.defaults["md"] = "com.example.old"
        let state = try FileTakeover.apply(rules: [rule("1")], to: FileRoutingState(), service: fake).state
        fake.defaults["md"] = "com.example.other"
        fake.setLog = []
        let outcome = try FileTakeover.apply(rules: [], to: state, service: fake)
        XCTAssertTrue(fake.setLog.isEmpty)
        XCTAssertEqual(fake.defaults["md"], "com.example.other")
        XCTAssertTrue(outcome.state.taken.isEmpty)
    }
    func testReleaseWithMissingFallbackPicksACandidateOrReports() throws {
        fake.defaults["md"] = "com.example.old"
        let state = try FileTakeover.apply(rules: [rule("1")], to: FileRoutingState(), service: fake).state
        fake.installed.remove("com.example.old")
        fake.candidates["md"] = [applicationIdentifier, "com.example.viewer"]
        let outcome = try FileTakeover.apply(rules: [], to: state, service: fake)
        XCTAssertEqual(fake.defaults["md"], "com.example.viewer")
        XCTAssertTrue(outcome.failures.isEmpty)
        fake.defaults["md"] = applicationIdentifier
        fake.candidates = [:]
        let stuck = try FileTakeover.apply(rules: [], to: FileRoutingState(rules: [], taken: ["md": TakenType(fallback: "com.example.old")]), service: fake)
        XCTAssertEqual(stuck.failures, ["md"])
    }

    // MARK: Types, records and volumes

    func testExtensionsOfOneTypeShareOneRecordAndOneTakeOver() throws {
        fake.defaults["jpg"] = "com.example.old"
        let state = try FileTakeover.apply(rules: [rule("1", "jpg"), rule("2", "jpeg")], to: FileRoutingState(), service: fake).state
        XCTAssertEqual(fake.setLog, ["jpg=\(applicationIdentifier)"])
        XCTAssertEqual(Array(state.taken.keys), ["jpg"])
        XCTAssertEqual(state.taken["jpg"]?.fallback, "com.example.old")
        XCTAssertEqual(FileTakeover.takenOver(state, service: fake), ["jpeg", "jpg"])
    }
    func testTypeIsReleasedOnlyWhenNoExtensionOfItHasARule() throws {
        fake.defaults["jpg"] = "com.example.old"
        var state = try FileTakeover.apply(rules: [rule("1", "jpg"), rule("2", "jpeg")], to: FileRoutingState(), service: fake).state
        state = try FileTakeover.apply(rules: [rule("2", "jpeg")], to: state, service: fake).state
        XCTAssertEqual(fake.defaults["jpg"], applicationIdentifier, "jpeg still has a rule")
        XCTAssertNotNil(state.taken["jpg"])
        state = try FileTakeover.apply(rules: [], to: state, service: fake).state
        XCTAssertEqual(fake.defaults["jpg"], "com.example.old")
        XCTAssertTrue(state.taken.isEmpty)
    }
    func testFileOfAnotherExtensionOfTheTypeOpensInRecordedFallback() {
        let fallbacks = ["jpg": TakenType(fallback: "com.example.old")]
        XCTAssertEqual(decide("/x/a.jpeg", [rule("1", "jpg", app: "com.example.viewer")], fallbacks: fallbacks), .open(application: "com.example.old", usedFallback: true))
        XCTAssertEqual(decide("/x/a.jpg", [rule("1", "jpg", app: "com.example.viewer")], fallbacks: fallbacks), .open(application: "com.example.viewer", usedFallback: false))
    }
    func testRecordIsOnDiskBeforeTheSystemIsAskedAndRemovedWhenRefused() throws {
        let store = FileRoutingStore(defaults: suite())
        fake.defaults["md"] = "com.example.old"
        var recordedBeforeSet: String??
        fake.beforeSet = { type in recordedBeforeSet = .some(store.load().taken[type]?.fallback) }
        try store.replace(rules: [rule("1")], service: fake)
        XCTAssertEqual(recordedBeforeSet, .some("com.example.old"), "the fallback must be saved before the default changes")
        try store.stopRouting(service: fake)
        fake.failingExtensions = ["md"]
        XCTAssertThrowsError(try store.replace(rules: [rule("1")], service: fake))
        XCTAssertEqual(store.load(), FileRoutingState(), "a refused take-over leaves no record")
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
    }
    func testInterruptedTakeOverIsRecoverableThroughStopRouting() throws {
        let store = FileRoutingStore(defaults: suite())
        // Crash after the record was written, before the default changed.
        fake.defaults["md"] = "com.example.old"
        try store.save(FileRoutingState(rules: [], taken: ["md": TakenType(fallback: "com.example.old")]))
        try store.stopRouting(service: fake)
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertEqual(store.load(), FileRoutingState())
        // Crash after the default changed, before the rules were saved.
        fake.defaults["md"] = applicationIdentifier
        try store.save(FileRoutingState(rules: [], taken: ["md": TakenType(fallback: "com.example.old")]))
        XCTAssertEqual(FileTakeover.ownedTypes(store.load(), service: fake), ["md"], "the menu must still offer Stop Routing Files")
        try store.stopRouting(service: fake)
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertEqual(store.load(), FileRoutingState())
    }
    func testFolderMatchFollowsTheVolumesCaseRules() {
        let rules = [rule("1", folder: "~/Notes")]
        guard case .unavailable = decide("/Users/tester/notes/a.md", rules) else { return XCTFail("case differs and the volume is case-sensitive") }
        fake.canonicalizer = { $0.lowercased() }  // a case-insensitive volume spells both the same way
        XCTAssertEqual(decide("/Users/tester/notes/a.md", rules), .open(application: "com.example.editor", usedFallback: false))
        XCTAssertEqual(decide("/Users/tester/NOTES/deep/a.md", rules), .open(application: "com.example.editor", usedFallback: false))
        XCTAssertThrowsError(try validate([rule("1", folder: "~/Notes"), rule("2", folder: "~/notes")]), "same folder on that volume")
    }
    func testRealCanonicalPathIsUsedWhenTheFolderExists() throws {
        let canonical = LaunchServicesFileDefaults().canonicalPath(root.path)
        XCTAssertNotNil(canonical)
        XCTAssertNil(LaunchServicesFileDefaults().canonicalPath(root.path + "/missing"))
    }
    func testTypeConformanceBlocksEvenWithoutTheList() {
        for ext in ["app", "dmg", "pkg", "sparseimage", "iso"] { XCTAssertTrue(FileRouting.isBlockedByType(ext), ext) }
        for ext in ["py", "rb", "js", "md", "txt", "json"] {
            XCTAssertFalse(FileRouting.isBlockedByType(ext), ext)
            XCTAssertNoThrow(try FileRouting.normalizedExtension(ext), ext)
        }
    }
    func testExtensionWithNoDeclaredTypeIsRejected() {
        XCTAssertThrowsError(try validate([rule("1", "zzqx")])) { XCTAssertTrue($0.localizedDescription.contains("zzqx")) }
        XCTAssertNil(LaunchServicesFileDefaults().typeIdentifier(forExtension: "zzqx9"))
        XCTAssertEqual(LaunchServicesFileDefaults().typeIdentifier(forExtension: "jpg"), LaunchServicesFileDefaults().typeIdentifier(forExtension: "jpeg"))
    }

    // MARK: Store and stop

    func suite() -> UserDefaults {
        let name = "lr-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testStoreRoundTripAndStopRoutingRestoresEveryType() throws {
        let store = FileRoutingStore(defaults: suite())
        fake.defaults["md"] = "com.example.old"; fake.defaults["txt"] = "com.example.other"
        try store.replace(rules: [rule("1"), rule("2", "txt")], service: fake)
        XCTAssertEqual(store.load().rules.map(\.id), ["1", "2"])
        XCTAssertEqual(FileTakeover.takenOver(store.load(), service: fake), ["md", "txt"])
        try store.stopRouting(service: fake)
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertEqual(fake.defaults["txt"], "com.example.other")
        XCTAssertEqual(store.load(), FileRoutingState())
    }
    func testStopRoutingKeepsRecordsItCouldNotRestore() throws {
        let store = FileRoutingStore(defaults: suite())
        fake.defaults["md"] = "com.example.old"; fake.defaults["txt"] = "com.example.other"
        try store.replace(rules: [rule("1"), rule("2", "txt")], service: fake)
        fake.failingExtensions = ["txt"]
        XCTAssertThrowsError(try store.stopRouting(service: fake)) { XCTAssertTrue($0 is PartialRestore) }
        XCTAssertEqual(fake.defaults["md"], "com.example.old")
        XCTAssertEqual(store.load().rules, [])
        XCTAssertEqual(store.load().taken["txt"]?.fallback, "com.example.other", "the fallback must survive so files still open")
    }

    // MARK: Settings bridge

    let browsers = [Browser(identifier: "com.apple.Safari", name: "Safari", profiles: [])]
    let current = Configuration(defaultBrowserIdentifier: "com.apple.Safari", rules: [])
    func patch(_ json: String) throws -> SettingsPatch { try SettingsPatch(data: Data(json.utf8), current: current, browsers: browsers, fileService: fake) }

    func testPatchWithFileRulesIsValidatedAndNormalized() throws {
        let p = try patch(#"{"fileRules":[{"id":"a","fileExtension":"MD","folder":"~/Notes/","applicationIdentifier":"com.example.editor"},{"id":"b","fileExtension":"txt","folder":null,"applicationIdentifier":"com.example.viewer"}]}"#)
        XCTAssertEqual(p.fileRules?.map(\.fileExtension), ["md", "txt"])
        XCTAssertEqual(p.fileRules?.first?.folder, "~/Notes")
        XCTAssertNil(p.fileRules?[1].folder)
        XCTAssertEqual(p.configuration, current)
    }
    func testBadFileRulePatchesAreRejectedWhole() {
        let good = #"{"id":"a","fileExtension":"md","applicationIdentifier":"com.example.editor"}"#
        for bad in [
            #"{"fileRules":[\#(good),{"id":"b","fileExtension":"sh","applicationIdentifier":"com.example.editor"}]}"#,
            #"{"fileRules":[\#(good),{"id":"b","fileExtension":"md","applicationIdentifier":"com.example.viewer"}]}"#,
            #"{"fileRules":[{"id":"a","fileExtension":"md","applicationIdentifier":"com.andrew.linkroutes"}]}"#,
            #"{"fileRules":[\#(good)],"stopRoutingFiles":true}"#,
            #"{"fileRules":[{"id":"a","fileExtension":"md","applicationIdentifier":"com.example.editor","extra":1}]}"#,
            #"{"fileRules":[{"id":"a","fileExtension":"md"}]}"#,
            #"{"fileRules":[{"id":"a","fileExtension":"md","folder":5,"applicationIdentifier":"com.example.editor"}]}"#,
            #"{"fileRules":"nope"}"#,
            #"{"stopRoutingFiles":"yes"}"#,
            #"{"takenOverExtensions":["md"]}"#,
        ] { XCTAssertThrowsError(try patch(bad), bad) }
    }
    func testStopRoutingFilesPatch() throws {
        XCTAssertTrue(try patch(#"{"stopRoutingFiles":true}"#).stopRoutingFiles)
        XCTAssertFalse(try patch(#"{"stopRoutingFiles":false}"#).stopRoutingFiles)
    }
    func testOlderPatchesStillValidate() throws {
        let p = try patch(#"{"launchAtLogin":true,"stripsTrackingParameters":false}"#)
        XCTAssertNil(p.fileRules)
        XCTAssertFalse(p.stopRoutingFiles)
        XCTAssertEqual(p.launchAtLogin, true)
    }
    func testVersion120ConfigurationLoadsUnchanged() throws {
        let saved = #"{"defaultBrowserIdentifier":"com.apple.Safari","rules":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","domain":"example.com","includeSubdomains":true,"browserIdentifier":"com.google.Chrome","sourceBundleIdentifier":"com.tinyspeck.slackmacgap"}],"stripsTrackingParameters":false,"unwrapsRedirects":true}"#
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(saved.utf8))
        XCTAssertEqual(configuration.rules.first?.domain, "example.com")
        XCTAssertEqual(configuration.rules.first?.sourceBundleIdentifier, "com.tinyspeck.slackmacgap")
        XCTAssertFalse(configuration.stripsTrackingParameters)
        XCTAssertTrue(configuration.unwrapsRedirects)
        // No file-routing state saved yet: an empty one, no takeovers.
        XCTAssertEqual(FileRoutingStore(defaults: suite()).load(), FileRoutingState())
        // The saved link configuration keeps its exact encoding keys (no file keys leak in).
        let keys = Set((try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]).keys)
        XCTAssertEqual(keys, ["defaultBrowserIdentifier", "rules", "stripsTrackingParameters", "unwrapsRedirects"])
    }
    func testSnapshotEncodesContractKeys() throws {
        let snapshot = SettingsSnapshot(launchAtLogin: false, loginStatus: "x", defaultBrowserIdentifier: "com.apple.Safari", rules: [], availableBrowsers: [], isDefaultBrowser: false, stripsTrackingParameters: true, unwrapsRedirects: false,
                                        fileRules: [rule("a", folder: "/x"), rule("b", "txt")], takenOverExtensions: ["md"])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        XCTAssertEqual(object["takenOverExtensions"] as? [String], ["md"])
        let rows = object["fileRules"] as! [[String: Any]]
        XCTAssertEqual(Set(rows[0].keys), ["id", "fileExtension", "folder", "applicationIdentifier"])
        XCTAssertEqual(Set(rows[1].keys), ["id", "fileExtension", "applicationIdentifier"])
    }
}
