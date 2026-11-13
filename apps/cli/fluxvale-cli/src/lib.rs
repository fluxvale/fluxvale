//! The FluxVale CLI (ADR-0019 Am. 3): a thin presentation layer over
//! `/api/v1`. The client itself — plus the wire types, the device
//! flow, and the generated types — lives in the `fluxvale-api` crate
//! (crates/fluxvale-api); its `src/types.rs` is generated from the
//! committed OpenAPI artifact by `cargo xtask openapi` — never edit
//! that file by hand.

pub mod auth;
pub mod cli;
pub mod config;
pub mod human;
pub mod reads;
pub mod render;
pub mod terraform;
pub mod token;
pub mod writes;
