import ServiceManagement
import XCTest

@testable import DodomaAppKit

/// Whether the first-run window opens itself, as a truth table.
final class OnboardingDecisionTests: XCTestCase {
    private func state(_ accessibility: Bool, _ inputMonitoring: Bool) -> PermissionState {
        PermissionState(accessibility: accessibility, inputMonitoring: inputMonitoring)
    }

    func testAFreshInstallWithNeitherGrantIsOnboarded() {
        XCTAssertTrue(Onboarding.isNeeded(permissions: state(false, false), hasCompleted: false))
    }

    func testEitherGrantMissingIsEnough() {
        XCTAssertTrue(Onboarding.isNeeded(permissions: state(true, false), hasCompleted: false))
        XCTAssertTrue(Onboarding.isNeeded(permissions: state(false, true), hasCompleted: false))
    }

    /// The whole reason the permission test is there: an accessory app that
    /// opens a window at every login is worse than no window at all.
    func testAFullyGrantedInstallIsNeverOnboarded() {
        XCTAssertFalse(Onboarding.isNeeded(permissions: state(true, true), hasCompleted: false))
    }

    /// And the whole reason the flag is there: revoking a grant later must not
    /// reopen the window unbidden.
    func testHavingFinishedOnceSuppressesItInEveryPermissionState() {
        for accessibility in [true, false] {
            for inputMonitoring in [true, false] {
                XCTAssertFalse(
                    Onboarding.isNeeded(
                        permissions: state(accessibility, inputMonitoring), hasCompleted: true),
                    "\(accessibility)/\(inputMonitoring)")
            }
        }
    }
}

/// `SMAppService.Status` flattened into what the two windows show.
final class LoginItemStatusTests: XCTestCase {
    func testEveryServiceStatusMapsToSomethingTheUICanShow() {
        XCTAssertEqual(LoginItem.map(.enabled), .enabled)
        XCTAssertEqual(LoginItem.map(.notRegistered), .disabled)
        XCTAssertEqual(LoginItem.map(.requiresApproval), .requiresApproval)
        XCTAssertEqual(LoginItem.map(.notFound), .notFound)
    }

    /// `.requiresApproval` means the registration exists and macOS is holding
    /// it back. Showing the switch as off would invite the user to register
    /// again, which changes nothing.
    func testTheToggleReadsOnWhileApprovalIsPending() {
        XCTAssertTrue(LoginItemStatus.enabled.isOn)
        XCTAssertTrue(LoginItemStatus.requiresApproval.isOn)
        XCTAssertFalse(LoginItemStatus.disabled.isOn)
        XCTAssertFalse(LoginItemStatus.notFound.isOn)
        XCTAssertFalse(LoginItemStatus.unavailable.isOn)
    }

    /// Every state the user cannot resolve by clicking the toggle has to say
    /// what to do instead.
    func testTheUnresolvableStatesExplainThemselves() {
        XCTAssertFalse(LoginItemStatus.requiresApproval.explanation.isEmpty)
        XCTAssertFalse(LoginItemStatus.notFound.explanation.isEmpty)
        XCTAssertFalse(LoginItemStatus.unavailable.explanation.isEmpty)
        XCTAssertTrue(LoginItemStatus.enabled.explanation.isEmpty)
        XCTAssertTrue(LoginItemStatus.disabled.explanation.isEmpty)
    }
}
