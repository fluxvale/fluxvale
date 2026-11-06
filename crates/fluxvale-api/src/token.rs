//! A redacted [`Token`] — the PAT credential value type every
//! authenticated call consumes. All formatting — Debug and Display —
//! is redacted; the raw value leaves this crate only via
//! [`Token::expose`], which feeds the Authorization header. Where the
//! value is *kept* (OS keychain, fallback file) is the caller's
//! business.

use std::fmt;

/// A personal access token (`fvpat_…`). All formatting — Debug and
/// Display — is redacted; the raw value leaves this crate only via
/// [`Token::expose`], which feeds the Authorization header.
#[derive(Clone, PartialEq, Eq)]
pub struct Token(String);

impl Token {
    pub fn new(value: impl Into<String>) -> Self {
        Token(value.into())
    }

    /// The raw token — for the Authorization header only.
    pub fn expose(&self) -> &str {
        &self.0
    }

    /// The display form: first 6 characters + an ellipsis.
    pub fn mask(&self) -> String {
        if self.0.chars().count() <= 6 {
            "…".to_string()
        } else {
            format!("{}…", self.0.chars().take(6).collect::<String>())
        }
    }
}

impl fmt::Debug for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Token(***redacted***)")
    }
}

impl fmt::Display for Token {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("***redacted***")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn token_debug_and_display_redact() {
        let token = Token::new("fvpat_supersecret_value");
        assert_eq!(format!("{token:?}"), "Token(***redacted***)");
        assert_eq!(format!("{token}"), "***redacted***");
        let rendered = format!("{token:?} {token} {token:?}");
        assert!(!rendered.contains("fvpat_supersecret_value"));
    }

    #[test]
    fn token_masks_all_but_first_six() {
        assert_eq!(Token::new("fvpat_secret").mask(), "fvpat_…");
        // Short values mask entirely rather than leak.
        assert_eq!(Token::new("abc").mask(), "…");
        // Character-safe, not byte-safe: multibyte tokens don't panic.
        assert_eq!(Token::new("日本語トークン値").mask(), "日本語トーク…");
    }
}
