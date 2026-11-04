//! Output rendering for the read commands: ONE data shape per command,
//! TWO renderers — `--output table` (hand-aligned columns; no table
//! crate) and `--output json` (the raw JSON:API-unwrapped attributes,
//! verbatim — derived display columns never leak into it).

use crate::cli::Output;
use serde_json::Value;

/// One cell's human form: absent or null reads "-", strings print
/// bare, the rest print as their plain JSON selves.
pub fn cell(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => "-".to_string(),
        Some(Value::String(s)) => s.clone(),
        Some(other) => other.to_string(),
    }
}

/// A boolean attribute's table form.
pub fn yes_no(value: Option<&Value>) -> String {
    match value.and_then(Value::as_bool) {
        Some(true) => "yes".to_string(),
        Some(false) => "no".to_string(),
        None => "-".to_string(),
    }
}

/// A list command's data: a deliberate column order, human cells plus
/// the raw attrs the JSON renderer prints verbatim.
pub struct Rows {
    headers: &'static [&'static str],
    rows: Vec<(Vec<String>, Value)>,
    empty_line: &'static str,
}

impl Rows {
    pub fn new(headers: &'static [&'static str], empty_line: &'static str) -> Self {
        Rows {
            headers,
            rows: Vec::new(),
            empty_line,
        }
    }

    /// One row: display cells aligned with the headers, plus the raw
    /// (unwrapped) attribute map JSON mode prints.
    pub fn push(&mut self, cells: Vec<String>, attrs: Value) {
        debug_assert_eq!(
            cells.len(),
            self.headers.len(),
            "cells must fill every column"
        );
        self.rows.push((cells, attrs));
    }

    pub fn render(&self, output: Output) -> String {
        match output {
            Output::Table => {
                if self.rows.is_empty() {
                    return self.empty_line.to_string();
                }
                let mut grid: Vec<Vec<&str>> = vec![self.headers.to_vec()];
                grid.extend(
                    self.rows
                        .iter()
                        .map(|(cells, _)| cells.iter().map(String::as_str).collect()),
                );
                aligned(&grid)
            }
            Output::Json => {
                let attrs: Vec<&Value> = self.rows.iter().map(|(_, attrs)| attrs).collect();
                to_pretty(&attrs)
            }
        }
    }
}

/// A show command's data: label/value lines plus the raw attrs map.
pub struct Detail {
    fields: Vec<(String, String)>,
    attrs: Value,
}

impl Detail {
    pub fn new(attrs: Value) -> Self {
        Detail {
            fields: Vec::new(),
            attrs,
        }
    }

    pub fn field(&mut self, label: &str, value: String) {
        self.fields.push((label.to_string(), value));
    }

    pub fn render(&self, output: Output) -> String {
        match output {
            Output::Table => {
                let grid: Vec<Vec<&str>> = self
                    .fields
                    .iter()
                    .map(|(label, value)| vec![label.as_str(), value.as_str()])
                    .collect();
                aligned(&grid)
            }
            Output::Json => to_pretty(&self.attrs),
        }
    }
}

/// Width = the longest cell per column; two spaces between columns; no
/// trailing padding. Widths are CHARACTER counts: wide glyphs (CJK)
/// occupy two terminal columns and will misalign — a real fix is a
/// unicode-width dep, not worth it for this table's data yet.
fn aligned(grid: &[Vec<&str>]) -> String {
    let columns = grid.iter().map(Vec::len).max().unwrap_or(0);
    let mut widths = vec![0usize; columns];
    for row in grid {
        for (i, cell) in row.iter().enumerate() {
            widths[i] = widths[i].max(cell.chars().count());
        }
    }
    let mut out = String::new();
    for row in grid {
        let mut line = String::new();
        for (i, cell) in row.iter().enumerate() {
            if i > 0 {
                line.push_str("  ");
            }
            line.push_str(cell);
            if i + 1 < row.len() {
                line.push_str(&" ".repeat(widths[i] - cell.chars().count()));
            }
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(line.trim_end());
    }
    out
}

/// `serde_json` can't fail on a `Value`; the expect documents that
/// instead of propagating an impossible error.
pub(crate) fn to_pretty(value: &impl serde::Serialize) -> String {
    serde_json::to_string_pretty(value).expect("serializing a JSON value cannot fail")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cells_render_by_shape() {
        assert_eq!(cell(None), "-");
        assert_eq!(cell(Some(&Value::Null)), "-");
        assert_eq!(cell(Some(&json!("web-01"))), "web-01");
        assert_eq!(cell(Some(&json!(true))), "true");
        assert_eq!(cell(Some(&json!(512))), "512");
        assert_eq!(cell(Some(&json!([1, 2]))), "[1,2]");
    }

    #[test]
    fn booleans_read_yes_no_or_dash() {
        assert_eq!(yes_no(Some(&json!(true))), "yes");
        assert_eq!(yes_no(Some(&json!(false))), "no");
        assert_eq!(yes_no(None), "-");
        assert_eq!(yes_no(Some(&Value::Null)), "-");
    }

    #[test]
    fn rows_align_columns_and_skip_trailing_padding() {
        let mut rows = Rows::new(&["NAME", "STATUS"], "no rows");
        rows.push(
            vec!["web".into(), "running".into()],
            json!({"name": "web", "status": "running"}),
        );
        rows.push(
            vec!["db-2".into(), "stopped".into()],
            json!({"name": "db-2", "status": "stopped"}),
        );
        assert_eq!(
            rows.render(Output::Table),
            "NAME  STATUS\nweb   running\ndb-2  stopped"
        );
        assert_eq!(
            rows.render(Output::Json),
            pretty_json(&[
                json!({"name": "web", "status": "running"}),
                json!({"name": "db-2", "status": "stopped"}),
            ])
        );
    }

    #[test]
    fn empty_list_reads_as_a_sentence_in_table_mode_and_array_in_json() {
        let rows = Rows::new(&["NAME"], "no instances yet");
        assert_eq!(rows.render(Output::Table), "no instances yet");
        assert_eq!(rows.render(Output::Json), "[]");
    }

    #[test]
    fn detail_pairs_align_and_json_is_the_raw_map() {
        let mut detail = Detail::new(json!({"slug": "web-01", "status": "running"}));
        detail.field("slug", "web-01".into());
        detail.field("status", "running".into());
        assert_eq!(
            detail.render(Output::Table),
            "slug    web-01\nstatus  running"
        );
        assert_eq!(
            detail.render(Output::Json),
            pretty_json(&json!({"slug": "web-01", "status": "running"}))
        );
    }

    #[test]
    fn multibyte_cells_count_characters_not_bytes() {
        // NB: char-count widths, not terminal columns — wide glyphs
        // misalign (see `aligned`'s doc); this pins no-panic behavior.
        let mut rows = Rows::new(&["NAME", "STATUS"], "no rows");
        rows.push(
            vec!["日本語".into(), "running".into()],
            json!({"name": "日本語"}),
        );
        rows.push(vec!["web".into(), "stopped".into()], json!({"name": "web"}));
        assert_eq!(
            rows.render(Output::Table),
            "NAME  STATUS\n日本語   running\nweb   stopped"
        );
    }

    fn pretty_json(value: &impl serde::Serialize) -> String {
        serde_json::to_string_pretty(value).unwrap()
    }
}
