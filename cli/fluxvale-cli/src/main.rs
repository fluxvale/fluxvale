//! Canary binary — prints the canary so release builds have something
//! to run.

fn main() {
    println!("{} canary", fluxvale_cli::canary());
}
