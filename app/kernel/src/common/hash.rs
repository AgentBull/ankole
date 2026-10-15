use hashcrew::xxhash::xxh3_128;

use crate::common::KernelResult;
use crate::common::crypto::parse_hex_32;

/// Change detection only. This is not a security digest or provenance checksum.
pub fn xxh3_128_hex(input: &[u8]) -> String {
    format!("{:032x}", xxh3_128(input))
}

/// A salt is a 64-character hex keyed-hash key, so the JS and Elixir APIs share one key form.
pub fn generic_hash(data: &[u8], salt: Option<&str>) -> KernelResult<String> {
    match salt {
        Some(salt) => {
            let key = parse_hex_32(salt, "salt")?;
            Ok(blake3::keyed_hash(&key, data).to_hex().to_string())
        }
        None => Ok(blake3::hash(data).to_hex().to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::xxh3_128_hex;

    #[test]
    fn xxh3_128_hex_preserves_fingerprints_at_length_boundaries() {
        let input: Vec<u8> = (0..65_536)
            .map(|index| (index as u8).wrapping_mul(37).wrapping_add(11))
            .collect();

        // These pre-migration digests protect stored fingerprints and leading zeroes.
        for (len, expected) in [
            (0, "99aa06d3014798d86001c324468d497f"),
            (1, "885f487031a569684a4139caf4136257"),
            (3, "d2f76a3b5388f28b505118c313121c0e"),
            (4, "b89f1314ee265fbdad17cf6483bb4f31"),
            (8, "acabfc73a36cbcfb2f685e863b34edb1"),
            (9, "428f8225bc32ed204d47bbb9821d4d08"),
            (16, "465d964535f22d7aaf8b52bc8abd84af"),
            (17, "e0b749d9e42a6e14261ec05370486e62"),
            (32, "9c925523a19f36393744a5456b09b5e9"),
            (64, "ed537e7017e31effda39cd24c80e650a"),
            (96, "5fd323872e47fae5f738dbf9d827a493"),
            (128, "b0adb160b0d7e62efc7e5a4d38ed3773"),
            (129, "ca19d202aba3e00afd5fb995ce889f09"),
            (160, "54c031747340b13b4650f4e318f262bd"),
            (225, "00fdc0c2f18c9445914c94c57fbb1b6e"),
            (239, "2a38d33d38e509576c1a6638922d4605"),
            (240, "60776a21568c1469e3382cc948003965"),
            (241, "8fe4da37d29ec7b9859dc8ab6dd85c7c"),
            (1023, "3b5e9e39b9d449bef35d4c7d308f7a40"),
            (1024, "02e7aa13471474567df7f049c0c1ad73"),
            (1025, "b845e98c00ea0dd129adcfcac5492652"),
            (65_536, "5ebfa563a08a91172b869c952fe73251"),
        ] {
            assert_eq!(xxh3_128_hex(&input[..len]), expected, "length={len}");
        }
    }
}
