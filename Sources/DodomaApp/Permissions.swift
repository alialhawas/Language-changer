import ApplicationServices
import Foundation
import IOKit.hid

struct PermissionState: Equatable {
    var accessibility: Bool
    var inputMonitoring: Bool

    var isReady: Bool { accessibility && inputMonitoring }
}

enum Permissions {
    static func current() -> PermissionState {
        PermissionState(
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }
}
