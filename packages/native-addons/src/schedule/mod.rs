use chrono::{LocalResult, TimeZone, Utc};
use chrono_tz::Tz;
use croner::Cron;
use croner::parser::{CronParser, Seconds};
use napi::bindgen_prelude::*;
use napi_derive::napi;

fn parse_tz(timezone: &str) -> Result<Tz> {
  timezone.parse::<Tz>().map_err(|_| {
    Error::new(
      Status::InvalidArg,
      format!("invalid IANA timezone: {timezone}"),
    )
  })
}

/// 5-field minute-first patterns plus an optional leading seconds field.
fn parse_cron(expression: &str) -> std::result::Result<Cron, croner::errors::CronError> {
  CronParser::builder()
    .seconds(Seconds::Optional)
    .build()
    .parse(expression)
}

/// Next cron fire time strictly after `afterMs`, evaluated inside an IANA
/// timezone so DST transitions cannot skew the schedule.
///
/// Accepts 5-field (minute-first) and 6-field (second-first) POSIX/Vixie cron
/// expressions. Returns the fire time as Unix epoch milliseconds, or null when
/// the expression never fires again.
#[napi(ts_return_type = "number | null")]
pub fn next_cron_fire(expression: String, after_ms: f64, timezone: String) -> Result<Option<i64>> {
  let tz = parse_tz(&timezone)?;
  let cron = parse_cron(&expression)
    .map_err(|e| Error::new(Status::InvalidArg, format!("invalid cron expression: {e}")))?;
  let after_utc = Utc
    .timestamp_millis_opt(after_ms as i64)
    .single()
    .ok_or_else(|| Error::new(Status::InvalidArg, "invalid afterMs timestamp".to_string()))?;
  let after_local = after_utc.with_timezone(&tz);
  match cron.find_next_occurrence(&after_local, false) {
    Ok(next) => Ok(Some(next.with_timezone(&Utc).timestamp_millis())),
    Err(_) => Ok(None),
  }
}

/// Validates a cron expression (same dialect as `nextCronFire`).
#[napi]
pub fn is_valid_cron_expression(expression: String) -> bool {
  parse_cron(&expression).is_ok()
}

/// Converts a wall-clock local time in an IANA timezone to Unix epoch
/// milliseconds, with RFC 5545-style disambiguation: ambiguous local times
/// (DST fall-back) take the earlier instant; skipped local times (DST
/// spring-forward gap) roll forward past the gap.
#[napi]
pub fn zoned_local_time_to_utc_ms(
  timezone: String,
  year: i32,
  month: u32,
  day: u32,
  hour: u32,
  minute: u32,
  second: u32,
) -> Result<i64> {
  let tz = parse_tz(&timezone)?;
  let local = chrono::NaiveDate::from_ymd_opt(year, month, day)
    .and_then(|date| date.and_hms_opt(hour, minute, second))
    .ok_or_else(|| {
      Error::new(
        Status::InvalidArg,
        format!("invalid local time: {year}-{month:02}-{day:02} {hour:02}:{minute:02}:{second:02}"),
      )
    })?;
  let resolved = match tz.from_local_datetime(&local) {
    LocalResult::Single(dt) => dt,
    LocalResult::Ambiguous(earlier, _later) => earlier,
    LocalResult::None => {
      // Inside a spring-forward gap: interpret as one hour later, which lands
      // just past the transition (RFC 5545 "compatible" behavior).
      let shifted = local + chrono::Duration::hours(1);
      tz.from_local_datetime(&shifted).earliest().ok_or_else(|| {
        Error::new(
          Status::InvalidArg,
          format!("unresolvable local time in {timezone}: {local}"),
        )
      })?
    }
  };
  Ok(resolved.with_timezone(&Utc).timestamp_millis())
}
