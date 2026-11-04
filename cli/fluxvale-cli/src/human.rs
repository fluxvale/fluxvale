//! Tiny humanizers for the read commands: integer-only money, the
//! runway projection's words, and relative timestamps. No chrono —
//! timestamps arrive as ISO-8601 strings over the wire and are parsed
//! with std math only (ADR-0019 Am. 3: a thin client; the values'
//! meanings stay server-side, the rendering is presentation).

use serde_json::Value;

/// Whole cents -> `$X.YZ` — integer math only, floats never touch
/// money. Negative balances render `-$X.YZ`.
pub fn money(cents: i64) -> String {
    let sign = if cents < 0 { "-" } else { "" };
    let abs = cents.unsigned_abs();
    format!("{sign}${}.{:02}", abs / 100, abs % 100)
}

/// Micro-cents per hour -> `$X.YYY/hr`. Three decimals on purpose: the
/// burn rate's meaningful digits live below the cent (µ¢ = 10⁻⁶ USD;
/// 1¢ = 10_000 µ¢). Integer math: thousandths of a dollar = µ¢ / 1000.
pub fn money_micro_per_hour(micro_cents_per_hour: i64) -> String {
    let sign = if micro_cents_per_hour < 0 { "-" } else { "" };
    let thousandths = micro_cents_per_hour.unsigned_abs() / 1000;
    format!("{sign}${}.{:03}/hr", thousandths / 1000, thousandths % 1000)
}

/// The runway projection's `runway_hours` value: the server's
/// "infinity" atom serializes as the string `"infinity"` and reads as
/// "∞ (no burn)"; a finite float goes through [`duration_hours`].
/// Anything else (absent, unexpected shape) reads "-".
pub fn runway_hours(value: &Value) -> String {
    match value {
        Value::String(s) if s == "infinity" => "∞ (no burn)".to_string(),
        Value::Number(_) => match value.as_f64() {
            Some(hours) => duration_hours(hours),
            None => "-".to_string(),
        },
        _ => "-".to_string(),
    }
}

/// Hours -> `3.4h` under a day, `17d 4h` past it. A negative value
/// (an overdrawn wallet's projection) keeps the sign.
pub fn duration_hours(hours: f64) -> String {
    let sign = if hours < 0.0 { "-" } else { "" };
    let hours = hours.abs();
    if hours < 24.0 {
        format!("{sign}{hours:.1}h")
    } else {
        let whole = hours as u64;
        format!("{sign}{}d {}h", whole / 24, whole % 24)
    }
}

/// Parse the wire's ISO-8601 timestamp — `2026-11-04T12:34:56.123456Z`
/// shape; the fraction is ignored, a `Z` or `±HH:MM` offset is applied.
/// `None` when it doesn't parse: callers render "-" instead of guessing.
pub fn parse_iso8601(raw: &str) -> Option<i64> {
    let (date, rest) = raw.trim().split_once(['T', ' '])?;
    let rest = rest.trim_end_matches('Z');
    let (time, offset_secs) = split_offset(rest);
    let time = time.split('.').next().unwrap_or(time);
    let mut clock = time.split(':');
    let hour: i64 = clock.next()?.parse().ok()?;
    let minute: i64 = clock.next()?.parse().ok()?;
    let second: i64 = clock.next().unwrap_or("0").parse().ok()?;
    let (year, month, day) = split_date(date)?;
    Some(
        days_from_civil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
            - offset_secs,
    )
}

/// A wire timestamp as a relative human string ("3h ago"); "-" for
/// absent or unparseable. Clock skew (a future stamp) reads "just now".
pub fn relative(raw: Option<&str>, now_secs: i64) -> String {
    let Some(raw) = raw else {
        return "-".to_string();
    };
    match parse_iso8601(raw) {
        Some(then) => ago(now_secs - then),
        None => "-".to_string(),
    }
}

fn ago(delta_secs: i64) -> String {
    let minutes = delta_secs / 60;
    match minutes {
        _ if delta_secs < 60 => "just now".to_string(),
        0..60 => format!("{minutes}m ago"),
        _ if minutes < 24 * 60 => format!("{}h ago", minutes / 60),
        _ => format!("{}d ago", minutes / (24 * 60)),
    }
}

/// Trailing `±HH:MM`/`±HHMM` offset -> seconds east of UTC.
fn split_offset(rest: &str) -> (&str, i64) {
    let bytes = rest.as_bytes();
    let Some(pos) = bytes
        .iter()
        .position(|b| *b == b'+' || *b == b'-')
        .filter(|pos| *pos == 8)
    else {
        return (rest, 0);
    };
    let (time, offset) = rest.split_at(pos);
    let sign = if offset.starts_with('-') { -1 } else { 1 };
    let digits: String = offset[1..].chars().filter(|c| c.is_ascii_digit()).collect();
    let value = digits.parse::<i64>().unwrap_or(0);
    let (hours, minutes) = if digits.len() > 2 {
        (value / 100, value % 100)
    } else {
        (value, 0)
    };
    (time, sign * (hours * 3600 + minutes * 60))
}

