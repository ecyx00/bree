import Foundation
import BreeGit

/// One off-main read of a directory's git metadata, applied back on the main
/// actor to every panel that joined the probe for that directory.
struct InitialWorkspaceGitMetadataSnapshot: Equatable, Sendable {
    let isRepository: Bool
    let branch: String?
    let isDirty: Bool
    let indexSignature: String?
    let indexContentSignature: String?
    let headSignature: String?
    let changedFileCount: Int?

    /// Probes `directory` through `reader` and folds the result into a
    /// snapshot (branch normalized).
    init(
        probing directory: String,
        reader: any WorkspaceGitMetadataReading,
        trackedPathEventGeneration: GitTrackedPathEventGeneration? = nil
    ) async {
        let metadata = await reader.workspaceMetadata(
            for: directory,
            trackedPathEventGeneration: trackedPathEventGeneration
        )
        guard metadata.isRepository else {
            self.init(
                isRepository: false,
                branch: nil,
                isDirty: false,
                indexSignature: nil,
                indexContentSignature: nil,
                headSignature: nil
            )
            return
        }

        let branch = GitMetadataService.normalizedBranchName(metadata.branch)
        self.init(
            isRepository: true,
            branch: branch,
            isDirty: metadata.isDirty,
            indexSignature: metadata.indexSignature,
            indexContentSignature: metadata.indexContentSignature,
            headSignature: metadata.headSignature,
            changedFileCount: metadata.changedFileCount
        )
    }

    init(
        isRepository: Bool,
        branch: String?,
        isDirty: Bool,
        indexSignature: String?,
        indexContentSignature: String?,
        headSignature: String?,
        changedFileCount: Int? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDirty = isDirty
        self.indexSignature = indexSignature
        self.indexContentSignature = indexContentSignature
        self.headSignature = headSignature
        self.changedFileCount = changedFileCount
    }
}
