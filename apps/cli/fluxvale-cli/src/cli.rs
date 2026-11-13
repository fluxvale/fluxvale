//! The command tree (clap derive) + dispatch. Handlers live in their
//! own modules by slice: the read commands in [`crate::reads`] (T4),
//! the auth commands (T5) in [`crate::auth`], and the writes — the
//! instance lifecycle plus backups and access (T6) — in
//! [`crate::writes`].

use crate::auth;
use crate::config::{self, Config};
use crate::reads;
use crate::terraform;
use crate::token::TokenStore;
use crate::writes::{self, ConfigureBackup, DeployFlags};
use clap::{Parser, Subcommand, ValueEnum};
use std::ffi::OsString;
use std::path::PathBuf;

/// The FluxVale command line.
#[derive(Debug, Parser)]
#[command(
    name = "fluxvale",
    version,
    about = "Manage your FluxVale instances, apps, and wallet from the command line"
)]
pub struct Cli {
    /// Path to the config file (default: <config dir>/fluxvale/config.toml)
    #[arg(long, global = true, value_name = "PATH")]
    pub config: Option<PathBuf>,

    /// Output format
    #[arg(long, global = true, value_enum, default_value_t = Output::Table)]
    pub output: Output,

    #[command(subcommand)]
    pub command: Command,
}

/// Output format for list/show commands.
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Output {
    /// Aligned columns for humans
    Table,
    /// Machine-readable JSON
    Json,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Sign in, sign out, or check your FluxVale credentials
    Auth {
        #[command(subcommand)]
        command: AuthCommand,
    },
    /// Show the signed-in user
    Whoami,
    /// List and inspect apps in the FluxVale catalog
    Apps {
        #[command(subcommand)]
        command: AppsCommand,
    },
    /// List, inspect, and manage your instances
    Instances {
        #[command(subcommand)]
        command: InstancesCommand,
    },
    /// Configure and run instance backups
    Backups {
        #[command(subcommand)]
        command: BackupsCommand,
    },
    /// Inspect and manage private access to your instances
    Access {
        #[command(subcommand)]
        command: AccessCommand,
    },
    /// Promote live resources into Terraform import blocks
    Terraform {
        #[command(subcommand)]
        command: TerraformCommand,
    },
    /// Show your wallet balance and runway
    Wallet {
        #[command(subcommand)]
        command: WalletCommand,
    },
    /// Top up your wallet
    Topup {
        /// Open the top-up page in your browser
        #[arg(long)]
        open: bool,
    },
}