/// `YYYY-MM-DD` -> (year, month, day).
fn split_date(date: &str) -> Option<(i64, i64, i64)> {
    let mut parts = date.split('-');
    let year = parts.next()?.parse().ok()?;
    let month = parts.next()?.parse().ok()?;
    let day = parts.next()?.parse().ok()?;
    Some((year, month, day))
}

/// Days from 1970-01-01 (Howard Hinnant's `days_from_civil`) — the
/// std-only substitute for a date library.
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month_of_era = (month + 9) % 12;
    let day_of_year = (153 * month_of_era + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146097 + day_of_era - 719468
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn money_is_integer_math() {
        assert_eq!(money(0), "$0.00");
        assert_eq!(money(1), "$0.01");
        assert_eq!(money(1900), "$19.00");
        assert_eq!(money(123456), "$1234.56");
        assert_eq!(money(-1), "-$0.01");
        assert_eq!(money(-1900), "-$19.00");
        assert_eq!(money(i64::MIN), "-$92233720368547758.08");
    }

    #[test]
    fn burn_rates_read_below_the_cent() {
        assert_eq!(money_micro_per_hour(0), "$0.000/hr");
        // 5_016 µ¢/h = $0.005/hr — sub-cent precision survives.
        assert_eq!(money_micro_per_hour(5_016), "$0.005/hr");
        assert_eq!(money_micro_per_hour(10_000), "$0.010/hr");
        assert_eq!(money_micro_per_hour(1_000_000), "$1.000/hr");
        assert_eq!(money_micro_per_hour(1_234_567), "$1.234/hr");
    }

    #[test]
    fn runway_infinity_reads_verbatim() {
        assert_eq!(runway_hours(&json!("infinity")), "∞ (no burn)");
        assert_eq!(runway_hours(&json!(412.3)), "17d 4h");
        assert_eq!(runway_hours(&json!(null)), "-");
        assert_eq!(runway_hours(&json!(3.5)), "3.5h");
    }

    #[test]
    fn durations_flip_to_days_past_a_day() {
        assert_eq!(duration_hours(0.0), "0.0h");
        assert_eq!(duration_hours(3.44), "3.4h");
        // Just under a day displays under a day (24h rounds to "1d 0h").
        assert_eq!(duration_hours(23.4), "23.4h");
        assert_eq!(duration_hours(24.0), "1d 0h");
        assert_eq!(duration_hours(412.3), "17d 4h");
        assert_eq!(duration_hours(-48.0), "-2d 0h");
    }

    #[test]
    fn iso8601_parses_z_fraction_and_offsets() {
        // 2026-11-05T00:00:00Z = 1793836800
        assert_eq!(parse_iso8601("2026-11-05T00:00:00Z"), Some(1793836800));
        assert_eq!(
            parse_iso8601("2026-11-05T00:00:00.123456Z"),
            Some(1793836800)
        );
        assert_eq!(parse_iso8601("2026-11-05T02:00:00+02:00"), Some(1793836800));
        assert_eq!(parse_iso8601("2026-11-04T22:00:00-0200"), Some(1793836800));
        // Leap years and era math: 1970-01-01T00:00:00Z is epoch zero.
        assert_eq!(parse_iso8601("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso8601("2024-02-29T12:00:00Z"), Some(1709208000));
        assert_eq!(parse_iso8601("nonsense"), None);
        assert_eq!(parse_iso8601("2026-11-05"), None);
        assert_eq!(parse_iso8601(""), None);
    }

    #[test]
    fn relative_steps_through_the_units() {
        let now = parse_iso8601("2026-11-05T00:00:00Z").unwrap();
        assert_eq!(relative(Some("2026-11-05T00:00:30Z"), now), "just now");
        assert_eq!(relative(Some("2026-11-04T23:58:00Z"), now), "2m ago");
        assert_eq!(relative(Some("2026-11-04T21:00:00Z"), now), "3h ago");
        assert_eq!(relative(Some("2026-11-01T00:00:00Z"), now), "4d ago");
        // Future stamps (clock skew) read as "just now", not negative.
        assert_eq!(relative(Some("2026-11-05T00:10:00Z"), now), "just now");
        assert_eq!(relative(None, now), "-");
        assert_eq!(relative(Some("garbage"), now), "-");
    }

    #[test]
    fn year_rollover_counts_days_across_months() {
        let now = parse_iso8601("2026-01-02T00:00:00Z").unwrap();
        assert_eq!(relative(Some("2025-12-31T00:00:00Z"), now), "2d ago");
    }
}
