//! The FluxVale CLI (ADR-0019 Am. 3): a thin presentation layer over
//! `/api/v1`. Serde types in [`api::types`] are generated from the
//! committed OpenAPI artifact by `cargo xtask openapi` — never edit
//! that file by hand.

pub mod api;
pub mod auth;
pub mod cli;
pub mod config;
pub mod human;
pub mod reads;
pub mod render;
pub mod token;
pub mod writes;
