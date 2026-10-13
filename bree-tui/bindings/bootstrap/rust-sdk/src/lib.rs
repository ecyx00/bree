//! Ownership-reservation prerelease for `bree-sdk`.
//!
//! Use a stable release for the bree Rust SDK.

/// Identifies this package as the one-time ownership bootstrap.
pub const OWNERSHIP_BOOTSTRAP: bool = true;

#[cfg(test)]
mod tests {
    #[test]
    fn identifies_the_ownership_bootstrap() {
        assert!(super::OWNERSHIP_BOOTSTRAP);
    }
}
