import Foundation

#if os(macOS)
import Darwin
import LocalAuthentication
import Security

/// Marks a SecItem query as never allowed to surface authentication UI —
/// port of CodexBarCore's KeychainNoUIQuery. Background credential reads use
/// this so a Keychain ACL that would prompt fails fast
/// (`errSecInteractionNotAllowed`) instead of blocking the fetch on a dialog
/// the user may never see.
enum KeychainNoUIQuery {
    private static let uiFailPolicy = KeychainNoUIQuery.resolveUIFailPolicy()

    static func apply(to query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        // Keep explicit UI-fail policy for legacy keychain behavior on macOS
        // where `interactionNotAllowed` alone can still surface Allow/Deny
        // prompts.
        query[kSecUseAuthenticationUI as String] = self.uiFailPolicy as CFString
    }

    private static func resolveUIFailPolicy() -> String {
        // Resolve the Security symbol at runtime to preserve the true constant
        // value without directly referencing deprecated API at compile time.
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else {
            return "u_AuthUIF"
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}

/// Decides, without ever requesting the secret, whether reading a generic
/// password would raise the legacy Keychain ACL dialog for this process —
/// port of CodexBarCore's KeychainAccessPreflight. The `KeychainNoUIQuery`
/// flags do not stop that dialog for login-keychain items on macOS 27, so a
/// silent read must only fetch data after this returns `.allowed`.
enum KeychainAccessPreflight {
    enum Outcome: Equatable {
        case allowed
        /// The item exists but its decrypt ACL does not trust this executable.
        case interactionRequired
        /// Inspection could not complete (locked keychain, unreadable ACL).
        case unavailable
        case notFound
    }

    enum DecryptACLEvaluation: Equatable {
        case allowed
        case rejected
        case indeterminate
    }

    static func checkGenericPassword(service: String,
                                     account: String?,
                                     searchList: [SecKeychain]? = nil) -> Outcome {
        // Even an attributes-only search raises the unlock dialog on a locked
        // keychain, so bail out before searching.
        guard isUnlocked(searchList) else { return .unavailable }
        // Attributes + item reference only: asking for the payload is what
        // raises the dialog, while the reference lets the ACL be inspected.
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnRef as String: true,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        if let searchList { query[kSecMatchSearchList as String] = searchList }
        KeychainNoUIQuery.apply(to: &query)
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess:
            guard let attributes = result as? [String: Any],
                  let value = attributes[kSecValueRef as String],
                  let itemTypeID = securityFunction(
                      named: "SecKeychainItemGetTypeID", as: SecKeychainItemGetTypeIDFunction.self),
                  CFGetTypeID(value as CFTypeRef) == itemTypeID()
            else { return .unavailable }
            let item = unsafeDowncast(value as AnyObject, to: SecKeychainItem.self)
            switch evaluateDecryptACL(item: item) {
            case .allowed: return .allowed
            case .rejected: return .interactionRequired
            case .indeterminate: return .unavailable
            }
        case errSecItemNotFound:
            return .notFound
        default:
            return .unavailable
        }
    }

    /// True only when every keychain to be searched reports unlocked; nil
    /// means the default (login) keychain. Unknown status counts as locked.
    private static func isUnlocked(_ searchList: [SecKeychain]?) -> Bool {
        guard let getStatus = securityFunction(
                  named: "SecKeychainGetStatus", as: SecKeychainGetStatusFunction.self)
        else { return false }
        let unlockedFlag: UInt32 = 1   // kSecUnlockStateStatus
        let keychains: [SecKeychain?] = searchList.map { $0.map(Optional.some) } ?? [nil]
        return keychains.allSatisfy { keychain in
            var status: UInt32 = 0
            return getStatus(keychain, &status) == errSecSuccess && status & unlockedFlag != 0
        }
    }

    /// Pure rule for one decrypt ACL entry. A non-zero prompt selector can ask
    /// for authentication whatever the caller is, so it never counts as
    /// allowed. A nil application list trusts every caller; otherwise one
    /// stored code requirement must validate against this executable — a path
    /// match alone is not enough, since an ACL can keep an older build's
    /// signature at the same path and still prompt.
    static func evaluateDecryptACL(trustedApplicationValidationStatuses: [OSStatus?]?,
                                   promptSelector: SecKeychainPromptSelector) -> DecryptACLEvaluation {
        guard promptSelector.rawValue == 0 else { return .rejected }
        guard let statuses = trustedApplicationValidationStatuses else { return .allowed }
        if statuses.contains(errSecSuccess) { return .allowed }
        // A completed signature mismatch reports CSSMERR_CSP_VERIFY_FAILED;
        // anything else (missing symbol, other error) proves nothing.
        return statuses.allSatisfy { $0 == OSStatus(CSSMERR_CSP_VERIFY_FAILED) } ? .rejected : .indeterminate
    }

    private static func evaluateDecryptACL(item: SecKeychainItem) -> DecryptACLEvaluation {
        guard let copyItemAccess = securityFunction(
                  named: "SecKeychainItemCopyAccess", as: SecKeychainItemCopyAccessFunction.self),
              let copyMatchingACLs = securityFunction(
                  named: "SecAccessCopyMatchingACLList", as: SecAccessCopyMatchingACLListFunction.self),
              let copyACLContents = securityFunction(
                  named: "SecACLCopyContents", as: SecACLCopyContentsFunction.self),
              let executablePath = Bundle.main.executablePath
        else { return .indeterminate }

        var access: SecAccess?
        guard copyItemAccess(item, &access) == errSecSuccess,
              let access,
              let rawACLs = copyMatchingACLs(access, kSecACLAuthorizationDecrypt)?.takeRetainedValue(),
              let acls = rawACLs as? [SecACL],
              !acls.isEmpty
        else { return .indeterminate }

        var inspectionIncomplete = false
        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var selector = SecKeychainPromptSelector()
            guard copyACLContents(acl, &applications, &description, &selector) == errSecSuccess else {
                inspectionIncomplete = true
                continue
            }
            let statuses: [OSStatus?]?
            if let applications {
                guard let trusted = applications as? [SecTrustedApplication] else {
                    inspectionIncomplete = true
                    continue
                }
                statuses = trusted.map { validate($0, executablePath: executablePath) }
            } else {
                statuses = nil
            }
            switch evaluateDecryptACL(trustedApplicationValidationStatuses: statuses, promptSelector: selector) {
            case .allowed: return .allowed
            case .indeterminate: inspectionIncomplete = true
            case .rejected: break
            }
        }
        return inspectionIncomplete ? .indeterminate : .rejected
    }

