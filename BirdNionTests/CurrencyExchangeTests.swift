import XCTest
@testable import BirdNion

final class CurrencyExchangeTests: XCTestCase {

    private func makeDefaults() throws -> UserDefaults {
        let name = "currency-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testConvertUSDPassthrough() {
        let exchange = CurrencyExchange(defaults: .standard)
        XCTAssertEqual(exchange.convert(usdAmount: 12.5, to: "USD"), 12.5)
    }

    func testConvertUsesOfflineFallbackRates() throws {
        let defaults = try makeDefaults()
        let exchange = CurrencyExchange(defaults: defaults)
        let vnd = try XCTUnwrap(exchange.convert(usdAmount: 1.0, to: "VND"))
        XCTAssertEqual(vnd, 25962.0, accuracy: 0.01)
        let eur = try XCTUnwrap(exchange.convert(usdAmount: 10.0, to: "EUR"))
        XCTAssertEqual(eur, 9.2, accuracy: 0.01)
    }

    func testConvertUnknownCurrencyReturnsNil() throws {
        let exchange = CurrencyExchange(defaults: try makeDefaults())
        XCTAssertNil(exchange.convert(usdAmount: 1.0, to: "XXX"))
    }

    func testCachedRatesOverrideFallback() throws {
        let defaults = try makeDefaults()
        defaults.set(["VND": 25000.0], forKey: "BirdNion.CurrencyExchangeRates")
        let exchange = CurrencyExchange(defaults: defaults)
        let vnd = try XCTUnwrap(exchange.convert(usdAmount: 2.0, to: "VND"))
        XCTAssertEqual(vnd, 50000.0, accuracy: 0.01)
    }

    func testRequiresLiveRates() {
        XCTAssertTrue(CurrencyExchange.requiresLiveRates(preferredCurrencyCode: "VND"))
        XCTAssertFalse(CurrencyExchange.requiresLiveRates(preferredCurrencyCode: "USD"))
        XCTAssertFalse(CurrencyExchange.requiresLiveRates(preferredCurrencyCode: "auto"))
        XCTAssertFalse(CurrencyExchange.requiresLiveRates(preferredCurrencyCode: "XXX"))
    }

    func testResolvedCodeAutoFallsBackToLocaleOrUSD() {
        UserDefaults.standard.set("auto", forKey: PreferredCurrency.defaultsKey)
        let resolved = PreferredCurrency.resolvedCode
        XCTAssertTrue(CurrencyExchange.supportedCurrencies.contains(resolved))

        UserDefaults.standard.set("vnd", forKey: PreferredCurrency.defaultsKey)
        XCTAssertEqual(PreferredCurrency.resolvedCode, "VND")

        UserDefaults.standard.set("XXX", forKey: PreferredCurrency.defaultsKey)
        XCTAssertEqual(PreferredCurrency.resolvedCode, "USD")

        UserDefaults.standard.removeObject(forKey: PreferredCurrency.defaultsKey)
    }

    func testFormatUSDunchangedWhenUSDSelected() {
        UserDefaults.standard.set("USD", forKey: PreferredCurrency.defaultsKey)
        XCTAssertEqual(PreferredCurrency.format(usd: 12.5), "$12.50")
        XCTAssertEqual(PreferredCurrency.format(usd: 1500), "$1,500")
        XCTAssertEqual(PreferredCurrency.format(usd: 12.5, wholeFraction: true), "$12")
        XCTAssertEqual(PreferredCurrency.format(usd: 1500, wholeFraction: true), "$1,500")
        UserDefaults.standard.removeObject(forKey: PreferredCurrency.defaultsKey)
    }

    func testFormatConvertsToVND() {
        UserDefaults.standard.set("VND", forKey: PreferredCurrency.defaultsKey)
        let formatted = PreferredCurrency.format(usd: 1.0)
        // Offline rate 25,962 → rendered with the VND grouping, no cents.
        XCTAssertTrue(formatted.contains("25") || formatted.contains("₫"),
                      "expected VND-formatted output, got \(formatted)")
        XCTAssertFalse(formatted.contains("$"))
        UserDefaults.standard.removeObject(forKey: PreferredCurrency.defaultsKey)
    }
}
