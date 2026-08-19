import Foundation
import Security

#if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
// Security.framework exports these on iOS, but the Swift overlay does not
// expose SecTask declarations. Keep the ABI bridge local and minimal so the
// running code signature—not the source .entitlements file—is authoritative.
@_silgen_name("SecTaskCreateFromSelf")
private func LASIdentityCreateSecurityTask(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("SecTaskCopyValueForEntitlement")
private func LASIdentityCopyEntitlementValue(
    _ task: CFTypeRef,
    _ entitlement: CFString,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> CFTypeRef?
#endif

/// Runtime probe for the code-signature identity iOS is actually running.
///
/// ForgeSign-class sideload signing historically bakes a wildcard (or missing)
/// `application-identifier` into the code signature. The app installs and
/// runs, but identity-scoped system services cannot issue it file-access
/// grants — most visibly the Files document picker, whose items grey out or
/// whose Open button does nothing. AltStore-style per-app profiles carry a
/// concrete identifier and are unaffected. ForgeSign 2.0+ expands wildcard
/// identities at sign time; older signing runs leave them wildcarded.
enum LASAppIdentity {

    /// True when the running signature carries a concrete (non-wildcard,
    /// non-missing) application-identifier. Simulator and Catalyst builds are
    /// not governed by iOS provisioning, so they report true.
    static var hasConcreteApplicationIdentifier: Bool {
        isConcreteApplicationIdentifier(liveApplicationIdentifierValue())
    }

    /// True only when iOS reliably issues open-in-place File Provider grants to
    /// this build — i.e. App Store / TestFlight distribution, which ships no
    /// embedded provisioning profile.
    ///
    /// A concrete `application-identifier` is necessary but NOT sufficient for
    /// open-in-place folder/package picking. Every resign/sideload path
    /// (development, ad-hoc, enterprise, AltStore, ForgeSign) embeds a
    /// `mobileprovision`, and on those builds the File Provider can still deny
    /// the security-scoped grant to content *outside* the sandbox even with a
    /// concrete identity: the picked folder looks selectable but "Open" does
    /// nothing. Folder/package imports must route to the in-sandbox App
    /// Documents flow on those builds; single-file copy imports are unaffected.
    static var openInPlaceFileProviderGrantsAreReliable: Bool {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        // No iOS provisioning sandbox governs these; open-in-place works.
        return true
        #else
        // App Store / TestFlight binaries carry no embedded.mobileprovision.
        return Bundle.main.url(
            forResource: "embedded",
            withExtension: "mobileprovision"
        ) == nil
        #endif
    }

    /// Pure predicate kept separate from the SecTask probe so it is
    /// unit-testable without a device.
    static func isConcreteApplicationIdentifier(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        if value.contains("*") { return false }
        // "TEAMID.com.example.app" — a team/app-id prefix plus a bundle id,
        // both non-empty.
        let parts = value.split(
            separator: ".",
            omittingEmptySubsequences: true
        )
        return parts.count >= 2
    }

    private static func liveApplicationIdentifierValue() -> String? {
        #if os(iOS) && !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        guard let task = LASIdentityCreateSecurityTask(nil) else { return nil }
        guard let raw = LASIdentityCopyEntitlementValue(
            task,
            "application-identifier" as CFString,
            nil
        ) else { return nil }
        return raw as? String
        #else
        // Simulator / Catalyst: no iOS provisioning, document pickers work.
        return "simulator.local"
        #endif
    }
}
