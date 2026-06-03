import XCTest
@testable import PetCore

final class RefValidatorTests: XCTestCase {
    func testValidBranchesPass() {
        XCTAssertTrue(RefValidator.isValidBranch("main"))
        XCTAssertTrue(RefValidator.isValidBranch("feature/v0.1-implementation"))
        XCTAssertTrue(RefValidator.isValidBranch("claudegotchi/fix/128"))
    }

    func testBranchRejectsLeadingDash() {
        XCTAssertFalse(RefValidator.isValidBranch("-h"))
        XCTAssertFalse(RefValidator.isValidBranch("--upload-pack=evil"))
    }

    func testBranchRejectsDotDotWhitespaceAndMetachars() {
        XCTAssertFalse(RefValidator.isValidBranch("a..b"))
        XCTAssertFalse(RefValidator.isValidBranch("a b"))
        XCTAssertFalse(RefValidator.isValidBranch("a\tb"))
        XCTAssertFalse(RefValidator.isValidBranch("a~1"))
        XCTAssertFalse(RefValidator.isValidBranch("a:b"))
        XCTAssertFalse(RefValidator.isValidBranch("a?b"))
        XCTAssertFalse(RefValidator.isValidBranch(""))
    }

    func testValidSlugsPass() {
        XCTAssertTrue(RefValidator.isValidSlug("owner/name"))
        XCTAssertTrue(RefValidator.isValidSlug("my-org.x/repo_1.swift"))
    }

    func testSlugRejectsLeadingDashEitherSegment() {
        XCTAssertFalse(RefValidator.isValidSlug("-h/repo"))
        XCTAssertFalse(RefValidator.isValidSlug("a/-rf"))
        XCTAssertFalse(RefValidator.isValidSlug("a/b/c"))
        XCTAssertFalse(RefValidator.isValidSlug("nooses"))
        XCTAssertFalse(RefValidator.isValidSlug("a/b c"))
    }

    func testValidLoginsPass() {
        XCTAssertTrue(RefValidator.isValidLogin("jalen"))
        XCTAssertTrue(RefValidator.isValidLogin("octo-cat"))
    }

    func testLoginRejectsLeadingDashAndBadChars() {
        XCTAssertFalse(RefValidator.isValidLogin("-state"))
        XCTAssertFalse(RefValidator.isValidLogin("a/b"))
        XCTAssertFalse(RefValidator.isValidLogin("a b"))
        XCTAssertFalse(RefValidator.isValidLogin(""))
    }
}
