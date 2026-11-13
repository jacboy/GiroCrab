import XCTest
@testable import GiroCrabUI

@MainActor
final class KeychainBypassTests: XCTestCase {
    private let names = ["GIROCRAB_NO_KEYCHAIN", "GIROCRAB_DEMO_SEED"]

    override func setUp() {
        super.setUp()
        for n in names { unsetenv(n) }
        UserDefaults.standard.removeObject(forKey: VaultKeyManager.requireBiometricsDefaultsKey)
    }

    override func tearDown() {
        for n in names { unsetenv(n) }
        UserDefaults.standard.removeObject(forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        super.tearDown()
    }

    func testBypassOffByDefault() {
        XCTAssertFalse(VaultKeyManager.keychainBypassed)
        XCTAssertEqual(AppModel.vaultURL.lastPathComponent, "tresor.girocrab")
    }

    func testBypassViaEnvironmentUsesSeparateVaultFile() {
        setenv("GIROCRAB_NO_KEYCHAIN", "1", 1)
        XCTAssertTrue(VaultKeyManager.keychainBypassed)
        XCTAssertEqual(AppModel.vaultURL.lastPathComponent, "tresor-dev.girocrab")
        unsetenv("GIROCRAB_NO_KEYCHAIN")
        setenv("GIROCRAB_DEMO_SEED", "true", 1)
        XCTAssertTrue(VaultKeyManager.keychainBypassed)
        setenv("GIROCRAB_DEMO_SEED", "0", 1)
        XCTAssertFalse(VaultKeyManager.keychainBypassed)
    }

    func testBypassStillPromptsBiometricsExceptDemoSeedOrOptOut() {
        setenv("GIROCRAB_NO_KEYCHAIN", "1", 1)
        #if os(macOS)
        XCTAssertTrue(VaultKeyManager.biometricsPromptInBypass)
        UserDefaults.standard.set(false, forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        XCTAssertFalse(VaultKeyManager.biometricsPromptInBypass)
        UserDefaults.standard.set(true, forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        #endif
        setenv("GIROCRAB_DEMO_SEED", "1", 1)
        XCTAssertFalse(VaultKeyManager.biometricsPromptInBypass)
    }

    func testBypassSetRequireBiometricsOnlyChangesPreference() async throws {
        setenv("GIROCRAB_NO_KEYCHAIN", "1", 1)
        try await VaultKeyManager.shared.setRequireBiometrics(false)
        XCTAssertEqual(UserDefaults.standard.object(forKey: VaultKeyManager.requireBiometricsDefaultsKey) as? Bool, false)
    }

    func testBypassUnlockReturnsThrowAwayKeyWithoutKeychain() async throws {
        // Demo seed: no Touch ID prompt, so this is testable headless.
        setenv("GIROCRAB_DEMO_SEED", "1", 1)
        let key = try await VaultKeyManager.shared.unlock()
        XCTAssertEqual(key, Data(repeating: 0x42, count: 32))
        XCTAssertFalse(VaultKeyManager.shared.lastUnlockCreatedKey)
    }

    #if os(macOS)
    func testRequireBiometricsDefaultsToTrueAndFollowsPreference() {
        XCTAssertTrue(VaultKeyManager.shared.requireBiometrics)
        UserDefaults.standard.set(false, forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        XCTAssertFalse(VaultKeyManager.shared.requireBiometrics)
        UserDefaults.standard.set(true, forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        XCTAssertTrue(VaultKeyManager.shared.requireBiometrics)
    }
    #else
    func testRequireBiometricsIsAlwaysTrueOnIOS() {
        UserDefaults.standard.set(false, forKey: VaultKeyManager.requireBiometricsDefaultsKey)
        XCTAssertTrue(VaultKeyManager.shared.requireBiometrics)
    }
    #endif
}
