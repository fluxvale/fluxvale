//! The PAT credential: a redacted [`Token`] newtype and its store.
//!
//! Storage per ADR-0019 Am. 3: OS keychain (service `fluxvale`,
//! account = the base_url host) with a 0600-file fallback
//! (`fluxvale/credentials`) for machines without a usable keychain
//! (Linux without a secret service, or one that refuses the write).
//! The token never appears in argv, logs, errors, or Debug output.

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
    /// file (written 0600). A keychain that constructs but refuses the
    /// write (locked, headless session) falls through to the file too —
    /// the same treatment `load` gives any get_password failure; the
    /// login status line then reports where the token actually landed.
    pub fn save(&self, host: &str, token: &Token) -> anyhow::Result<()> {
        match self.keychain_entry(host) {
            None => self.file_store().set(host, token),
            Some(entry) => match entry.set_password(token.expose()) {
                Ok(()) => Ok(()),
                Err(keychain_error) => {
                    // Write the file BEFORE dropping a stale keychain
                    // entry: if the write fails, the previous keychain
                    // credential is still the only stored token — never
                    // removed by a failed save. A stale entry left
                    // readable would shadow the file token (`load`
                    // checks the keychain first), so drop it only after
                    // the write succeeds — best-effort: a locked
                    // collection refuses deletes too.
                    self.file_store().set(host, token).map_err(|file_error| {
                        anyhow::anyhow!(
                            "the OS keychain refused the token ({keychain_error}), \
                             and the fallback file failed too: {file_error}"
                        )
                    })?;
                    let _ = entry.delete_credential();
                    Ok(())
                }
            },
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
    use std::sync::Arc;

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

    /// Swaps the process-global keyring default store for a fresh mock
    /// for the guard's lifetime (restored on drop). Serialized by a
    /// static mutex: the store is global, and the test harness runs
    /// tests in parallel — two swappers would install under each other.
    struct MockKeyring {
        /// Whether the v1 facade's platform store initialized. It may
        /// not have (headless CI has no secret service) — then entries
        /// cannot be built and the tests assert only the file outcome.
        platform_store_initialized: bool,
        #[allow(dead_code)] // held for the Drop
        guard: std::sync::MutexGuard<'static, ()>,
        platform_store: Option<Arc<keyring_core::CredentialStore>>,
    }

    static KEYRING_SWAPS: std::sync::Mutex<()> = std::sync::Mutex::new(());

    impl MockKeyring {
        fn install() -> Self {
            let guard = KEYRING_SWAPS.lock().expect("keyring swap mutex poisoned");
            // Forces the facade's one-time platform-store init (which
            // installs itself as the default store) before the swap.
            let platform_store_initialized = keyring::Entry::store_status().is_ok();
            let platform_store = keyring_core::unset_default_store();
            keyring_core::set_default_store(
                keyring_core::mock::Store::new().expect("mock keyring store"),
            );
            MockKeyring {
                platform_store_initialized,
                guard,
                platform_store,
            }
        }
    }

    impl Drop for MockKeyring {
        fn drop(&mut self) {
            keyring_core::unset_default_store();
            if let Some(platform_store) = self.platform_store.take() {
                keyring_core::set_default_store(platform_store);
            }
        }
    }

    #[test]
    fn save_falls_back_to_the_file_when_the_keychain_refuses_the_write() {
        // Op-time failure, injected through keyring-core's mock store:
        // MockKeyring swaps the v1 facade's platform store for a mock,
        // so the entry `save` builds is mock-backed and its one-shot
        // set_error makes exactly the next set_password fail —
        // locked-keychain-at-write-time, not Entry::new unavailability.
        // Where the platform store cannot initialize at all (headless
        // CI), the facade's Entry::new fails instead and save reaches
        // the same file via the unavailability arm; the injected arm
        // itself only runs where a keychain initializes (dev machines).
        let mock = MockKeyring::install();

        let host = "refusing-keychain.test";
        let store = TokenStore::at(temp_dir());
        if mock.platform_store_initialized {
            let entry =
                keyring::Entry::new(KEYCHAIN_SERVICE, host).expect("the mock store builds entries");
            let cred = entry
                .inner
                .as_any()
                .downcast_ref::<keyring_core::mock::Cred>()
                .expect("the mock store builds mock credentials");
            cred.set_error(keyring_core::Error::Invalid(
                "mock".to_string(),
                "the keychain refuses the write".to_string(),
            ));
        }

        store
            .save(host, &Token::new("fvpat_fallback"))
            .expect("a refused keychain write must fall back to the 0600 file");
        assert_eq!(
            store.load(host).unwrap().map(|(token, _)| token),
            Some(Token::new("fvpat_fallback")),
            "the token must load back from the file after the keychain refused it"
        );
        // The login status line reports `load`'s location — it must say
        // the file, not claim the keychain holds the token.
        assert_eq!(
            store.load(host).unwrap().map(|(_, location)| location),
            Some(TokenLocation::FallbackFile)
        );
    }

    #[test]
    fn save_names_both_layers_when_the_fallback_file_fails_too() {
        // The dual-failure arm: keychain refuses the write AND the file
        // write fails (here: the credentials path is a directory). The
        // error must name both layers, or triage starts from nothing.
        // Same environment split as the fallback test above — where no
        // keychain initializes, the plain file error is already the
        // whole story.
        let mock = MockKeyring::install();

        let host = "refusing-keychain.test";
        let dir = temp_dir();
        std::fs::create_dir_all(dir.join("credentials")).unwrap();
        let store = TokenStore::at(dir);
        if mock.platform_store_initialized {
            let entry =
                keyring::Entry::new(KEYCHAIN_SERVICE, host).expect("the mock store builds entries");
            let cred = entry
                .inner
                .as_any()
                .downcast_ref::<keyring_core::mock::Cred>()
                .expect("the mock store builds mock credentials");
            cred.set_error(keyring_core::Error::Invalid(
                "mock".to_string(),
                "the keychain refuses the write".to_string(),
            ));
        }

        let err = store
            .save(host, &Token::new("fvpat_neither"))
            .expect_err("nothing stored: both layers failed");
        if mock.platform_store_initialized {
            let message = err.to_string();
            assert!(
                message.contains("the OS keychain refused the token")
                    && message.contains("and the fallback file failed too"),
                "the error must name both layers: {message}"
            );
        }
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
