//! The PAT credential: a redacted [`Token`] newtype and its store.
//!
//! Storage per ADR-0019 Am. 3: OS keychain (service `fluxvale`,
//! account = the base_url host) with a 0600-file fallback
//! (`fluxvale/credentials`) for machines without a keychain (Linux
//! without a secret service). The token never appears in argv, logs,
//! errors, or Debug output.

use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

/// The platform config dir's `fluxvale/` folder (where the fallback
/// credentials file lives).
use crate::config;

/// Where a loaded token came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenLocation {
    Keychain,
    FallbackFile,
}

impl fmt::Display for TokenLocation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TokenLocation::Keychain => f.write_str("the OS keychain"),
            TokenLocation::FallbackFile => f.write_str("the credentials file"),
        }
    }
}

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

/// The keychain service name (constant across profiles; the account
/// distinguishes environments).
const KEYCHAIN_SERVICE: &str = "fluxvale";
/// The fallback credentials file name, sibling of `config.toml`.
const FALLBACK_FILE: &str = "credentials";

/// Keychain first, 0600-file fallback (ADR-0019 Am. 3).
pub struct TokenStore {
    config_dir: PathBuf,
}

impl TokenStore {
    /// Store rooted at the `fluxvale/` config directory.
    pub fn at(config_dir: PathBuf) -> Self {
        TokenStore { config_dir }
    }

    /// The default store location: `<config dir>/fluxvale`.
    pub fn default_dir() -> anyhow::Result<PathBuf> {
        let dir = config::config_dir().ok_or_else(|| {
            anyhow::anyhow!(
                "no config directory: set XDG_CONFIG_HOME or HOME (on Windows, APPDATA)"
            )
        })?;
        Ok(dir.join("fluxvale"))
    }

    /// Save the token: OS keychain where available, else the fallback
    /// file (written 0600).
    pub fn save(&self, host: &str, token: &Token) -> anyhow::Result<()> {
        match self.keychain_entry(host) {
            Some(entry) => entry.set_password(token.expose()).map_err(|err| {
                anyhow::anyhow!("the OS keychain refused the token ({err}); nothing was stored")
            }),
            None => self.file_store().set(host, token),
        }
    }

    /// Load the token, reporting where it came from. `None` when no
    /// credential exists for `host` anywhere.
    pub fn load(&self, host: &str) -> anyhow::Result<Option<(Token, TokenLocation)>> {
        if let Some(entry) = self.keychain_entry(host)
            && let Ok(password) = entry.get_password()
        {
            return Ok(Some((Token::new(password), TokenLocation::Keychain)));
        }
        Ok(self
            .file_store()
            .get(host)?
            .map(|token| (token, TokenLocation::FallbackFile)))
    }

    /// Remove the credential everywhere (best-effort on each layer).
    pub fn delete(&self, host: &str) -> anyhow::Result<()> {
        if let Some(entry) = self.keychain_entry(host) {
            // NoEntry on logout is fine — the file layer may still hold it.
            let _ = entry.delete_credential();
        }
        self.file_store().remove(host)
    }

    fn keychain_entry(&self, host: &str) -> Option<keyring::Entry> {
        keyring::Entry::new(KEYCHAIN_SERVICE, host).ok()
    }

    fn file_store(&self) -> FileTokenStore {
        FileTokenStore::at(self.config_dir.clone())
    }
}

/// The 0600 fallback file (`fluxvale/credentials`): a TOML map of
/// host -> token. Split from [`TokenStore`] so the file layer is
/// testable on machines that have a keychain.
pub struct FileTokenStore {
    path: PathBuf,
}

impl FileTokenStore {
    pub fn at(config_dir: PathBuf) -> Self {
        FileTokenStore {
            path: config_dir.join(FALLBACK_FILE),
        }
    }

