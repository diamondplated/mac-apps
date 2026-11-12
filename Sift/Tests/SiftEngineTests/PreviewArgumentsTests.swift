import TestSupport
import Testing

@testable import SiftVerify

// `sift --preview` is argument plumbing only; the preview itself is tested in SiftPreviewTests.

@Test(.engineLifetime) func previewTakesOneFileAnOutputAndAnAppearance() {
    #expect(
        parseArguments(["--preview", "a.parquet", "--out", "p.html", "--appearance", "dark"])
            == .preview(path: "a.parquet", output: "p.html", appearance: "dark"))
    #expect(
        parseArguments(["--preview", "a.csv"])
            == .preview(path: "a.csv", output: "preview.html", appearance: "system"))
}

@Test(.engineLifetime) func previewRefusesWhatItCannotUse() {
    for args in [
        ["--preview"], ["--preview", "a", "b"], ["--preview", "a", "--out"],
        ["--preview", "a", "--appearance", "sepia"], ["--preview", "a", "--rows", "3"],
    ] {
        guard case .usageError = parseArguments(args) else {
            Issue.record("\(args) was accepted")
            continue
        }
    }
}
