//! Bounded image decoding and WebP encoding for model inputs.

use std::io::Cursor;

use image::{DynamicImage, ImageDecoder, ImageFormat, ImageReader, imageops::FilterType};

use crate::common::KernelError;

const MAX_INPUT_BYTES: usize = 50 * 1024 * 1024;
const MAX_DATA_URL_BYTES: usize = 4 * 1024 * 1024;
const MAX_DIMENSION: u32 = 4096;
const MAX_PIXELS: u64 = 268_000_000;

pub fn normalize(bytes: &[u8]) -> Result<Vec<u8>, KernelError> {
    if bytes.is_empty() || bytes.len() > MAX_INPUT_BYTES {
        return Err(KernelError::new(
            "image input exceeds the 50 MiB limit or is empty",
        ));
    }
    let mut reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(image_error)?;
    let lossless = matches!(
        reader.format(),
        Some(ImageFormat::Png | ImageFormat::Gif | ImageFormat::Bmp)
    );
    let mut limits = image::Limits::default();
    limits.max_alloc = Some(MAX_PIXELS * 8);
    reader.limits(limits);
    let mut decoder = reader.into_decoder().map_err(image_error)?;
    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 || u64::from(width) * u64::from(height) > MAX_PIXELS {
        return Err(KernelError::new("image dimensions exceed the decode limit"));
    }
    let orientation = decoder.orientation().map_err(image_error)?;
    let mut decoded = DynamicImage::from_decoder(decoder).map_err(image_error)?;
    decoded.apply_orientation(orientation);
    let mut dimension = decoded.width().max(decoded.height()).min(MAX_DIMENSION);
    for _ in 0..4 {
        let rgba = decoded
            .resize(dimension, dimension, FilterType::Lanczos3)
            .to_rgba8();
        let encoder = webp::Encoder::from_rgba(rgba.as_raw(), rgba.width(), rgba.height());
        if lossless {
            let output = encode(&encoder, true, 75)?;
            if fits(output.len()) {
                return Ok(output);
            }
        }
        let mut low = 35;
        let mut high = 85;
        let mut best = None;
        let mut smallest = usize::MAX;
        while low <= high {
            let quality = (low + high) / 2;
            let output = encode(&encoder, false, quality)?;
            smallest = smallest.min(output.len());
            if fits(output.len()) {
                best = Some(output);
                low = quality + 1;
            } else {
                high = quality - 1;
            }
        }
        if let Some(output) = best {
            return Ok(output);
        }
        let ratio = ((MAX_DATA_URL_BYTES as f64 * 0.75 / smallest as f64).sqrt() * 0.9).min(0.8);
        dimension = ((f64::from(dimension) * ratio) as u32).max(64);
    }
    Err(KernelError::new(
        "image cannot fit the 4 MiB model input limit",
    ))
}

fn encode(
    encoder: &webp::Encoder<'_>,
    lossless: bool,
    quality: i32,
) -> Result<Vec<u8>, KernelError> {
    encoder
        .encode_simple(lossless, quality as f32)
        .map(|bytes| bytes.to_vec())
        .map_err(|error| KernelError::new(format!("WebP encoding failed: {error:?}")))
}

fn fits(bytes: usize) -> bool {
    "data:image/webp;base64,".len() + bytes.div_ceil(3) * 4 <= MAX_DATA_URL_BYTES
}

fn image_error(error: impl std::fmt::Display) -> KernelError {
    KernelError::new(format!("invalid image: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::{GenericImageView, RgbaImage};

    #[test]
    fn rejects_invalid_and_oversized_inputs() {
        assert!(normalize(b"not an image").is_err());
        assert!(normalize(&vec![0; MAX_INPUT_BYTES + 1]).is_err());
    }

    #[test]
    fn preserves_alpha_and_bounds_dimensions_and_encoded_size() {
        let source = DynamicImage::ImageRgba8(RgbaImage::from_pixel(
            5000,
            100,
            image::Rgba([24, 80, 160, 128]),
        ));
        let mut bytes = Cursor::new(Vec::new());
        source.write_to(&mut bytes, ImageFormat::Png).unwrap();
        let encoded = normalize(bytes.get_ref()).unwrap();
        assert!(fits(encoded.len()));
        let output = image::load_from_memory(&encoded).unwrap();
        assert_eq!(output.width(), 4096);
        assert!(output.height() <= 4096);
        assert_eq!(output.get_pixel(0, 0).0[3], 128);
    }
    #[test]
    fn noisy_images_fall_back_from_lossless_and_fit_the_data_url_budget() {
        let mut state = 42u32;
        let source = image::RgbImage::from_fn(2300, 1800, |_, _| {
            let mut rgb = [0; 3];
            for channel in &mut rgb {
                state ^= state << 13;
                state ^= state >> 17;
                state ^= state << 5;
                *channel = state as u8;
            }
            image::Rgb(rgb)
        });
        let mut input = Cursor::new(Vec::new());
        DynamicImage::ImageRgb8(source)
            .write_to(&mut input, ImageFormat::Png)
            .unwrap();
        assert!(input.get_ref().len() > MAX_DATA_URL_BYTES);
        let output = normalize(input.get_ref()).unwrap();
        assert!(fits(output.len()));
        assert_eq!(
            image::load_from_memory(&output).unwrap().dimensions(),
            (2300, 1800)
        );
    }

    #[test]
    fn jpeg_orientation_is_applied_before_encoding() {
        let source = DynamicImage::ImageRgb8(image::RgbImage::from_pixel(
            80,
            20,
            image::Rgb([24, 80, 160]),
        ));
        let mut input = Cursor::new(Vec::new());
        source.write_to(&mut input, ImageFormat::Jpeg).unwrap();
        // One little-endian TIFF orientation tag: rotate 90 degrees clockwise.
        let exif: &[u8] =
            b"Exif\0\0II\x2a\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0\x06\0\0\0\0\0\0\0";
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe1];
        jpeg.extend_from_slice(&((exif.len() + 2) as u16).to_be_bytes());
        jpeg.extend_from_slice(exif);
        jpeg.extend_from_slice(&input.get_ref()[2..]);
        let output = normalize(&jpeg).unwrap();
        assert_eq!(
            image::load_from_memory(&output).unwrap().dimensions(),
            (20, 80)
        );
    }
}
