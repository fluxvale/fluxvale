//! Canary crate — exists only to exercise the CLI CI lane (ADR-0019
//! Am. 3). The first real CLI slice replaces it.

/// The canary's one trivial function; src/main.rs and the test below
/// are its consumers.
pub fn canary() -> &'static str {
    "fluxvale-cli"
}

#[cfg(test)]
mod tests {
    use super::canary;

    #[test]
    fn canary_answers() {
        assert_eq!(canary(), "fluxvale-cli");
    }
}
