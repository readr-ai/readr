import Foundation

public extension ProviderInfo.Kind {
    /// Whether this connection method takes a pasted API key.
    ///
    /// ChatGPT is subscription-only — its backend can't be driven by an API
    /// key — and the local model needs no credential at all.
    var usesAPIKey: Bool {
        self != .chatGPT && self != .local
    }

    /// Whether this method offers a browser sign-in. Delegates to the single
    /// source of truth shared with the token refresher.
    var offersSignIn: Bool {
        OAuthProviderConfig.config(for: self) != nil
    }
}

/// A company whose models Readr can talk to, and the ways to connect to it.
///
/// A `ProviderInfo.Kind` is a connection METHOD, not a company: `.chatGPT`
/// (subscription sign-in) and `.openAI` (API key) are the same company and,
/// for most readers, the same account. Listing them as two sibling cards —
/// "ChatGPT (subscription)" and "OpenAI (API key)" — asked the reader to
/// already know that, and made the settings screen look like it supported
/// twice as many services as it does (user-reported). Settings groups by
/// vendor and offers the methods inside one card.
///
/// The kinds themselves stay separate everywhere else: they have different
/// credentials, catalogs and endpoints, and each is independently connected,
/// validated and activated. This type is about presentation only.
public struct ProviderVendor: Identifiable, Sendable, Hashable {
    /// Stable slug, used for view identity and accessibility ids.
    public let id: String
    public let title: String
    /// Connection methods, in the order they should be offered.
    public let methods: [ProviderInfo.Kind]

    public init(id: String, title: String, methods: [ProviderInfo.Kind]) {
        self.id = id
        self.title = title
        self.methods = methods
    }

    /// Short pill naming how this vendor connects, derived from the methods
    /// actually on offer rather than hardcoded — so a build that hides one
    /// method never advertises it.
    public var badge: String {
        if methods == [.local] { return "Local" }
        let signIn = methods.contains(where: \.offersSignIn)
        let key = methods.contains(where: \.usesAPIKey)
        switch (signIn, key) {
        case (true, true): return "Sign in or key"
        case (true, false): return "Subscription"
        case (false, true): return "API key"
        case (false, false): return "On-device"
        }
    }

    /// True when this vendor offers more than one way in, and the card
    /// therefore has to label which is which.
    public var hasMultipleMethods: Bool { methods.count > 1 }
}

public extension ProviderVendor {

    /// Every vendor, in display order: the ones offering a sign-in lead
    /// (lowest-friction first run), then the key-only cloud vendors, then the
    /// local model.
    static let all: [ProviderVendor] = [
        ProviderVendor(id: "openai", title: "OpenAI", methods: [.chatGPT, .openAI]),
        ProviderVendor(id: "openrouter", title: "OpenRouter", methods: [.openRouter]),
        ProviderVendor(id: "anthropic", title: "Claude (Anthropic)", methods: [.anthropic]),
        ProviderVendor(id: "local", title: "Local model (on-device)", methods: [.local]),
    ]

    /// The vendor a connection method belongs to, or nil if it is in no
    /// vendor (which would be a bug — every kind should be reachable).
    static func vendor(for kind: ProviderInfo.Kind) -> ProviderVendor? {
        all.first { $0.methods.contains(kind) }
    }

    /// The vendors to render given the kinds this build exposes, each carrying
    /// only its displayed methods, in `all` order.
    ///
    /// A vendor whose every method is hidden drops out entirely — that is how
    /// the iOS build loses the local row, and how it would lose OpenAI
    /// altogether if the key path were ever gated too. A vendor that keeps
    /// only some of its methods simply offers fewer ways in: on iOS the
    /// ChatGPT subscription is gated off (docs/AUTH.md ToS caveat) and OpenAI
    /// shows as an API-key card.
    static func displayed(forKinds displayedKinds: [ProviderInfo.Kind]) -> [ProviderVendor] {
        let allowed = Set(displayedKinds)
        return all.compactMap { vendor in
            let methods = vendor.methods.filter(allowed.contains)
            guard !methods.isEmpty else { return nil }
            return ProviderVendor(id: vendor.id, title: vendor.title, methods: methods)
        }
    }
}