#[derive(Debug, Subcommand)]
pub enum AuthCommand {
    /// Sign in — the device flow: a code to approve in the panel,
    /// the token lands in your OS keychain
    Login {
        /// Comma-separated scopes (default: the full catalog)
        #[arg(long, value_name = "SCOPE,SCOPE")]
        scopes: Option<String>,
        /// Don't open the approval page in a browser
        #[arg(long)]
        no_open: bool,
    },
    /// Sign out and remove the stored token
    Logout,
    /// Show who you are signed in as
    Status,
    /// Run a command with the stored token in its environment only
    /// (`FLUXVALE_PAT`) — e.g. `fluxvale auth exec -- tofu apply`
    Exec {
        /// The command and its arguments, after `--`
        #[arg(last = true, required = true, num_args = 1.., value_name = "COMMAND")]
        command: Vec<OsString>,
    },
    /// Mint a scoped, short-lived token for CI or a container — printed
    /// once to stdout; the CLI never writes it to disk
    Token {
        /// Comma-separated scopes (required; the server refuses any you
        /// do not already hold)
        #[arg(long, value_name = "SCOPE,SCOPE")]
        scopes: String,
        /// Lifetime: one integer plus s, m, h, or d (e.g. 30m, 12h, 7d)
        #[arg(long, value_name = "DURATION")]
        ttl: String,
        /// A name for the token row (default: "fluxvale auth token")
        #[arg(long, value_name = "NAME")]
        name: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
pub enum AppsCommand {
    /// List apps in the catalog
    List,
    /// Show one app
    Show {
        /// The app slug
        slug: String,
    },
}

#[derive(Debug, Subcommand)]
pub enum InstancesCommand {
    /// List your instances
    List,
    /// Show one instance's status (verbose list when no id is given)
    Status {
        /// The instance ID (omit for a verbose list)
        instance: Option<String>,
    },
    /// Create an instance of a catalog app and deploy it
    Deploy {
        /// The app slug (`fluxvale apps list`)
        #[arg(long)]
        app: String,
        /// A name for the instance (default: the server generates one)
        #[arg(long, value_name = "NAME")]
        name: Option<String>,
        /// CPU cores (default: the app version's)
        #[arg(long, value_name = "CORES")]
        cpu: Option<String>,
        /// Memory in MB (default: the app version's)
        #[arg(long, value_name = "MB")]
        memory_mb: Option<i64>,
        /// Storage in GB (default: the app version's)
        #[arg(long, value_name = "GB")]
        storage_gb: Option<i64>,
        /// The app version id (default: the newest published)
        #[arg(long, value_name = "ID")]
        version: Option<String>,
        /// An env var for the new instance, repeatable (KEY=VALUE).
        /// Values are write-only — never echoed.
        #[arg(long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
    },
    /// Merge env vars on an existing instance (in place)
    Configure {
        /// The instance ID
        instance: String,
        /// Add or replace an env var, repeatable (KEY=VALUE). Values
        /// are write-only — never echoed.
        #[arg(long = "env", value_name = "KEY=VALUE")]
        env: Vec<String>,
        /// Remove an env var by name, repeatable. An empty string is a
        /// value, not a removal — use this flag.
        #[arg(long = "remove", value_name = "KEY")]
        remove: Vec<String>,
    },
    /// Stop a running instance
    Stop {
        /// The instance ID
        instance: String,
    },
    /// Start a stopped instance
    Start {
        /// The instance ID
        instance: String,
    },
    /// Destroy an instance — ALL its data is deleted
    Destroy {
        /// The instance ID
        instance: String,
        /// Actually destroy; without this flag nothing is sent
        #[arg(long)]
        confirm: bool,
    },
}

#[derive(Debug, Subcommand)]
pub enum BackupsCommand {
    /// Configure backup settings for an instance (creates or updates
    /// the row — whichever applies)
    Configure {
        /// The instance ID
        instance: String,
        /// The S3 endpoint — http(s)://host[:port], no path
        #[arg(long)]
        endpoint: String,
        /// The S3 bucket name
        #[arg(long)]
        bucket: String,
        /// Optional key prefix inside the bucket (no leading or
        /// trailing slash)
        #[arg(long)]
        prefix: Option<String>,
        /// The S3 access key's ID — an identifier, not the secret. The
        /// matching secret is written by the panel's save; backups
        /// cannot run until it exists
        #[arg(long, value_name = "ID")]
        access_key_id: String,
        /// How many snapshots to keep (2-30, default 7)
        #[arg(long, value_name = "2-30")]
        retention: Option<u8>,
        /// Keep backups enabled (the default)
        #[arg(long)]
        enabled: bool,
        /// Pause backups — the row and its credentials stay
        #[arg(long, conflicts_with = "enabled")]
        disabled: bool,
    },
    /// Run a backup now
    Run {
        /// The instance ID
        instance: String,
    },
    /// Show backup status: the settings row plus the latest run
    Status {
        /// The instance ID
        instance: String,
    },
    /// Restore an instance's volume from a backup run — the current
    /// volume state is OVERWRITTEN
    Restore {
        /// The instance ID
        instance: String,
        /// The backup run to restore from (the newest successful one —
        /// see `backups status`)
        #[arg(long, value_name = "RUN_ID")]
        from: String,
        /// Actually overwrite the volume; without this flag nothing is
        /// sent and the command prints what would happen
        #[arg(long)]
        confirm: bool,
    },
}

#[derive(Debug, Subcommand)]
pub enum AccessCommand {
    /// Show the organization's private-access gateway
    Status {
        /// The organization ID (default: organization_id from the config file)
        #[arg(long, value_name = "ID")]
        org: Option<String>,
    },
    /// Attach a private instance to a gateway
    Attach {
        /// The gateway ID
        gateway: String,
        /// The instance ID
        instance: String,
    },
    /// Detach an instance from a gateway (idempotent)
    Detach {
        /// The gateway ID
        gateway: String,
        /// The instance ID
        instance: String,
    },
    /// Create the organization's gateway — needs a Tailscale auth key
    /// and provisions cluster resources: use the panel
    Create {
        /// The tailnet's MagicDNS domain (unused — see above)
        #[arg(long, value_name = "DOMAIN")]
        tailnet_domain: Option<String>,
    },
    /// Resume a suspended gateway
    Resume {
        /// The gateway ID
        gateway: String,
    },
}

#[derive(Debug, Subcommand)]
pub enum TerraformCommand {
    /// Write versions.tf, imports.tf, and README.md for an org's live estate
    Import {
        /// The organization's slug or id
        #[arg(long)]
        org: String,
        /// Directory to write the scaffold into (default: the current directory)
        #[arg(long, value_name = "DIR")]
        out: Option<PathBuf>,
    },
}

#[derive(Debug, Subcommand)]
pub enum WalletCommand {
    /// Show your wallet balance
    Balance {
        /// The organization ID (default: organization_id from the config file)
        #[arg(long, value_name = "ID")]
        org: Option<String>,
    },
    /// Show the wallet's ledger entries
    Ledger {
        /// The organization ID (default: organization_id from the config file)
        #[arg(long, value_name = "ID")]
        org: Option<String>,
        /// How many entries to fetch (default 25)
        #[arg(long, value_name = "N")]
        limit: Option<u32>,
        /// Fetch entries older than this opaque cursor (from a previous
        /// page's next-page hint)
        #[arg(long, value_name = "CURSOR", conflicts_with = "after")]
        before: Option<String>,
        /// Fetch entries newer than this opaque cursor
        #[arg(long, value_name = "CURSOR")]
        after: Option<String>,
    },
    /// Show how long your balance lasts at current spend
    Runway {
        /// The organization ID (default: organization_id from the config file)
        #[arg(long, value_name = "ID")]
        org: Option<String>,
    },
}

/// Dispatch. Returns Ok(()) on success; errors print one line to
/// stderr and exit non-zero.
pub fn run(cli: &Cli) -> anyhow::Result<()> {
    let config_path = match &cli.config {
        Some(path) => path.clone(),
        None => config::default_path()?,
    };
    let config = Config::load(&config_path)?;

    match &cli.command {
        Command::Auth { command } => match command {
            AuthCommand::Login { scopes, no_open } => {
                let host = config::host_from_base_url(&config.base_url);
                let store = TokenStore::at(TokenStore::default_dir()?);
                let flags = auth::LoginFlags {
                    scopes: scopes.clone(),
                    no_open: *no_open,
                };
                print(auth::login(
                    &config.base_url,
                    &flags,
                    |token| {
                        store.save(&host, token)?;
                        match store.load(&host)? {
                            Some((_, location)) => Ok(location),
                            None => anyhow::bail!("the token did not persist"),
                        }
                    },
                    reads::open_url,
                    std::thread::sleep,
                    |fragment| eprint!("{fragment}"),
                    |line| println!("{line}"),
                ))
            }
            AuthCommand::Logout => {
                let store = TokenStore::at(TokenStore::default_dir()?);
                let host = config::host_from_base_url(&config.base_url);
                print(auth::logout_store(&store, &host))
            }
            AuthCommand::Status => {
                let (client, location) = reads::read_client(&config)?;
                print(reads::whoami(&client, location, cli.output))
            }
            AuthCommand::Exec { command } => {
                let store = TokenStore::at(TokenStore::default_dir()?);
                let host = config::host_from_base_url(&config.base_url);
                let status =
                    auth::exec(|| Ok(store.load(&host)?.map(|(token, _)| token)), command)?;
                // Pass the child's status through untouched: a wrapper
                // must not dress a failed tofu plan as a CLI error.
                match status.code() {
                    Some(0) => Ok(()),
                    Some(code) => std::process::exit(code),
                    None => std::process::exit(1),
                }
            }
            AuthCommand::Token { scopes, ttl, name } => {
                let caller = reads::stored_token(&config)?;
                let scopes = auth::parse_scopes(Some(scopes.as_str()))?;
                let ttl_seconds = auth::parse_ttl(ttl)?;
                let minted = auth::mint(
                    &config.base_url,
                    caller,
                    name.as_deref(),
                    &scopes,
                    ttl_seconds,
                )?;
                // stdout carries the secret and nothing else, so the
                // caller can pipe it straight into a secret store.
                eprintln!("{}", auth::mint_summary(&minted));
                print(Ok(minted.token.expose().to_string()))
            }
        },
        Command::Whoami => {
            let (client, location) = reads::read_client(&config)?;
            print(reads::whoami(&client, location, cli.output))
        }
        Command::Apps { command } => match command {
            AppsCommand::List => {
                let (client, _) = reads::read_client(&config)?;
                print(reads::apps_list(&client, cli.output))
            }
            AppsCommand::Show { slug } => {
                let (client, _) = reads::read_client(&config)?;
                print(reads::apps_show(&client, slug, cli.output))
            }
        },
        Command::Instances { command } => match command {
            InstancesCommand::List => {
                let (client, _) = reads::read_client(&config)?;
                print(reads::instances_list(&client, cli.output))
            }
            InstancesCommand::Status { instance } => {
                let (client, _) = reads::read_client(&config)?;
                match instance {
                    Some(id) => print(reads::instances_status(&client, id, cli.output)),
                    None => print(reads::instances_status_all(&client, cli.output)),
                }
            }
            InstancesCommand::Deploy {
                app,
                name,
                cpu,
                memory_mb,
                storage_gb,
                version,
                env,
            } => {
                let (client, _) = reads::read_client(&config)?;
                let flags = DeployFlags {
                    app: app.clone(),
                    name: name.clone(),
                    cpu: cpu.clone(),
                    memory_mb: *memory_mb,
                    storage_gb: *storage_gb,
                    version: version.clone(),
                    env: writes::parse_env_assignments(env)?,
                };
                print(writes::instances_deploy(&client, &flags, cli.output))
            }
            InstancesCommand::Configure {
                instance,
                env,
                remove,
            } => {
                let (client, _) = reads::read_client(&config)?;
                let set = writes::parse_env_assignments(env)?;
                print(writes::instances_configure(
                    &client, instance, &set, remove, cli.output,
                ))
            }
            InstancesCommand::Stop { instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::instances_stop(&client, instance, cli.output))
            }
            InstancesCommand::Start { instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::instances_start(&client, instance, cli.output))
            }
            InstancesCommand::Destroy { instance, confirm } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::instances_destroy(
                    &client, instance, *confirm, cli.output,
                ))
            }
        },
        Command::Backups { command } => match command {
            BackupsCommand::Configure {
                instance,
                endpoint,
                bucket,
                prefix,
                access_key_id,
                retention,
                enabled,
                disabled,
            } => {
                let (client, _) = reads::read_client(&config)?;
                let flags = ConfigureBackup {
                    instance: instance.clone(),
                    endpoint: endpoint.clone(),
                    bucket: bucket.clone(),
                    prefix: prefix.clone(),
                    access_key_id: access_key_id.clone(),
                    retention: *retention,
                    enabled: writes::enabled_flag(*enabled, *disabled),
                };
                print(writes::backups_configure(&client, &flags, cli.output))
            }
            BackupsCommand::Status { instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::backups_status(&client, instance, cli.output))
            }
            BackupsCommand::Run { instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::backups_run(&client, instance, cli.output))
            }
            BackupsCommand::Restore {
                instance,
                from,
                confirm,
            } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::backups_restore(
                    &client, instance, from, *confirm, cli.output,
                ))
            }
        },
        Command::Access { command } => match command {
            AccessCommand::Status { org } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref(), &client)?;
                print(writes::access_status(&client, &org_id, cli.output))
            }
            AccessCommand::Attach { gateway, instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::access_attach(
                    &client, gateway, instance, cli.output,
                ))
            }
            AccessCommand::Detach { gateway, instance } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::access_detach(
                    &client, gateway, instance, cli.output,
                ))
            }
            AccessCommand::Create { .. } => print(writes::access_create_unavailable()),
            AccessCommand::Resume { gateway } => {
                let (client, _) = reads::read_client(&config)?;
                print(writes::access_resume(&client, gateway, cli.output))
            }
        },
        Command::Terraform { command } => match command {
            TerraformCommand::Import { org, out } => {
                let (client, _) = reads::read_client(&config)?;
                let out = out.clone().unwrap_or_else(terraform::default_out);
                print(terraform::import(&client, org, &out, cli.output))
            }
        },
        Command::Wallet { command } => match command {
            WalletCommand::Balance { org } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref(), &client)?;
                print(reads::wallet_balance(&client, &org_id, cli.output))
            }
            WalletCommand::Ledger {
                org,
                limit,
                before,
                after,
            } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref(), &client)?;
                let page = reads::LedgerPage {
                    limit: *limit,
                    before: before.clone(),
                    after: after.clone(),
                };
                print(reads::wallet_ledger(&client, &org_id, page, cli.output))
            }
            WalletCommand::Runway { org } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref(), &client)?;
                print(reads::wallet_runway(&client, &org_id, cli.output))
            }
        },
        Command::Topup { open } => print(reads::topup(&config.base_url, *open)),
    }
}