    pub fn get(&self, host: &str) -> anyhow::Result<Option<Token>> {
        match fs::read_to_string(&self.path) {
            Ok(raw) => {
                let map = self.parse(&raw)?;
                Ok(map.get(host).map(|value| Token::new(value.clone())))
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(err) => Err(err.into()),
        }
    }

    pub fn set(&self, host: &str, token: &Token) -> anyhow::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
            set_owner_only(parent);
        }
        let mut map = match fs::read_to_string(&self.path) {
            Ok(raw) => self.parse(&raw)?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(err) => return Err(err.into()),
        };
        map.insert(host.to_string(), token.expose().to_string());
        // Mode is set at creation AND after write: a pre-existing file
        // (maybe with looser perms) must end up 0600 either way.
        write_owner_rw(&self.path, &toml::to_string_pretty(&map)?)?;
        set_owner_rw(&self.path)?;
        Ok(())
    }

    pub fn remove(&self, host: &str) -> anyhow::Result<()> {
        let raw = match fs::read_to_string(&self.path) {
            Ok(raw) => raw,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(err) => return Err(err.into()),
        };
        let mut map = self.parse(&raw)?;
        if map.remove(host).is_none() {
            return Ok(());
        }
        if map.is_empty() {
            fs::remove_file(&self.path)?;
        } else {
            write_owner_rw(&self.path, &toml::to_string_pretty(&map)?)?;
        }
        Ok(())
    }

    fn parse(&self, raw: &str) -> anyhow::Result<BTreeMap<String, String>> {
        toml::from_str(raw).map_err(|err| anyhow::anyhow!("{}: {err}", self.path.display()))
    }
}

/// Create the file 0600 (Unix) or default perms elsewhere.
fn write_owner_rw(path: &Path, contents: &str) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::OpenOptionsExt;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        file.write_all(contents.as_bytes())
    }
    #[cfg(not(unix))]
    {
        fs::write(path, contents)
    }
}

/// Force 0600 on a file that may already exist with looser perms.
fn set_owner_rw(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(path)?.permissions();
        perms.set_mode(0o600);
        fs::set_permissions(path, perms)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

/// Force 0700 on the credentials directory.
fn set_owner_only(path: &Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if let Ok(metadata) = fs::metadata(path) {
            let mut perms = metadata.permissions();
            perms.set_mode(0o700);
            let _ = fs::set_permissions(path, perms);
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
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

    #[test]
    fn file_store_round_trip() {
        let store = FileTokenStore::at(temp_dir());
        assert!(store.get("fluxvale.com").unwrap().is_none());
        store
            .set("fluxvale.com", &Token::new("fvpat_stored"))
            .unwrap();
        let loaded = store.get("fluxvale.com").unwrap().unwrap();
        assert_eq!(loaded, Token::new("fvpat_stored"));
        // Second host coexists.
        store
            .set("staging.fluxvale.com", &Token::new("fvpat_other"))
            .unwrap();
        assert_eq!(
            store.get("fluxvale.com").unwrap().unwrap(),
            Token::new("fvpat_stored")
        );
        assert_eq!(
            store.get("staging.fluxvale.com").unwrap().unwrap(),
            Token::new("fvpat_other")
        );
    }

    #[cfg(unix)]
    #[test]
    fn fallback_file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let store = FileTokenStore::at(temp_dir());
        store
            .set("fluxvale.com", &Token::new("fvpat_modecheck"))
            .unwrap();
        let mode = fs::metadata(&store.path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "credentials file must be owner-only");
        // Rewrite (pre-existing path) keeps the mode.
        store
            .set("fluxvale.com", &Token::new("fvpat_second"))
            .unwrap();
        let mode = fs::metadata(&store.path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn remove_prunes_host_and_empty_file() {
        let store = FileTokenStore::at(temp_dir());
        store.set("a.example", &Token::new("fvpat_a")).unwrap();
        store.set("b.example", &Token::new("fvpat_b")).unwrap();
        store.remove("a.example").unwrap();
        assert!(store.get("a.example").unwrap().is_none());
        assert!(store.get("b.example").unwrap().is_some());
        store.remove("b.example").unwrap();
        assert!(!store.path.exists(), "empty credentials file is removed");
        // Removing an absent host is a no-op.
        store.remove("never.existed").unwrap();
    }

    #[test]
    fn default_store_dir_is_fluxvale_under_config() {
        // The dir itself is environment-dependent; pin the join shape.
        let store = TokenStore::at(PathBuf::from("/cfg-root"));
        assert_eq!(store.config_dir, PathBuf::from("/cfg-root"));
        assert!(
            TokenStore::at(PathBuf::from("/cfg-root"))
                .file_store()
                .path
                .ends_with("credentials")
        );
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-token-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
