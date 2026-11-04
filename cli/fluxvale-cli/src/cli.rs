//! The command tree (clap derive) + dispatch. Handlers live in their
//! own modules by slice: the read commands in [`crate::reads`] (T4),
//! the backups + access writes in [`crate::writes`] (T6); device-flow
//! login (T5) and the instance lifecycle writes land later — their
//! arms still dispatch to `not_yet`.

use crate::config::{self, Config};
use crate::reads;
use crate::token::TokenStore;
use crate::writes::{self, ConfigureBackup};
use clap::{Parser, Subcommand, ValueEnum};
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
    /// Sign in to FluxVale
    Login,
    /// Sign out and remove the stored token
    Logout,
    /// Show whether you are signed in
    Status,
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
    /// Deploy an instance
    Deploy {
        /// The instance ID
        instance: String,
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
    /// Destroy an instance
    Destroy {
        /// The instance ID
        instance: String,
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
pub enum WalletCommand {
    /// Show your wallet balance
    Balance {
        /// The organization ID (default: organization_id from the config file)
        #[arg(long, value_name = "ID")]
        org: Option<String>,
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
            AuthCommand::Login => not_yet("auth login"),
            AuthCommand::Logout => not_yet("auth logout"),
            AuthCommand::Status => auth_status(&config),
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
            InstancesCommand::Deploy { .. } => not_yet("instances deploy"),
            InstancesCommand::Stop { .. } => not_yet("instances stop"),
            InstancesCommand::Start { .. } => not_yet("instances start"),
            InstancesCommand::Destroy { .. } => not_yet("instances destroy"),
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
                let org_id = reads::resolve_org(&config, org.as_deref())?;
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
        Command::Wallet { command } => match command {
            WalletCommand::Balance { org } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref())?;
                print(reads::wallet_balance(&client, &org_id, cli.output))
            }
            WalletCommand::Runway { org } => {
                let (client, _) = reads::read_client(&config)?;
                let org_id = reads::resolve_org(&config, org.as_deref())?;
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

/// `auth status` runs locally: config + stored token, no network.
fn auth_status(config: &Config) -> anyhow::Result<()> {
    let store = TokenStore::at(TokenStore::default_dir()?);
    let host = config::host_from_base_url(&config.base_url);
    match store.load(&host)? {
        Some((token, location)) => {
            println!(
                "Signed in to {} ({}, stored in {})",
                config.base_url,
                token.mask(),
                location
            );
        }
        None => {
            println!("Not signed in. Run `fluxvale auth login` to sign in.");
        }
    }
    Ok(())
}

fn not_yet(command: &str) -> anyhow::Result<()> {
    Err(anyhow::anyhow!(
        "`fluxvale {command}` is not implemented yet"
    ))
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
                command: AuthCommand::Login
            }
        ));
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
        match parse(&["instances", "deploy", "01ABC"]).command {
            Command::Instances {
                command: InstancesCommand::Deploy { instance },
            } => {
                assert_eq!(instance, "01ABC")
            }
            other => panic!("wrong: {other:?}"),
        }
        for action in ["stop", "start", "destroy"] {
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
        }
        // The access verbs parse with their arguments.
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
        for action in ["balance", "runway"] {
            assert!(
                matches!(parse(&["wallet", action]).command, Command::Wallet { .. }),
                "{action} must parse"
            );
        }
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

    #[test]
    fn unimplemented_commands_error_cleanly() {
        let err = not_yet("instances deploy").unwrap_err();
        assert_eq!(
            err.to_string(),
            "`fluxvale instances deploy` is not implemented yet"
        );
    }
}
