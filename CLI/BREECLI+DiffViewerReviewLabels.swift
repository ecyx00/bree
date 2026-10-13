import Foundation

extension BREECLI.DiffViewerLabels {
    /// Labels for the review-parity controls (viewed state, file filter,
    /// generated and large-diff collapse). Kept out of `bree_open.swift`,
    /// which is over the file length budget; `localized()` merges them.
    static var reviewParityLabels: [String: String] {
        [
            "changedSinceViewed": BREEDiffViewerLocalization.string("diffViewer.changedSinceViewed", defaultValue: "Changed since viewed"),
            "clearFileFilter": BREEDiffViewerLocalization.string("diffViewer.clearFileFilter", defaultValue: "Clear filter"),
            "filesViewedProgress": BREEDiffViewerLocalization.string("diffViewer.filesViewedProgress", defaultValue: "{viewed} of {total} files viewed"),
            "filterAddedFiles": BREEDiffViewerLocalization.string("diffViewer.filterAddedFiles", defaultValue: "Added"),
            "filterDeletedFiles": BREEDiffViewerLocalization.string("diffViewer.filterDeletedFiles", defaultValue: "Deleted"),
            "filterFiles": BREEDiffViewerLocalization.string("diffViewer.filterFiles", defaultValue: "Filter files"),
            "filterModifiedFiles": BREEDiffViewerLocalization.string("diffViewer.filterModifiedFiles", defaultValue: "Modified"),
            "filterRenamedFiles": BREEDiffViewerLocalization.string("diffViewer.filterRenamedFiles", defaultValue: "Renamed"),
            "generatedFile": BREEDiffViewerLocalization.string("diffViewer.generatedFile", defaultValue: "Generated file"),
            "hideViewedFiles": BREEDiffViewerLocalization.string("diffViewer.hideViewedFiles", defaultValue: "Hide viewed files"),
            "largeDiff": BREEDiffViewerLocalization.string("diffViewer.largeDiff", defaultValue: "Large diff"),
            "loadDiff": BREEDiffViewerLocalization.string("diffViewer.loadDiff", defaultValue: "Load diff"),
            "markNotViewed": BREEDiffViewerLocalization.string("diffViewer.markNotViewed", defaultValue: "Mark as not viewed"),
            "markViewed": BREEDiffViewerLocalization.string("diffViewer.markViewed", defaultValue: "Mark as viewed"),
            "noFilesMatchFilter": BREEDiffViewerLocalization.string("diffViewer.noFilesMatchFilter", defaultValue: "No files match the filter."),
            "showViewedFiles": BREEDiffViewerLocalization.string("diffViewer.showViewedFiles", defaultValue: "Show viewed files"),
            "viewed": BREEDiffViewerLocalization.string("diffViewer.viewed", defaultValue: "Viewed"),
        ]
    }
}
