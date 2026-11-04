//! The command tree (clap derive) + dispatch. Every handler lands in
//! its own slice (T4/T5/T6); this build carries the tree, the global
//! flags, and the locally-implementable `auth status`.

use crate::config::{self, Config};
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
    Topup,
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
    /// Show one instance's status
    Status {
        /// The instance ID
        instance: String,
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
    Balance,
    /// Show how long your balance lasts at current spend
    Runway,
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
        Command::Whoami => not_yet("whoami"),
        Command::Apps { command } => match command {
            AppsCommand::List => not_yet("apps list"),
            AppsCommand::Show { .. } => not_yet("apps show"),
        },
        Command::Instances { command } => match command {
            InstancesCommand::List => not_yet("instances list"),
            InstancesCommand::Status { .. } => not_yet("instances status"),
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
            WalletCommand::Balance => not_yet("wallet balance"),
            WalletCommand::Runway => not_yet("wallet runway"),
        },
        Command::Topup => not_yet("topup"),
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
        match parse(&["instances", "deploy", "01ABC"]).command {
            Command::Instances {
                command: InstancesCommand::Deploy { instance },
            } => {
                assert_eq!(instance, "01ABC")
            }
            other => panic!("wrong: {other:?}"),
        }
        for action in ["status", "stop", "start", "destroy"] {
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
        assert!(matches!(parse(&["topup"]).command, Command::Topup));
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
