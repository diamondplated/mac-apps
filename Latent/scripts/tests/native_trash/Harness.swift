import Foundation
import Darwin

struct Failure: Error, CustomStringConvertible { let description: String }
func demand(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure(description: message) }
}
@main struct Harness {
    static func main() {
        do { try run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }
    static func run() throws {
        let fm = FileManager.default
        let volume = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let fixture = volume.appendingPathComponent("fixture-\(UUID().uuidString).bin")
        let expected = Data("isolated recoverable bytes".utf8)
        try expected.write(to: fixture)
        defer { try? fm.removeItem(at: fixture) }
        let destination = volume.appendingPathComponent(".Trashes/\(getuid())", isDirectory: true).resolvingSymlinksInPath()
        try demand(destination.path.hasPrefix(volume.path + "/.Trashes/"), "Trash destination escaped test volume; operation refused")
        let volumeDevice = (try fm.attributesOfItem(atPath: volume.path)[.systemNumber] as? NSNumber)?.uint64Value
        let trashDevice = (try fm.attributesOfItem(atPath: destination.path)[.systemNumber] as? NSNumber)?.uint64Value
        try demand(volumeDevice != nil && volumeDevice == trashDevice, "Trash device does not match disposable volume")
        print("Containment PASS: native Trash directory is on disposable volume")
        let helper = RecoverableTrash()
        let receipt = try helper.trash(fixture)
        guard let trashed = receipt.trashURL?.resolvingSymlinksInPath() else {
            throw Failure(description: "native adapter returned no recoverable Trash receipt")
        }
        try demand(trashed.path.hasPrefix(destination.path + "/"), "Trash receipt escaped isolated Trash directory")
        try demand(!fm.fileExists(atPath: fixture.path), "source remains after trash")
        let actual = try Data(contentsOf: trashed)
        try demand(actual == expected, "trashed bytes differ")
        print("Native trash PASS: recoverable receipt and byte identity")
        let occupied = Data("do not overwrite".utf8)
        try occupied.write(to: fixture)
        var refused = false
        do { try helper.restore(originalURL: fixture, trashURL: trashed) }
        catch { refused = true }
        try demand(refused, "undo overwrote occupied destination")
        let unchanged = try Data(contentsOf: fixture)
        try demand(unchanged == occupied && fm.fileExists(atPath: trashed.path), "failed undo damaged either file")
        try fm.removeItem(at: fixture)
        try helper.restore(originalURL: fixture, trashURL: trashed)
        let restored = try Data(contentsOf: fixture)
        try demand(restored == expected && !fm.fileExists(atPath: trashed.path), "undo did not restore bytes")
        print("Undo PASS: refuses overwrite, then restores original bytes")
    }
}
