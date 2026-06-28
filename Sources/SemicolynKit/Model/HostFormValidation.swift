// SPDX-FileCopyrightText: 2026 True Positive LLC
// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Severity of a host-form validation issue.
public enum ValidationSeverity: Equatable, Sendable {
    /// Hard block: the Save action must be disabled.
    case hardBlock
    /// Soft block: a warning shown to the user, but Save is still allowed.
    case softBlock
}

/// A single validation issue surfaced by `validateHostForm`.
public struct ValidationIssue: Equatable, Sendable {
    /// The specific type of validation failure.
    public enum Kind: Equatable, Sendable {
        // Hard blocks
        case missingLabel
        case missingHostName
        case jumpChainCycle
        case inlineJumpHostMissingHostName(index: Int)
        case localForwardMissingField(index: Int)
        case remoteForwardMissingField(index: Int)
        case dynamicForwardMissingField(index: Int)
        case stalePasswordRef
        // Soft blocks
        case duplicateLabel(existing: [HostRef])
        case noUserSet
    }

    public let kind: Kind
    public let severity: ValidationSeverity

    public init(kind: Kind, severity: ValidationSeverity) {
        self.kind = kind
        self.severity = severity
    }
}

/// Returns every validation issue for a host being edited.
///
/// Pure function: given the draft `host`, the other saved hosts, the `Defaults`,
/// and whether the host's `passwordRef` still resolves to a stored secret,
/// returns every issue in detection order.
///
/// - Parameters:
///   - host: The draft host being saved.
///   - others: All other saved hosts (not including the host being saved).
///   - defaults: The current global defaults record.
///   - passwordRefResolves: Whether `host.passwordRef.value` refers to a secret
///     that is still present in the secret store.
/// - Returns: Array of `ValidationIssue`; empty means the form is clean.
public func validateHostForm(
    _ host: Host,
    others: [Host],
    defaults: Defaults,
    passwordRefResolves: Bool
) -> [ValidationIssue] {
    var issues: [ValidationIssue] = []

    // --- Hard: required fields ---
    if host.label.isEmpty {
        issues.append(ValidationIssue(kind: .missingLabel, severity: .hardBlock))
    }
    if host.hostName.isEmpty {
        issues.append(ValidationIssue(kind: .missingHostName, severity: .hardBlock))
    }

    // --- Hard: jump-chain cycle ---
    // Build the dictionary as HostStore.saveHost does: others + [host], host overrides.
    var allHosts: [UUID: Host] = Dictionary(uniqueKeysWithValues: others.map { ($0.id, $0) })
    allHosts[host.id] = host
    if hasCycle(savingHostId: host.id, chain: host.resolvedJumpChain, in: allHosts) {
        issues.append(ValidationIssue(kind: .jumpChainCycle, severity: .hardBlock))
    }

    // --- Hard: inline jump hops with missing hostName ---
    for (index, hop) in host.resolvedJumpChain.enumerated() {
        if case let .inline(hostName, _, _, _) = hop, hostName.isEmpty {
            issues.append(ValidationIssue(
                kind: .inlineJumpHostMissingHostName(index: index),
                severity: .hardBlock
            ))
        }
    }

    // --- Hard: port-forward missing fields ---
    for (index, fwd) in (host.localForwards.value ?? []).enumerated() {
        if fwd.hostAddress.isEmpty || fwd.bindPort <= 0 || fwd.hostPort <= 0 {
            issues.append(ValidationIssue(kind: .localForwardMissingField(index: index), severity: .hardBlock))
        }
    }
    for (index, fwd) in (host.remoteForwards.value ?? []).enumerated() {
        if fwd.hostAddress.isEmpty || fwd.bindPort <= 0 || fwd.hostPort <= 0 {
            issues.append(ValidationIssue(kind: .remoteForwardMissingField(index: index), severity: .hardBlock))
        }
    }
    for (index, fwd) in (host.dynamicForwards.value ?? []).enumerated() {
        if fwd.bindPort <= 0 {
            issues.append(ValidationIssue(kind: .dynamicForwardMissingField(index: index), severity: .hardBlock))
        }
    }

    // --- Hard: stale password reference ---
    if host.passwordRef.value != nil && !passwordRefResolves {
        issues.append(ValidationIssue(kind: .stalePasswordRef, severity: .hardBlock))
    }

    // --- Soft: duplicate label ---
    let duplicates = others.filter { $0.label == host.label }
    if !duplicates.isEmpty {
        let refs = duplicates.map { HostRef(id: $0.id, label: $0.label) }
        issues.append(ValidationIssue(kind: .duplicateLabel(existing: refs), severity: .softBlock))
    }

    // --- Soft: no user set ---
    if host.user.value == nil && defaults.user.value == nil {
        issues.append(ValidationIssue(kind: .noUserSet, severity: .softBlock))
    }

    return issues
}

/// Returns `true` iff `issues` contains no `.hardBlock` — the Save action is allowed.
public func canSave(_ issues: [ValidationIssue]) -> Bool {
    !issues.contains { $0.severity == .hardBlock }
}