/// One trailing newline, added here and nowhere else: the renderers
/// end their last line bare, and this closes it. A closed pipe
/// (`fluxvale … | head`) is how machine output gets consumed — not an
/// error; every other stdout failure (ENOSPC, EIO) propagates.
fn print(line: anyhow::Result<String>) -> anyhow::Result<()> {
    use std::io::Write as _;
    let text = line?;
    let mut stdout = std::io::stdout().lock();
    match writeln!(stdout, "{text}").and_then(|()| stdout.flush()) {
        Err(err) if err.kind() == std::io::ErrorKind::BrokenPipe => Ok(()),
        other => other.map_err(Into::into),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::CommandFactory as _;

    fn parse(args: &[&str]) -> Cli {
        Cli::try_parse_from(std::iter::once("fluxvale").chain(args.iter().copied())).unwrap()
    }

    #[test]
    fn cli_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn the_whole_tree_parses() {
        assert!(matches!(
            parse(&["auth", "login"]).command,
            Command::Auth {
                command: AuthCommand::Login {
                    scopes: None,
                    no_open: false
                }
            }
        ));
        match parse(&["auth", "login", "--scopes", "a:b,c:d", "--no-open"]).command {
            Command::Auth {
                command: AuthCommand::Login { scopes, no_open },
            } => {
                assert_eq!(scopes.as_deref(), Some("a:b,c:d"));
                assert!(no_open);
            }
            other => panic!("wrong: {other:?}"),
        }
        assert!(matches!(
            parse(&["auth", "logout"]).command,
            Command::Auth {
                command: AuthCommand::Logout
            }
        ));
        assert!(matches!(
            parse(&["auth", "status"]).command,
            Command::Auth {
                command: AuthCommand::Status
            }
        ));
        // The exec hand-off: only values after `--`, hyphens intact.
        match parse(&["auth", "exec", "--", "tofu", "plan", "-var", "x=1"]).command {
            Command::Auth {
                command: AuthCommand::Exec { command },
            } => assert_eq!(
                command,
                vec![
                    OsString::from("tofu"),
                    OsString::from("plan"),
                    OsString::from("-var"),
                    OsString::from("x=1")
                ]
            ),
            other => panic!("wrong: {other:?}"),
        }
        assert!(
            Cli::try_parse_from(["fluxvale", "auth", "exec"]).is_err(),
            "exec needs a command"
        );
        assert!(
            Cli::try_parse_from(["fluxvale", "auth", "exec", "--"]).is_err(),
            "the -- separator alone is not a command"
        );
        // The mint flags: --scopes and --ttl are required; --name is not.
        match parse(&[
            "auth",
            "token",
            "--scopes",
            "instances:read,backups:read",
            "--ttl",
            "1h",
            "--name",
            "ci",
        ])
        .command
        {
            Command::Auth {
                command: AuthCommand::Token { scopes, ttl, name },
            } => {
                assert_eq!(scopes, "instances:read,backups:read");
                assert_eq!(ttl, "1h");
                assert_eq!(name.as_deref(), Some("ci"));
            }
            other => panic!("wrong: {other:?}"),
        }
        assert!(
            Cli::try_parse_from(["fluxvale", "auth", "token", "--ttl", "1h"]).is_err(),
            "--scopes is required"
        );
        assert!(
            Cli::try_parse_from(["fluxvale", "auth", "token", "--scopes", "instances:read"])
                .is_err(),
            "--ttl is required"
        );
        assert!(matches!(parse(&["whoami"]).command, Command::Whoami));
        assert!(matches!(
            parse(&["apps", "list"]).command,
            Command::Apps {
                command: AppsCommand::List
            }
        ));
        match parse(&["apps", "show", "wordpress"]).command {
            Command::Apps {
                command: AppsCommand::Show { slug },
            } => assert_eq!(slug, "wordpress"),
            other => panic!("wrong: {other:?}"),
        }
        assert!(matches!(
            parse(&["instances", "list"]).command,
            Command::Instances {
                command: InstancesCommand::List
            }
        ));
        // status parses with and without the id.
        assert!(matches!(
            parse(&["instances", "status"]).command,
            Command::Instances {
                command: InstancesCommand::Status { instance: None }
            }
        ));
        // deploy takes the app slug + its optional resource flags; no
        // positional id — the command creates the instance.
        match parse(&[
            "instances",
            "deploy",
            "--app",
            "forgejo",
            "--name",
            "my forgejo",
            "--cpu",
            "1.5",
            "--memory-mb",
            "1024",
            "--storage-gb",
            "5",
            "--version",
            "01JVER",
            "--env",
            "API_KEY=sekrit",
            "--env",
            "TZ=UTC",
        ])
        .command
        {
            Command::Instances {
                command:
                    InstancesCommand::Deploy {
                        app,
                        name,
                        cpu,
                        memory_mb,
                        storage_gb,
                        version,
                        env,
                    },
            } => {
                assert_eq!(app, "forgejo");
                assert_eq!(name.as_deref(), Some("my forgejo"));
                assert_eq!(cpu.as_deref(), Some("1.5"));
                assert_eq!(memory_mb, Some(1024));
                assert_eq!(storage_gb, Some(5));
                assert_eq!(version.as_deref(), Some("01JVER"));
                assert_eq!(env, ["API_KEY=sekrit", "TZ=UTC"]);
            }
            other => panic!("wrong: {other:?}"),
        }
        // The bare form parses: app only, everything defaulted.
        match parse(&["instances", "deploy", "--app", "wordpress"]).command {
            Command::Instances {
                command: InstancesCommand::Deploy { app, .. },
            } => assert_eq!(app, "wordpress"),
            other => panic!("wrong: {other:?}"),
        }
        assert!(
            Cli::try_parse_from(["fluxvale", "instances", "deploy", "01ABC"]).is_err(),
            "deploy takes --app, not a positional id"
        );
        // configure takes the merge flags, both repeatable.
        match parse(&[
            "instances",
            "configure",
            "01ABC",
            "--env",
            "API_KEY=sekrit",
            "--remove",
            "OLD",
        ])
        .command
        {
            Command::Instances {
                command:
                    InstancesCommand::Configure {
                        instance,
                        env,
                        remove,
                    },
            } => {
                assert_eq!(instance, "01ABC");
                assert_eq!(env, ["API_KEY=sekrit"]);
                assert_eq!(remove, ["OLD"]);
            }
            other => panic!("wrong: {other:?}"),
        }
        // The destroy gate: --confirm parses on and off.
        match parse(&["instances", "destroy", "01ABC"]).command {
            Command::Instances {
                command: InstancesCommand::Destroy { instance, confirm },
            } => {
                assert_eq!(instance, "01ABC");
                assert!(!confirm);
            }
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["instances", "destroy", "01ABC", "--confirm"]).command {
            Command::Instances {
                command: InstancesCommand::Destroy { confirm, .. },
            } => assert!(confirm),
            other => panic!("wrong: {other:?}"),
        }
        for action in ["stop", "start"] {
            assert!(
                matches!(
                    parse(&["instances", action, "01ABC"]).command,
                    Command::Instances { .. }
                ),
                "{action} must parse"
            );
        }
        // The backups verbs parse with their arguments.
        match parse(&[
            "backups",
            "configure",
            "01ABC",
            "--endpoint",
            "https://e.example",
            "--bucket",
            "bucket",
            "--prefix",
            "a/b",
            "--access-key-id",
            "KEY",
            "--retention",
            "14",
            "--disabled",
        ])
        .command
        {
            Command::Backups {
                command:
                    BackupsCommand::Configure {
                        instance,
                        endpoint,
                        bucket,
                        prefix,
                        access_key_id,
                        retention,
                        enabled,
                        disabled,
                    },
            } => {
                assert_eq!(instance, "01ABC");
                assert_eq!(endpoint, "https://e.example");
                assert_eq!(bucket, "bucket");
                assert_eq!(prefix.as_deref(), Some("a/b"));
                assert_eq!(access_key_id, "KEY");
                assert_eq!(retention, Some(14));
                assert!(!enabled);
                assert!(disabled);
            }
            other => panic!("wrong: {other:?}"),
        }
        // Neither flag folds to the tri-state None (the payload omits
        // `enabled`).
        match parse(&[
            "backups",
            "configure",
            "i1",
            "--endpoint",
            "https://e.example",
            "--bucket",
            "bucket",
            "--access-key-id",
            "KEY",
        ])
        .command
        {
            Command::Backups {
                command:
                    BackupsCommand::Configure {
                        enabled, disabled, ..
                    },
            } => {
                assert!(!enabled);
                assert!(!disabled);
            }
            other => panic!("wrong: {other:?}"),
        }
        // The pair is exclusive.
        assert!(
            Cli::try_parse_from([
                "fluxvale",
                "backups",
                "configure",
                "i1",
                "--endpoint",
                "https://e.example",
                "--bucket",
                "bucket",
                "--access-key-id",
                "KEY",
                "--enabled",
                "--disabled",
            ])
            .is_err()
        );
        match parse(&["backups", "run", "01ABC"]).command {
            Command::Backups {
                command: BackupsCommand::Run { instance },
            } => assert_eq!(instance, "01ABC"),
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["backups", "status", "01ABC"]).command {
            Command::Backups {
                command: BackupsCommand::Status { instance },
            } => assert_eq!(instance, "01ABC"),
            other => panic!("wrong: {other:?}"),
        }
        // The restore gate: --confirm parses on and off.
        match parse(&["backups", "restore", "i1", "--from", "r9"]).command {
            Command::Backups {
                command:
                    BackupsCommand::Restore {
                        instance,
                        from,
                        confirm,
                    },
            } => {
                assert_eq!(instance, "i1");
                assert_eq!(from, "r9");
                assert!(!confirm);
            }
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["backups", "restore", "i1", "--from", "r9", "--confirm"]).command {
            Command::Backups {
                command: BackupsCommand::Restore { from, confirm, .. },
            } => {
                assert_eq!(from, "r9");
                assert!(confirm);
            }
            other => panic!("wrong: {other:?}"),
        } // The access verbs parse with their arguments.
        match parse(&["access", "status", "--org", "01JORG"]).command {
            Command::Access {
                command: AccessCommand::Status { org },
            } => assert_eq!(org.as_deref(), Some("01JORG")),
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["access", "attach", "g1", "i1"]).command {
            Command::Access {
                command: AccessCommand::Attach { gateway, instance },
            } => {
                assert_eq!(gateway, "g1");
                assert_eq!(instance, "i1");
            }
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["access", "detach", "g1", "i1"]).command {
            Command::Access {
                command: AccessCommand::Detach { gateway, instance },
            } => {
                assert_eq!(gateway, "g1");
                assert_eq!(instance, "i1");
            }
            other => panic!("wrong: {other:?}"),
        }
        // The create stub accepts (and ignores) the flag the panel's
        // flow would carry — the handler answers "use the panel".
        assert!(matches!(
            parse(&["access", "create", "--tailnet-domain", "example.ts.net"]).command,
            Command::Access {
                command: AccessCommand::Create { .. }
            }
        ));
        match parse(&["access", "resume", "g1"]).command {
            Command::Access {
                command: AccessCommand::Resume { gateway },
            } => assert_eq!(gateway, "g1"),
            other => panic!("wrong: {other:?}"),
        }
        // The Terraform import scaffold: --org is required, --out optional.
        match parse(&["terraform", "import", "--org", "acme", "--out", "infra"]).command {
            Command::Terraform {
                command: TerraformCommand::Import { org, out },
            } => {
                assert_eq!(org, "acme");
                assert_eq!(out, Some(PathBuf::from("infra")));
            }
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["terraform", "import", "--org", "acme"]).command {
            Command::Terraform {
                command: TerraformCommand::Import { out, .. },
            } => assert_eq!(out, None),
            other => panic!("wrong: {other:?}"),
        }
        assert!(
            Cli::try_parse_from(["fluxvale", "terraform", "import"]).is_err(),
            "--org is required"
        );
        for action in ["balance", "runway"] {
            assert!(
                matches!(parse(&["wallet", action]).command, Command::Wallet { .. }),
                "{action} must parse"
            );
        }
        // The ledger's flags parse, and --before/--after are exclusive.
        match parse(&["wallet", "ledger", "--org", "01JORG", "--limit", "5"]).command {
            Command::Wallet {
                command:
                    WalletCommand::Ledger {
                        org,
                        limit,
                        before,
                        after,
                    },
            } => {
                assert_eq!(org.as_deref(), Some("01JORG"));
                assert_eq!(limit, Some(5));
                assert_eq!(before, None);
                assert_eq!(after, None);
            }
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["wallet", "ledger", "--after", "CUR1"]).command {
            Command::Wallet {
                command: WalletCommand::Ledger { after, .. },
            } => assert_eq!(after.as_deref(), Some("CUR1")),
            other => panic!("wrong: {other:?}"),
        }
        assert!(
            Cli::try_parse_from([
                "fluxvale", "wallet", "ledger", "--before", "A", "--after", "B"
            ])
            .is_err()
        );
        // The wallet org flag and the topup --open flag.
        match parse(&["wallet", "balance", "--org", "01JORG"]).command {
            Command::Wallet {
                command: WalletCommand::Balance { org },
            } => assert_eq!(org.as_deref(), Some("01JORG")),
            other => panic!("wrong: {other:?}"),
        }
        match parse(&["wallet", "runway"]).command {
            Command::Wallet {
                command: WalletCommand::Runway { org },
            } => assert_eq!(org, None),
            other => panic!("wrong: {other:?}"),
        }
        assert!(matches!(
            parse(&["topup", "--open"]).command,
            Command::Topup { open: true }
        ));
        assert!(matches!(
            parse(&["topup"]).command,
            Command::Topup { open: false }
        ));
    }

    #[test]
    fn defaults_and_global_flags() {
        let cli = parse(&["whoami"]);
        assert_eq!(cli.output, Output::Table);
        assert!(cli.config.is_none());

        // Global flags work after the subcommand too.
        let cli = parse(&["whoami", "--output", "json", "--config", "/tmp/c.toml"]);
        assert_eq!(cli.output, Output::Json);
        assert_eq!(cli.config, Some(PathBuf::from("/tmp/c.toml")));
    }

    #[test]
    fn unknown_output_is_rejected() {
        let parsed = Cli::try_parse_from(["fluxvale", "whoami", "--output", "yaml"]);
        assert!(parsed.is_err());
    }
}
