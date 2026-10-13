//! Handwritten, blocking Rust SDK for the bree resource API.
//!
//! Resource handles are cheap clones containing an opaque typed ID and a
//! shared [`Client`]. Copying or dropping a handle performs no I/O. Reads,
//! mutations, stream cancellation, and resource deletion are always explicit.
//!
//! The generated prelaunch wire client remains available through [`raw`] for
//! protocol debugging and migration tooling. Its numeric mux slots and legacy
//! models are deliberately absent from this crate's root.
//!
//! ```no_run
//! use bree::{Client, Config, RunCommand};
//!
//! # fn main() -> bree::Result<()> {
//! let client = Client::connect(Config::default())?;
//! let session = client.current_session();
//! let created = session.create_workspace(Some("build".to_string()))?;
//! let terminal = created.resource.run(RunCommand::argv(["cargo", "test"])?)?;
//! terminal.resource.write_text("q")?;
//! # Ok(())
//! # }
//! ```
//!
//! Legacy generated types are intentionally namespaced:
//!
//! ```compile_fail
//! use bree::Id;
//! ```
//!
//! Local sidebar plugin installation and selection are CLI-only:
//!
//! ```compile_fail
//! use bree::SidebarPlugin;
//! ```

mod client;
mod codec;
mod convenience;
mod generated;
mod presence;
pub mod raw;
mod raw_support;
mod resource;
mod topology;

// Private aliases keep the checked-in legacy generator compiling without
// making its names root-level public API.
use client::{BreeClient, BreeStream};
use presence::{Nullable, Optional};
use raw_support::{CommandMetadata, EventMetadata, ProfileMetadata, StreamMetadata};

pub use client::{BreeError as Error, Result};
pub use resource::*;
