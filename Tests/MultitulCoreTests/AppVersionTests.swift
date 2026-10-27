import Testing
import Foundation
@testable import MultitulCore

private func v(_ s: String) -> AppVersion { AppVersion(s) }
private func lt(_ a: String, _ b: String) -> Bool { AppVersion.compare(v(a), v(b)) < 0 }
private func eq(_ a: String, _ b: String) -> Bool { AppVersion.compare(v(a), v(b)) == 0 }

@Suite struct AppVersionTests {
    @Test func plainSemverOrdering() {
        #expect(lt("1.2.3", "1.2.4") && lt("1.2.9", "1.3.0") && lt("1.9.9", "2.0.0"))
        #expect(!lt("2.0.0", "1.9.9") && !lt("1.2.3", "1.2.3"))
    }

    @Test func numbersAreNotComparedAsText() {
        #expect(lt("1.9", "1.10") && lt("1.2.9", "1.2.10") && lt("9", "10") && lt("2.0", "10.0"))
    }

    @Test func missingTrailingZerosAreEqual() {
        #expect(eq("1.0", "1.0.0") && eq("2", "2.0.0.0") && lt("1.0", "1.0.1"))
        #expect(v("1.0") == v("1.0.0") && v("1.0").hashValue == v("1.0.0").hashValue)
    }

    @Test func sparkleStylePreReleases() {
        #expect(lt("1.2.3b4", "1.2.3b10"))
        #expect(lt("1.2.3b10", "1.2.3rc1"))
        #expect(lt("1.2.3rc1", "1.2.3"))
        #expect(lt("1.2.3", "1.2.3.1"))
        #expect(lt("1.2.2", "1.2.3b1"))
        #expect(lt("1.0a", "1.0b") && lt("1.0b", "1.0"))
    }

    @Test func spelledOutPreReleaseWords() {
        #expect(lt("2.0 alpha 3", "2.0 beta 1") && lt("2.0 beta 1", "2.0 rc 1") && lt("2.0 rc 1", "2.0"))
        #expect(lt("2.0-dev", "2.0-alpha") && lt("2.0-preview", "2.0-rc") && lt("2.0 beta", "2.0 preview"))
    }

    @Test func semverPrereleaseIdentifiers() {
        #expect(lt("1.0.0-alpha", "1.0.0-beta.2"))
        #expect(lt("1.0.0-beta.2", "1.0.0-beta.11"))
        #expect(lt("1.0.0-beta.11", "1.0.0-rc.1"))
        #expect(lt("1.0.0-rc.1", "1.0.0"))
    }

    @Test func buildNumbers() {
        #expect(lt("12345", "12346") && lt("99", "100") && lt("1.2.3.4567", "1.2.3.4568") && lt("1.2.3.999", "1.2.4.1"))
    }

    @Test func hugeNumbersDoNotOverflow() {
        #expect(lt("99999999999999999999", "100000000000000000000"))
        #expect(eq("00000000000000000001", "1"))
    }

    @Test func leadingZerosAndPrefixes() {
        #expect(eq("1.02", "1.2") && eq("v1.2.0", "1.2") && eq("V3", "3") && eq("1.0-final", "1.0") && eq("1.0 release", "1.0"))
    }

    @Test func buildMetadataIsIgnoredLikeInSemver() {
        #expect(eq("1.2.3+45", "1.2.3") && eq("1.2.3+abc", "1.2.3+xyz"))
    }

    @Test func patchWordsAreNewerThanTheRelease() {
        #expect(lt("1.0", "1.0p1") && lt("1.0p1", "1.0p2") && lt("1.0", "1.0 hotfix 1"))
    }

    @Test func dateStyleVersions() {
        #expect(lt("2024.9.30", "2024.10.1") && lt("2024.10.1", "2025.1"))
    }

    @Test func unknownWordsCountAsPreReleases() {
        #expect(lt("2.0-foo", "2.0") && AppVersion("2.0-foo").isPreRelease)
    }

    @Test func preReleaseDetection() {
        #expect(AppVersion("1.0b2").isPreRelease && AppVersion("1.0-rc.1").isPreRelease && AppVersion("1.0 alpha").isPreRelease)
        #expect(!AppVersion("1.0").isPreRelease && !AppVersion("1.0.2").isPreRelease && !AppVersion("1.0p1").isPreRelease)
    }

    @Test func isNewerGuardsAgainstEmptyInput() {
        #expect(AppVersion.isNewer("1.1", than: "1.0") && !AppVersion.isNewer("1.0", than: "1.1") && !AppVersion.isNewer("1.0", than: "1.0.0"))
        #expect(!AppVersion.isNewer("", than: "1.0") && !AppVersion.isNewer("1.0", than: "") && !AppVersion.isNewer("???", than: "1.0"))
    }

    @Test func oddVersionStringsDoNotCrash() {
        for s in ["10.15.7 (19H1217)", "", "   ", "abc", "1..2", "1.2.3.", "-1", "١٢٣", "1_2_3", "🙂1"] { _ = v(s).description; _ = AppVersion.compare(v(s), v("1")) }
        #expect(v("").isEmpty && !v("1").isEmpty)
    }

    @Test func sortingAList() {
        let sorted = ["1.10", "1.2", "1.2b1", "1.2.1", "1.9", "1.2rc1"].map(AppVersion.init).sorted().map(\.raw)
        #expect(sorted == ["1.2b1", "1.2rc1", "1.2", "1.2.1", "1.9", "1.10"])
    }

    @Test func marketingAndBuildComparedSeparately() {
        #expect(AppVersion.isNewer("7.0.1", than: "7.0") && AppVersion.isNewer("501", than: "499"))
    }
}
