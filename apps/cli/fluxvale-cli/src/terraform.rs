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
                    "{} already exists — choose an empty --out directory, e.g. --out fluxvale-import (or move the old file first)",
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
            let next = if is_current_dir(out) {
                "tofu init && tofu plan -generate-config-out=generated.tf && tofu apply".to_string()
            } else {
                format!(
                    "cd {} && tofu init && tofu plan -generate-config-out=generated.tf && tofu apply",
                    shell_quote(&out.display().to_string())
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

fn is_current_dir(path: &Path) -> bool {
    path == Path::new(".") || path.as_os_str() == "./"
}

/// A single shell word for the printed next-step command. Paths with
/// spaces or shell metacharacters get single-quoted; the embedded-quote
/// form is the POSIX `'\''` dance.
fn shell_quote(value: &str) -> String {
    let safe = value
        .chars()
        .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.' | '/'));
    if safe {
        value.to_string()
    } else {
        format!("'{}'", value.replace('\'', "'\\''"))
    }
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
    fn paths_with_spaces_are_quoted_in_the_next_step() {
        let rendered = render(Path::new("infra/my org"), &bundle(), Output::Table);
        assert!(
            rendered.contains("next: cd 'infra/my org' && tofu init &&"),
            "{rendered}"
        );
        assert_eq!(shell_quote("plain/path"), "plain/path");
        assert_eq!(shell_quote("a'b"), "'a'\\''b'");
    }

    #[test]
    fn the_default_out_is_the_current_directory() {
        assert_eq!(default_out(), PathBuf::from("."));
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
    fn a_mid_write_failure_removes_the_files_this_run_created() {
        let out = temp_dir();
        // A directory where the second file belongs makes the open fail
        // after versions.tf was already written.
        fs::create_dir(out.join("imports.tf")).unwrap();
        let err = write_bundle(&out, &bundle()).unwrap_err();
        assert!(!err.to_string().is_empty());
        assert!(!out.join("versions.tf").exists());
        assert!(out.join("imports.tf").is_dir());
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

    #[test]
    fn import_discovers_then_writes_the_scaffold() {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        let responses = vec![
            (200, r#"{"data":[{"type":"organization","id":"org1","attributes":{"slug":"acme","name":"Acme"}}]}"#.to_string()),
            (200, r#"{"data":[{"type":"instance","id":"i1","attributes":{"name":"Web","slug":"web-a1b2","organization_id":"org1","status":"running"}}]}"#.to_string()),
            (404, "{}".to_string()),
            (404, "{}".to_string()),
            (404, "{}".to_string()),
            (200, r#"{"data":[]}"#.to_string()),
        ];
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base_url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().unwrap();
                let mut head = String::new();
                let mut buf = [0u8; 4096];
                while !head.contains("\r\n\r\n") {
                    let read = stream.read(&mut buf).unwrap();
                    if read == 0 {
                        break;
                    }
                    head.push_str(&String::from_utf8_lossy(&buf[..read]));
                }
                let reason = if status == 200 { "OK" } else { "Not Found" };
                let response = format!(
                    "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = stream.write_all(response.as_bytes());
            }
        });
        let client = ApiClient::new(&base_url, fluxvale_api::Token::new("fvpat_test"));
        let out = temp_dir();
        let rendered = import(&client, "acme", &out, Output::Table).unwrap();
        assert!(rendered.contains("terraform import scaffold for acme"));
        assert!(
            fs::read_to_string(out.join("imports.tf"))
                .unwrap()
                .contains("fluxvale_instance.web_a1b2")
        );
        assert!(
            fs::read_to_string(out.join("README.md"))
                .unwrap()
                .contains("**Acme (acme)**")
        );
    }
}
