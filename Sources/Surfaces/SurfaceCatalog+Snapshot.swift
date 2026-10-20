import BreeSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Provider rows as registered, sorted for stable readers (sidebar, CLI).
    var snapshot: SurfaceCatalogSnapshot {
        SurfaceCatalogSnapshot(
            machines: machines.values.sorted {
                if $0.id.isLocal != $1.id.isLocal { return $0.id.isLocal }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            resources: resources.values.sorted { $0.id.rawValue < $1.id.rawValue },
            projections: projections.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
        )
    }

    /// Complete export for the local control socket.
    var export: SurfaceCatalogExport {
        SurfaceCatalogExport(catalog: snapshot)
    }
}
