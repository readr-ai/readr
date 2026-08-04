import XCTest
@testable import ReadrKit

/// Settings groups connection methods by the company behind them.
///
/// "ChatGPT (subscription)" and "OpenAI (API key)" sat on the screen as two
/// sibling cards, which reads as two services rather than two doors into the
/// same account (user-reported). These pin the grouping, and — more
/// importantly — that hiding a method never leaves a card advertising a way in
/// that this build does not offer.
final class ProviderVendorTests: XCTestCase {

    // MARK: - Method facts

    func testOnlyChatGPTAndLocalSkipTheAPIKeyField() {
        XCTAssertFalse(ProviderInfo.Kind.chatGPT.usesAPIKey)
        XCTAssertFalse(ProviderInfo.Kind.local.usesAPIKey)
        XCTAssertTrue(ProviderInfo.Kind.openAI.usesAPIKey)
        XCTAssertTrue(ProviderInfo.Kind.anthropic.usesAPIKey)
        XCTAssertTrue(ProviderInfo.Kind.openRouter.usesAPIKey)
    }

    /// Anthropic sign-in is intentionally unwired (Consumer Terms — see
    /// docs/AUTH.md), so a Claude card must never grow a sign-in button.
    func testOnlyChatGPTAndOpenRouterOfferSignIn() {
        XCTAssertTrue(ProviderInfo.Kind.chatGPT.offersSignIn)
        XCTAssertTrue(ProviderInfo.Kind.openRouter.offersSignIn)
        XCTAssertFalse(ProviderInfo.Kind.anthropic.offersSignIn)
        XCTAssertFalse(ProviderInfo.Kind.openAI.offersSignIn)
        XCTAssertFalse(ProviderInfo.Kind.local.offersSignIn)
    }

    // MARK: - Grouping

    func testChatGPTAndOpenAIShareOneVendor() {
        XCTAssertEqual(ProviderVendor.vendor(for: .chatGPT)?.id, "openai")
        XCTAssertEqual(ProviderVendor.vendor(for: .openAI)?.id, "openai")
        XCTAssertEqual(
            ProviderVendor.vendor(for: .chatGPT)?.methods, [.chatGPT, .openAI]
        )
    }

    func testEveryKindBelongsToExactlyOneVendor() {
        let kinds: [ProviderInfo.Kind] = [.chatGPT, .openAI, .anthropic, .openRouter, .local]
        for kind in kinds {
            let owners = ProviderVendor.all.filter { $0.methods.contains(kind) }
            XCTAssertEqual(owners.count, 1, "\(kind) should belong to exactly one vendor")
        }
    }

    func testVendorsCoverEveryKindAndRepeatNone() {
        let listed = ProviderVendor.all.flatMap(\.methods)
        XCTAssertEqual(Set(listed).count, listed.count, "a kind is listed twice")
        XCTAssertEqual(
            Set(listed),
            Set([.chatGPT, .openAI, .anthropic, .openRouter, .local] as [ProviderInfo.Kind])
        )
    }

    /// Sign-in vendors lead: a first run should meet the lowest-friction path
    /// before the paste-a-key ones.
    func testSignInVendorsComeFirst() {
        XCTAssertEqual(ProviderVendor.all.map(\.id), ["openai", "openrouter", "anthropic", "local"])
    }

    // MARK: - Badges

    func testBadgeNamesTheMethodsOnOffer() {
        XCTAssertEqual(ProviderVendor.vendor(for: .chatGPT)?.badge, "Sign in or key")
        XCTAssertEqual(ProviderVendor.vendor(for: .openRouter)?.badge, "Sign in or key")
        XCTAssertEqual(ProviderVendor.vendor(for: .anthropic)?.badge, "API key")
        XCTAssertEqual(ProviderVendor.vendor(for: .local)?.badge, "Local")
    }

    /// The badge follows the methods actually displayed. With the ChatGPT
    /// subscription gated off (iOS), the OpenAI card must stop calling itself
    /// a sign-in card.
    func testBadgeDropsSignInWhenThatMethodIsHidden() {
        let vendors = ProviderVendor.displayed(forKinds: [.openAI, .anthropic, .openRouter])
        let openAI = vendors.first { $0.id == "openai" }
        XCTAssertEqual(openAI?.badge, "API key")
    }

    // MARK: - Display filtering

    /// The iOS build hides the ChatGPT subscription and the local model.
    func testIOSSetKeepsOpenAIAsAKeyOnlyCardAndDropsLocal() {
        let vendors = ProviderVendor.displayed(
            forKinds: [.openRouter, .anthropic, .openAI]
        )
        XCTAssertEqual(vendors.map(\.id), ["openai", "openrouter", "anthropic"])
        XCTAssertEqual(vendors.first?.methods, [.openAI])
        XCTAssertFalse(vendors.first?.hasMultipleMethods ?? true)
    }

    func testMacOSSetKeepsEveryVendorAndBothOpenAIMethods() {
        let vendors = ProviderVendor.displayed(
            forKinds: [.chatGPT, .openRouter, .anthropic, .openAI, .local]
        )
        XCTAssertEqual(vendors.map(\.id), ["openai", "openrouter", "anthropic", "local"])
        XCTAssertEqual(vendors.first?.methods, [.chatGPT, .openAI])
        XCTAssertTrue(vendors.first?.hasMultipleMethods ?? false)
    }

    /// A vendor with nothing left to offer disappears rather than rendering an
    /// empty card.
    func testVendorWithEveryMethodHiddenDropsOut() {
        let vendors = ProviderVendor.displayed(forKinds: [.anthropic])
        XCTAssertEqual(vendors.map(\.id), ["anthropic"])
    }

    func testNoDisplayedKindsProducesNoVendors() {
        XCTAssertTrue(ProviderVendor.displayed(forKinds: []).isEmpty)
    }

    /// Display order comes from `all`, not from the caller's argument order —
    /// otherwise the screen would reshuffle with the platform filter.
    func testDisplayOrderIsIndependentOfTheArgumentOrder() {
        let vendors = ProviderVendor.displayed(
            forKinds: [.local, .anthropic, .openAI, .openRouter, .chatGPT]
        )
        XCTAssertEqual(vendors.map(\.id), ["openai", "openrouter", "anthropic", "local"])
    }

    /// Methods keep their canonical order too: the subscription is offered
    /// before the key it is meant to save the reader from needing.
    func testMethodOrderIsCanonical() {
        let vendors = ProviderVendor.displayed(forKinds: [.openAI, .chatGPT])
        XCTAssertEqual(vendors.first?.methods, [.chatGPT, .openAI])
    }
}
