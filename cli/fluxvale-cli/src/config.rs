//! Non-secret config (`fluxvale/config.toml`): base URL + active
//! profile. Tokens never live here — see [`crate::token`].

use std::fs;
use std::path::{Path, PathBuf};

pub const DEFAULT_BASE_URL: &str = "https://fluxvale.com";

/// The non-secret config file contents. Only these two keys — the
/// token lives in the OS keychain (0600 file fallback).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Config {
    /// API base URL (no trailing slash, no `/api/v1` suffix).
    #[serde(default = "default_base_url")]
    pub base_url: String,
    /// Name of the active profile, when one is set.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_profile: Option<String>,
    /// The organization id the wallet commands use when no --org flag
    /// is passed. Optional since #362 T6a: `resolve_org` auto-resolves
    /// a single-org account via GET /organizations; pin one here when
    /// you belong to several.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub organization_id: Option<String>,
}

fn default_base_url() -> String {
    DEFAULT_BASE_URL.to_string()
}

impl Default for Config {
    fn default() -> Self {
        Config {
            base_url: default_base_url(),
            active_profile: None,
            organization_id: None,
        }
    }
}

impl Config {
    /// Load from `path`, falling back to the default config when the
    /// file doesn't exist. A file that fails to parse is an error, not
    /// a silent default — a typo'd config must be loud.
    pub fn load(path: &Path) -> anyhow::Result<Config> {
        let raw = match fs::read_to_string(path) {
            Ok(raw) => raw,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(Config::default()),
            Err(err) => return Err(err.into()),
        };
        let config = toml::from_str::<Config>(&raw)
            .map_err(|err| anyhow::anyhow!("{}: {err}", path.display()))?;
        Ok(config.fill_defaults())
    }

    /// Write to `path`, creating parent directories.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(path, toml::to_string_pretty(self)?)?;
        Ok(())
    }

    /// Apply defaults for keys the file omitted (TOML deserialization
    /// already defaults `base_url`; keep the hook for future fields).
    fn fill_defaults(mut self) -> Self {
        if self.base_url.is_empty() {
            self.base_url = default_base_url();
        }
        self
    }
}

/// Default config path: `<config dir>/fluxvale/config.toml`.
pub fn default_path() -> anyhow::Result<PathBuf> {
    let dir = config_dir().ok_or_else(|| {
        anyhow::anyhow!("no config directory: set XDG_CONFIG_HOME or HOME (on Windows, APPDATA)")
    })?;
    Ok(dir.join("fluxvale").join("config.toml"))
}

/// Platform config dir, resolved like the `dirs` crate without the
/// dependency (std env vars only):
/// - Linux/BSD: `$XDG_CONFIG_HOME` (absolute) or `$HOME/.config`
/// - macOS:     `$HOME/Library/Application Support`
/// - Windows:   `$APPDATA` (the Roaming profile)
pub fn config_dir() -> Option<PathBuf> {
    platform_config_dir(
        env_var("XDG_CONFIG_HOME").as_deref(),
        env_var("HOME").as_deref(),
        env_var("APPDATA").as_deref(),
    )
}

fn env_var(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

/// Pure form of [`config_dir`] — env vars passed explicitly so tests
/// don't mutate process state.
fn platform_config_dir(
    xdg: Option<&str>,
    home: Option<&str>,
    appdata: Option<&str>,
) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home.map(|home| {
            PathBuf::from(home)
                .join("Library")
                .join("Application Support")
        })
    }
    #[cfg(windows)]
    {
        appdata.map(PathBuf::from)
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = appdata;
        match xdg {
            Some(xdg) if Path::new(xdg).is_absolute() => Some(PathBuf::from(xdg)),
            _ => home.map(|home| PathBuf::from(home).join(".config")),
        }
    }
}

/// The host part of a base URL — the keychain account / credentials-file
/// key (`https://fluxvale.com` -> `fluxvale.com`; non-default ports are
/// kept so local environments don't collide).
pub fn host_from_base_url(base_url: &str) -> String {
    let rest = base_url
        .strip_prefix("https://")
        .or_else(|| base_url.strip_prefix("http://"))
        .unwrap_or(base_url);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or(rest);
    authority.trim_end_matches(['.', ':']).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_when_file_missing() {
        let dir = temp_dir();
        let path = dir.join("config.toml");
        let config = Config::load(&path).unwrap();
        assert_eq!(config, Config::default());
        assert_eq!(config.base_url, "https://fluxvale.com");
    }

    #[test]
    fn round_trip() {
        let dir = temp_dir();
        let path = dir.join("nested").join("config.toml");
        let config = Config {
            base_url: "https://staging.fluxvale.com".to_string(),
            active_profile: Some("staging".to_string()),
            organization_id: Some("01JORG".to_string()),
        };
        config.save(&path).unwrap();
        let loaded = Config::load(&path).unwrap();
        assert_eq!(loaded, config);
    }

    #[test]
    fn toml_omits_none_profile() {
        let config = Config::default();
        let raw = toml::to_string_pretty(&config).unwrap();
        assert!(!raw.contains("active_profile"));
        assert!(!raw.contains("organization_id"));
        assert!(raw.contains("https://fluxvale.com"));
    }

    #[test]
    fn malformed_config_is_loud() {
        let dir = temp_dir();
        let path = dir.join("config.toml");
        std::fs::write(&path, "base_url = 12").unwrap();
        assert!(Config::load(&path).is_err());
    }

    #[test]
    fn config_dir_resolves_xdg_then_home() {
        let xdg = platform_config_dir(Some("/abs/xdg"), Some("/home/u"), None);
        assert_eq!(xdg, Some(PathBuf::from("/abs/xdg")));
        let home_only = platform_config_dir(None, Some("/home/u"), None);
        assert_eq!(home_only, Some(PathBuf::from("/home/u/.config")));
        // A relative XDG value is ignored per the spec.
        let relative = platform_config_dir(Some("rel/xdg"), Some("/home/u"), None);
        assert_eq!(relative, Some(PathBuf::from("/home/u/.config")));
        assert_eq!(platform_config_dir(None, None, None), None);
    }

    #[test]
    fn host_from_base_url_parses() {
        assert_eq!(host_from_base_url("https://fluxvale.com"), "fluxvale.com");
        assert_eq!(
            host_from_base_url("https://staging.fluxvale.com/"),
            "staging.fluxvale.com"
        );
        // Ports distinguish local environments.
        assert_eq!(
            host_from_base_url("http://127.0.0.1:4000"),
            "127.0.0.1:4000"
        );
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-config-test-{}-{}",
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
