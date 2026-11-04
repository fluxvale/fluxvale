//! The command tree (clap derive) + dispatch. Handlers live in their
//! own modules by slice: the read commands in [`crate::reads`] (T4);
//! device-flow login (T5) and the write commands (T6) land later —
//! their arms still dispatch to `not_yet`.

use crate::config::{self, Config};
use crate::reads;
use crate::token::TokenStore;
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
    /// Configure backup settings for an instance
    Configure,
    /// Run a backup now
    Run,
    /// Show backup status
    Status,
    /// Restore an instance from a backup
    Restore,
}

#[derive(Debug, Subcommand)]
pub enum AccessCommand {
    /// Show private access status
    Status,
    /// Attach an instance to a private access gateway
    Attach,
    /// Detach an instance from a private access gateway
    Detach,
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
            BackupsCommand::Configure => not_yet("backups configure"),
            BackupsCommand::Run => not_yet("backups run"),
            BackupsCommand::Status => not_yet("backups status"),
            BackupsCommand::Restore => not_yet("backups restore"),
        },
        Command::Access { command } => match command {
            AccessCommand::Status => not_yet("access status"),
            AccessCommand::Attach => not_yet("access attach"),
            AccessCommand::Detach => not_yet("access detach"),
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
/// error to panic on; write failures end the command quietly.
fn print(line: anyhow::Result<String>) -> anyhow::Result<()> {
    use std::io::Write as _;
    let text = line?;
    let mut stdout = std::io::stdout().lock();
    let _ = writeln!(stdout, "{text}");
    let _ = stdout.flush();
    Ok(())
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
        for action in ["configure", "run", "status", "restore"] {
            assert!(
                matches!(parse(&["backups", action]).command, Command::Backups { .. }),
                "{action} must parse"
            );
        }
        for action in ["status", "attach", "detach"] {
            assert!(
                matches!(parse(&["access", action]).command, Command::Access { .. }),
                "{action} must parse"
            );
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
