import XCTest
@testable import BirdNion

final class BirdNionCLITests: XCTestCase {

    func testCLIModeDetection() {
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "usage", "--json"]))
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "serve"]))
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "config", "import", "x.json"]))
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "providers"]))
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "help"]))
        XCTAssertTrue(BirdNionCLI.wantsCLIMode(["birdnion", "--version"]))
    }

    func testStrayArgumentsDoNotActivateCLIMode() {
        XCTAssertFalse(BirdNionCLI.wantsCLIMode(["birdnion"]))
        XCTAssertFalse(BirdNionCLI.wantsCLIMode(["birdnion", "--json"]))
        XCTAssertFalse(BirdNionCLI.wantsCLIMode(["birdnion", "frobnicate"]))
        // A subcommand anywhere other than argv[1] doesn't count.
        XCTAssertFalse(BirdNionCLI.wantsCLIMode(["birdnion", "--flag", "usage"]))
    }

    func testHelpTextDocumentsEverySubcommand() {
        for keyword in ["usage", "providers", "config import", "serve", "version"] {
            XCTAssertTrue(BirdNionCLI.helpText.contains(keyword),
                          "help text missing \(keyword)")
        }
    }
}
