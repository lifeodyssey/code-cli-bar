import Security
import XCTest
@testable import VibeBarCore

final class KeychainPasswordReadTests: XCTestCase {
    func testServiceOnlyReadResolvesOneReferenceBeforeCopyingPassword() throws {
        let reference = NSObject()
        let password = Data("synthetic-password".utf8)
        var calls = 0

        let actual = try read { query, result in
            calls += 1
            let query = query as NSDictionary
            // macOS rejects this combination even when only one item exists.
            if query[kSecReturnData] as? Bool == true,
               query[kSecMatchLimit] as? String == kSecMatchLimitAll as String {
                return errSecParam
            }
            XCTAssertEqual(query[kSecAttrService] as? String, "test-service")
            if calls == 1 {
                XCTAssertEqual(query[kSecReturnRef] as? Bool, true)
                XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitAll as String)
                XCTAssertNil(query[kSecReturnData])
                result?.pointee = [reference] as NSArray
            } else {
                XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
                XCTAssertEqual(query[kSecReturnData] as? Bool, true)
                XCTAssertNil(query[kSecReturnRef])
                let items = query[kSecMatchItemList] as? [NSObject]
                XCTAssertEqual(items?.count, 1)
                XCTAssertTrue(items?.first === reference)
                result?.pointee = password as NSData
            }
            return errSecSuccess
        }

        XCTAssertEqual(actual, password)
        XCTAssertEqual(calls, 2)
    }

    func testMultipleMatchesAreRejectedBeforeAnyPasswordIsRead() {
        var calls = 0
        XCTAssertThrowsError(try read { query, result in
            calls += 1
            XCTAssertNil((query as NSDictionary)[kSecReturnData])
            result?.pointee = [NSObject(), NSObject()] as NSArray
            return errSecSuccess
        }) { error in
            XCTAssertEqual(error as? KeychainStore.KeychainError, .ambiguousItem(2))
        }
        XCTAssertEqual(calls, 1)
    }

    func testEmptyMatchesAreReportedAsMissing() {
        XCTAssertThrowsError(try read { _, result in
            result?.pointee = [] as NSArray
            return errSecSuccess
        }) { error in
            XCTAssertEqual(error as? KeychainStore.KeychainError, .itemNotFound)
        }
    }

    func testExplicitAccountUsesOneDirectPasswordRead() throws {
        let password = Data("synthetic-account-password".utf8)
        var calls = 0
        let actual = try read(account: "test-account") { query, result in
            calls += 1
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecAttrAccount] as? String, "test-account")
            XCTAssertEqual(query[kSecMatchLimit] as? String, kSecMatchLimitOne as String)
            XCTAssertEqual(query[kSecReturnData] as? Bool, true)
            XCTAssertNil(query[kSecReturnRef])
            XCTAssertNil(query[kSecMatchItemList])
            result?.pointee = password as NSData
            return errSecSuccess
        }
        XCTAssertEqual(actual, password)
        XCTAssertEqual(calls, 1)
    }

    func testReferenceLookupErrorsPreserveKeychainStatus() {
        for (status, expected) in failures {
            XCTAssertThrowsError(try read { _, _ in status }) { error in
                XCTAssertEqual(error as? KeychainStore.KeychainError, expected)
            }
        }
    }

    func testPasswordReadErrorsPreserveKeychainStatus() {
        for (status, expected) in failures {
            var calls = 0
            XCTAssertThrowsError(try read { _, result in
                calls += 1
                if calls == 1 {
                    result?.pointee = [NSObject()] as NSArray
                    return errSecSuccess
                }
                return status
            }) { error in
                XCTAssertEqual(error as? KeychainStore.KeychainError, expected)
            }
            XCTAssertEqual(calls, 2)
        }
    }

    func testDataProtectionAndNoUISettingsApplyToBothQueries() throws {
        var calls = 0
        var noUIQuery: [String: Any] = [:]
        KeychainNoUIQuery.apply(to: &noUIQuery, uiPolicy: .fail)
        _ = try read(useDataProtectionKeychain: true) { query, result in
            calls += 1
            let query = query as NSDictionary
            XCTAssertEqual(query[kSecUseDataProtectionKeychain] as? Bool, true)
            XCTAssertEqual(query[kSecUseAuthenticationUI] as? String, noUIQuery[kSecUseAuthenticationUI as String] as? String)
            XCTAssertNotNil(query[kSecUseAuthenticationContext])
            if calls == 1 {
                result?.pointee = [NSObject()] as NSArray
            } else {
                result?.pointee = Data() as NSData
            }
            return errSecSuccess
        }
        XCTAssertEqual(calls, 2)
    }

    private var failures: [(OSStatus, KeychainStore.KeychainError)] {
        [
            (errSecItemNotFound, .itemNotFound),
            (errSecInteractionNotAllowed, .interactionNotAllowed),
            (errSecAuthFailed, .unhandledStatus(errSecAuthFailed))
        ]
    }

    private func read(
        account: String? = nil,
        useDataProtectionKeychain: Bool = false,
        copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    ) throws -> Data {
        try KeychainStore.readGenericPasswordData(
            service: "test-service",
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            copyMatching: copyMatching
        )
    }
}
