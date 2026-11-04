//! Binary entry: parse, dispatch, one-line errors. All logic lives in
//! the library so tests can reach it.

use clap::Parser as _;

fn main() {
    let cli = fluxvale_cli::cli::Cli::parse();
    if let Err(err) = fluxvale_cli::cli::run(&cli) {
        eprintln!("error: {err}");
        std::process::exit(1);
    }
}
