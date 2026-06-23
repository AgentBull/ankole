use rlibphonenumber::{PHONE_NUMBER_UTIL, PhoneNumberFormat};

use super::{KernelError, KernelResult};

/// Parses and validates an international phone number, then returns E.164 text.
pub fn phone_normalize_e164(phone: &str) -> KernelResult<String> {
    let parsed = PHONE_NUMBER_UTIL
        .parse(phone)
        .map_err(|reason| KernelError::new(format!("invalid phone number: {reason}")))?;

    if !PHONE_NUMBER_UTIL.is_valid_number(&parsed) {
        return Err(KernelError::new("invalid phone number: not a valid number"));
    }

    Ok(PHONE_NUMBER_UTIL
        .format(&parsed, PhoneNumberFormat::E164)
        .into_owned())
}
