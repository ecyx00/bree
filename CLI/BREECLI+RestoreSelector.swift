extension BREECLI {
    /// The surface identity constraints parsed from `bree restore` or `bree fork` arguments.
    struct RestoreSelector {
        let surface: String?
        let usesCurrentSurface: Bool
        let kind: String?
        let checkpointID: String?
    }
}
