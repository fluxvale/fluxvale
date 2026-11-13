//! `terraform import` (#763): discover an organization's live estate
//! and write the import scaffold. The rendering lives in the shared
//! `fluxvale_api::terraform` module so the CLI and the MCP tool emit
//! byte-identical files; this module only owns the filesystem and the
//! terminal presentation.

use crate::cli::Output;
use crate::render::to_pretty;
use fluxvale_api::ApiClient;
use fluxvale_api::terraform::{Bundle, bundle};
use serde_json::json;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};

/// Fetch the bundle and write its files into `out`. Refuses to clobber
/// an existing file: the scaffold's names are conventional Terraform
/// module names, and silently replacing a hand-edited `versions.tf` or
/// a repository README would be destructive.
pub fn import(client: &ApiClient, org: &str, out: &Path, output: Output) -> anyhow::Result<String> {
    let bundle = bundle(client, org)?;
    write_bundle(out, &bundle)?;
    Ok(render(out, &bundle, output))
}

fn write_bundle(out: &Path, bundle: &Bundle) -> anyhow::Result<()> {
    fs::create_dir_all(out)?;
    let mut written: Vec<PathBuf> = Vec::new();
    for file in &bundle.files {
        let path = out.join(file.name);
        let mut handle = match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(handle) => handle,
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {
                remove_written(&written);
                anyhow::bail!(
                    "{} already exists — choose an empty --out directory (or move the old file first)",
                    path.display()
                );
            }
            Err(err) => {
                remove_written(&written);
                return Err(err.into());
            }
        };
        if let Err(err) = handle
            .write_all(file.contents.as_bytes())
            .and_then(|()| handle.flush())
        {
            drop(handle);
            let _ = fs::remove_file(&path);
            remove_written(&written);
            return Err(err.into());
        }
        written.push(path);
    }
    Ok(())
}

/// A failed run must not leave half a scaffold behind: the next run
/// refuses an existing file, so clean up only what THIS run created.
fn remove_written(paths: &[PathBuf]) {
    for path in paths {
        let _ = fs::remove_file(path);
    }
}

fn render(out: &Path, bundle: &Bundle, output: Output) -> String {
    match output {
        Output::Table => {
            let names = bundle
                .files
                .iter()
                .map(|file| file.name)
                .collect::<Vec<_>>()
                .join(", ");
            let next = if out == Path::new(".") {
                "tofu init && tofu plan -generate-config-out=generated.tf && tofu apply".to_string()
            } else {
                format!(
                    "cd {} && tofu init && tofu plan -generate-config-out=generated.tf && tofu apply",
                    out.display()
                )
            };
            format!(
                "terraform import scaffold for {}\n\
                 wrote {names} to {}\n\
                 next: {next}",
                bundle.organization,
                out.display()
            )
        }
        Output::Json => to_pretty(&json!({
            "organization": bundle.organization,
            "directory": out.display().to_string(),
            "files": bundle.files.iter().map(|file| file.name).collect::<Vec<_>>(),
        })),
    }
}

/// The default `--out`: the current directory.
pub fn default_out() -> PathBuf {
    PathBuf::from(".")
}

#[cfg(test)]
mod tests {
    use super::*;
    use fluxvale_api::terraform::GeneratedFile;

    fn bundle() -> Bundle {
        Bundle {
            organization: "acme".into(),
            files: vec![
                GeneratedFile {
                    name: "versions.tf",
                    contents: "terraform {}\n".into(),
                },
                GeneratedFile {
                    name: "imports.tf",
                    contents: "import {}\n".into(),
                },
                GeneratedFile {
                    name: "README.md",
                    contents: "# scaffold\n".into(),
                },
            ],
        }
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "fluxvale-cli-terraform-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn writes_the_three_files_and_reports_them() {
        let out = temp_dir();
        let rendered = import_rendered_for_test(&out);
        assert!(rendered.contains("wrote versions.tf, imports.tf, README.md"));
        assert_eq!(
            fs::read_to_string(out.join("versions.tf")).unwrap(),
            "terraform {}\n"
        );
        assert_eq!(
            fs::read_to_string(out.join("imports.tf")).unwrap(),
            "import {}\n"
        );
        assert_eq!(
            fs::read_to_string(out.join("README.md")).unwrap(),
            "# scaffold\n"
        );
    }

    #[test]
    fn refuses_to_clobber_an_existing_file() {
        let out = temp_dir();
        fs::write(out.join("imports.tf"), "hand edited\n").unwrap();
        let err = write_bundle(&out, &bundle()).unwrap_err().to_string();
        assert!(err.contains("already exists"), "{err}");
        // Nothing was written when the preflight failed.
        assert_eq!(
            fs::read_to_string(out.join("imports.tf")).unwrap(),
            "hand edited\n"
        );
        assert!(!out.join("versions.tf").exists());
    }

    #[test]
    fn the_default_directory_does_not_print_a_pointless_cd() {
        let rendered = render(Path::new("."), &bundle(), Output::Table);
        assert!(rendered.contains("next: tofu init &&"), "{rendered}");
        assert!(!rendered.contains("cd ."), "{rendered}");
        let elsewhere = render(Path::new("/tmp/scaffold"), &bundle(), Output::Table);
        assert!(
            elsewhere.contains("next: cd /tmp/scaffold && tofu init &&"),
            "{elsewhere}"
        );
    }

    #[test]
    fn a_write_failure_cleans_up_what_this_run_created() {
        let out = temp_dir();
        let blocker = out.join("blocker");
        fs::write(&blocker, "not a directory").unwrap();
        let err = write_bundle(&blocker, &bundle()).unwrap_err();
        assert!(!err.to_string().is_empty());
        // The blocker file is untouched; no scaffold leaked into its parent.
        assert_eq!(fs::read_to_string(&blocker).unwrap(), "not a directory");
        assert!(!out.join("versions.tf").exists());
    }

    #[test]
    fn json_output_names_the_files_and_directory() {
        let out = temp_dir();
        let rendered = render(&out, &bundle(), Output::Json);
        let value: serde_json::Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(value["organization"], "acme");
        assert_eq!(value["files"][1], "imports.tf");
        assert_eq!(value["directory"], out.display().to_string());
    }

    fn import_rendered_for_test(out: &Path) -> String {
        write_bundle(out, &bundle()).unwrap();
        render(out, &bundle(), Output::Table)
    }
}
