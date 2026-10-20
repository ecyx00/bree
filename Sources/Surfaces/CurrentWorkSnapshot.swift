import BreeSurfaceCatalogModel
import Foundation

/// A bounded, read-only projection of existing work owners for CLI and Find Work.
struct CurrentWorkSnapshot: Codable, Sendable {
    init(
        observedAt: String,
        totalObserved: Int,
        truncated: Bool,
        ownerAvailability: [String: String],
        items: [Item]
    ) {
        self.observedAt = observedAt
        self.totalObserved = totalObserved
        self.truncated = truncated
        self.ownerAvailability = ownerAvailability
        self.items = items
    }

    var schemaVersion = 1
    var authority = "read_only_projection"
    var observedAt: String
    var totalObserved: Int
    var truncated: Bool
    var ownerAvailability: [String: String]
    var unsupportedFacts = ["durable_work_identity", "review_threads", "check_runs", "review_dispositions"]
    var items: [Item]

    struct Evidence: Codable, Sendable {
        init(
            owner: String,
            reference: String,
            observedAt: String
        ) {
            self.owner = owner
            self.reference = reference
            self.observedAt = observedAt
        }

        var owner: String
        var reference: String
        var observedAt: String
    }

    struct Freshness: Codable, Sendable {
        init(
            state: String,
            reason: String?,
            observedAt: String
        ) {
            self.state = state
            self.reason = reason
            self.observedAt = observedAt
        }

        var state: String
        var reason: String?
        /// Time this owner state was read, not the time a remote graph was produced.
        var observedAt: String
    }

    struct Placement: Codable, Sendable {
        init(
            kind: String,
            machine: String
        ) {
            self.kind = kind
            self.machine = machine
        }

        var kind: String
        var machine: String
    }

    struct Projection: Codable, Sendable {
        init(
            resourceRef: String,
            workspaceID: UUID,
            panelID: UUID,
            stableSurfaceID: UUID?,
            stableWorkspaceID: UUID?,
            remoteWorkspaceID: String?,
            remoteTabID: String?
        ) {
            self.resourceRef = resourceRef
            self.workspaceID = workspaceID
            self.panelID = panelID
            self.stableSurfaceID = stableSurfaceID
            self.stableWorkspaceID = stableWorkspaceID
            self.remoteWorkspaceID = remoteWorkspaceID
            self.remoteTabID = remoteTabID
        }

        var resourceRef: String
        var workspaceID: UUID
        var panelID: UUID
        var stableSurfaceID: UUID?
        var stableWorkspaceID: UUID?
        var remoteWorkspaceID: String?
        var remoteTabID: String?
    }

    struct Agent: Codable, Sendable {
        init(
            sessionID: String?,
            kind: String?,
            state: String,
            hasHookLifecycleState: Bool,
            version: Int?,
            lastActivityAt: String?,
            evidence: Evidence
        ) {
            self.sessionID = sessionID
            self.kind = kind
            self.state = state
            self.hasHookLifecycleState = hasHookLifecycleState
            self.version = version
            self.lastActivityAt = lastActivityAt
            self.evidence = evidence
        }

        var sessionID: String?
        var kind: String?
        var state: String
        var hasHookLifecycleState: Bool
        var version: Int?
        var lastActivityAt: String?
        var evidence: Evidence
    }

    struct Attention: Codable, Sendable {
        init(
            kind: String,
            scope: String,
            evidence: Evidence
        ) {
            self.kind = kind
            self.scope = scope
            self.evidence = evidence
        }

        var kind: String
        var scope: String
        var evidence: Evidence
    }

    struct Obligation: Codable, Sendable {
        init(
            kind: String,
            freshness: Freshness,
            evidence: Evidence
        ) {
            self.kind = kind
            self.freshness = freshness
            self.evidence = evidence
        }

        var kind: String
        var possibleHumanObligation = true
        var freshness: Freshness
        var evidence: Evidence
    }

    struct Item: Codable, Sendable {
        init(
            resourceRef: String,
            durableSurfaceID: UUID?,
            label: String,
            kind: String,
            lifecycle: String,
            placement: Placement,
            projections: [Projection],
            cwd: String?,
            projectHints: [String],
            repositoryHints: [String],
            agents: [Agent],
            attention: [Attention],
            freshness: Freshness,
            possibleHumanObligations: [Obligation],
            evidence: [Evidence],
            omitted: [String: Int]
        ) {
            self.resourceRef = resourceRef
            self.durableSurfaceID = durableSurfaceID
            self.label = label
            self.kind = kind
            self.lifecycle = lifecycle
            self.placement = placement
            self.projections = projections
            self.cwd = cwd
            self.projectHints = projectHints
            self.repositoryHints = repositoryHints
            self.agents = agents
            self.attention = attention
            self.freshness = freshness
            self.possibleHumanObligations = possibleHumanObligations
            self.evidence = evidence
            self.omitted = omitted
        }

        var resourceRef: String
        /// Only a local resource can inherit its single durable surface identity.
        var durableSurfaceID: UUID?
        var label: String
        var kind: String
        var lifecycle: String
        var placement: Placement
        var projections: [Projection]
        var cwd: String?
        var projectHints: [String]
        var repositoryHints: [String]
        var agents: [Agent]
        var attention: [Attention]
        var freshness: Freshness
        var possibleHumanObligations: [Obligation]
        var evidence: [Evidence]
        var omitted: [String: Int]
    }

    /// The socket and human consumers receive this same schema, without runtime owners.
    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        guard data.count <= 2_000_000 else {
            throw SurfaceCatalogError.unsupported("Current-work response exceeds 2 MB; request a smaller limit")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