    /// Checks one trusted application against the running code: its stored
    /// requirement against this process's dynamic signature when available,
    /// otherwise Security's static path validation.
    private static func validate(_ application: SecTrustedApplication, executablePath: String) -> OSStatus? {
        if let copyRequirement = securityFunction(
               named: "SecTrustedApplicationCopyRequirement",
               as: SecTrustedApplicationCopyRequirementFunction.self) {
            var requirement: Unmanaged<SecRequirement>?
            if copyRequirement(application, &requirement) == errSecSuccess,
               let requirement = requirement?.takeRetainedValue() {
                var code: SecCode?
                guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
                let status = SecCodeCheckValidity(code, [], requirement)
                return status == errSecCSReqFailed ? OSStatus(CSSMERR_CSP_VERIFY_FAILED) : status
            }
        }
        guard let validateWithPath = securityFunction(
                  named: "SecTrustedApplicationValidateWithPath",
                  as: SecTrustedApplicationValidateWithPathFunction.self)
        else { return nil }
        return executablePath.withCString { validateWithPath(application, $0) }
    }

    private typealias SecKeychainItemGetTypeIDFunction = @convention(c) () -> CFTypeID
    private typealias SecKeychainGetStatusFunction = @convention(c) (
        SecKeychain?, UnsafeMutablePointer<UInt32>) -> OSStatus
    private typealias SecKeychainItemCopyAccessFunction = @convention(c) (
        SecKeychainItem, UnsafeMutablePointer<SecAccess?>) -> OSStatus
    private typealias SecAccessCopyMatchingACLListFunction = @convention(c) (
        SecAccess, CFTypeRef) -> Unmanaged<CFArray>?
    private typealias SecACLCopyContentsFunction = @convention(c) (
        SecACL,
        UnsafeMutablePointer<CFArray?>,
        UnsafeMutablePointer<CFString?>,
        UnsafeMutablePointer<SecKeychainPromptSelector>) -> OSStatus
    private typealias SecTrustedApplicationValidateWithPathFunction = @convention(c) (
        SecTrustedApplication, UnsafePointer<CChar>) -> OSStatus
    private typealias SecTrustedApplicationCopyRequirementFunction = @convention(c) (
        SecTrustedApplication, UnsafeMutablePointer<Unmanaged<SecRequirement>?>) -> OSStatus

    private static let securityFrameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/Frameworks/Security.framework/Security", RTLD_NOW)

    // Resolved at runtime so the deprecated ACL API needs no compile-time reference.
    private static func securityFunction<T>(named name: String, as _: T.Type) -> T? {
        guard let securityFrameworkHandle, let symbol = dlsym(securityFrameworkHandle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
#endif
