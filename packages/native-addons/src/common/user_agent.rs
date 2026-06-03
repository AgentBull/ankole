use napi::bindgen_prelude::*;
use napi_derive::napi;
use woothee::parser::Parser;

/// Parsed User-Agent struct
#[napi(object)]
pub struct ParsedUA {
  pub name: String,
  pub category: String,
  pub os: String,
  pub os_version: String,
  pub browser_type: String,
  pub version: String,
  pub vendor: String,
}

/// convert WootheeResult to ParsedUA
impl From<woothee::parser::WootheeResult<'_>> for ParsedUA {
  fn from(v: woothee::parser::WootheeResult) -> Self {
    Self {
      name: v.name.to_string(),
      category: v.category.to_string(),
      os: v.os.to_string(),
      os_version: v.os_version.to_string(),
      browser_type: v.browser_type.to_string(),
      version: v.version.to_string(),
      vendor: v.vendor.to_string(),
    }
  }
}

/// User-Agent Parser
/// @param ua user-agent string
#[napi(js_name = "uaParser")]
pub fn parse(ua: String) -> Result<ParsedUA> {
  let parser = Parser::new();
  match parser.parse(&ua) {
    None => Err(Error::new(
      Status::GenericFailure,
      format!("Invalid user agent: {}", ua),
    )),
    Some(r) => Ok(ParsedUA::from(r)),
  }
}
