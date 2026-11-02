//! Floating pictures and pictures placed in cells.
//!
//! A floating picture sits over the grid and moves, without stretching, with the cell its
//! top-left corner is in. A cell picture is the cell's content: it replaces the value or formula
//! and goes away when someone types into the cell.

use std::sync::Arc;

use gridcraft_core::CellRef;
use gridcraft_model::{Anchor, AnchorMode, CellPicture, Image, Workbook};

use super::edit::sheet_mut;
use super::{ImageAnchor, Outcome, Picture, PictureMime};
use crate::Error;
use crate::doc::require_sheet;
use crate::ids::{ImageId, SheetId};

/// The largest picture one operation may carry, in bytes.
pub const MAX_PICTURE_BYTES: usize = 2 * 1024 * 1024;
/// The widest or tallest a floating picture may be, and the farthest its corner may sit inside
/// its cell, in pixels.
const MAX_IMAGE_PX: f32 = 10_000.0;
const MAX_ALT_CHARS: usize = 1_000;

pub(super) fn insert(
    wb: &mut Workbook,
    sheet_id: SheetId,
    image_id: &mut Option<ImageId>,
    anchor: &ImageAnchor,
    picture: &Picture,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_anchor(anchor)?;
    check_picture(picture)?;
    let id = new_object_id(wb, *image_id)?;
    *image_id = Some(id);
    sheet_mut(wb, index)?.images.push(Image {
        id: id.0,
        anchor: model_anchor(anchor),
        data: Arc::new(picture.data.0.clone()),
        mime: picture.mime.as_str().to_string(),
        alt: picture.alt.clone(),
    });
    Ok(Outcome::default())
}

pub(super) fn update(
    wb: &mut Workbook,
    sheet_id: SheetId,
    image_id: ImageId,
    anchor: &ImageAnchor,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_anchor(anchor)?;
    let sheet = sheet_mut(wb, index)?;
    let image = sheet
        .images
        .iter_mut()
        .find(|image| image.id == image_id.0)
        .ok_or_else(|| missing(image_id))?;
    image.anchor = Anchor {
        mode: image.anchor.mode,
        ..model_anchor(anchor)
    };
    Ok(Outcome::default())
}

pub(super) fn delete(
    wb: &mut Workbook,
    sheet_id: SheetId,
    image_id: ImageId,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    take_image(sheet_mut(wb, index)?, image_id)?;
    Ok(Outcome::default())
}

pub(super) fn set_cell_picture(
    wb: &mut Workbook,
    sheet_id: SheetId,
    at: CellRef,
    picture: Option<&Picture>,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let Some(picture) = picture else {
        sheet.cell_pictures.remove(&at);
        return Ok(Outcome::default());
    };
    check_picture(picture)?;
    place_in_cell(
        wb,
        index,
        at,
        CellPicture {
            data: picture.data.0.clone(),
            mime: picture.mime.as_str().to_string(),
            alt: picture.alt.clone(),
        },
    )
}

pub(super) fn to_cell(
    wb: &mut Workbook,
    sheet_id: SheetId,
    image_id: ImageId,
    at: CellRef,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    let sheet = sheet_mut(wb, index)?;
    let position = sheet
        .images
        .iter()
        .position(|image| image.id == image_id.0)
        .ok_or_else(|| missing(image_id))?;
    let mime = sheet.images.get(position).map(|image| image.mime.clone());
    if !mime.as_deref().is_some_and(cell_mime) {
        return Err(Error::invalid(
            "only PNG and JPEG pictures can be placed in a cell",
        ));
    }
    let image = take_image(sheet, image_id)?;
    let data = Arc::try_unwrap(image.data).unwrap_or_else(|shared| shared.as_ref().clone());
    place_in_cell(
        wb,
        index,
        at,
        CellPicture {
            data,
            mime: image.mime,
            alt: image.alt,
        },
    )
}

pub(super) fn from_cell(
    wb: &mut Workbook,
    sheet_id: SheetId,
    at: CellRef,
    image_id: &mut Option<ImageId>,
    anchor: &ImageAnchor,
) -> Result<Outcome, Error> {
    let index = require_sheet(wb, sheet_id)?;
    check_anchor(anchor)?;
    let id = new_object_id(wb, *image_id)?;
    let sheet = sheet_mut(wb, index)?;
    let picture = sheet
        .cell_pictures
        .remove(&at)
        .ok_or_else(|| Error::invalid(format!("{} holds no picture", at.a1())))?;
    let picture = Arc::try_unwrap(picture).unwrap_or_else(|shared| shared.as_ref().clone());
    sheet.images.push(Image {
        id: id.0,
        anchor: model_anchor(anchor),
        data: Arc::new(picture.data),
        mime: picture.mime,
        alt: picture.alt,
    });
    *image_id = Some(id);
    Ok(Outcome {
        changed: vec![(index, at)],
        structural: false,
    })
}

/// Puts `picture` into the cell in place of its value or formula; the cell keeps its format.
fn place_in_cell(
    wb: &mut Workbook,
    index: usize,
    at: CellRef,
    picture: CellPicture,
) -> Result<Outcome, Error> {
    let sheet = sheet_mut(wb, index)?;
    let style = sheet.cell(at).map(|cell| cell.style);
    sheet.remove_cell(at);
    if let Some(style) = style.filter(|style| *style != gridcraft_model::StyleId::default()) {
        sheet.set_style(at, style);
    }
    sheet.cell_pictures.insert(at, Arc::new(picture));
    Ok(Outcome {
        changed: vec![(index, at)],
        structural: false,
    })
}

fn take_image(sheet: &mut gridcraft_model::Sheet, image_id: ImageId) -> Result<Image, Error> {
    let position = sheet
        .images
        .iter()
        .position(|image| image.id == image_id.0)
        .ok_or_else(|| missing(image_id))?;
    Ok(sheet.images.remove(position))
}

fn missing(image_id: ImageId) -> Error {
    Error::invalid(format!("no picture has image_id {image_id} on this sheet"))
}

/// The id a new floating picture gets: the one the editor chose when no object of the workbook
/// uses it, or else one past every object id in use.
fn new_object_id(wb: &Workbook, requested: Option<ImageId>) -> Result<ImageId, Error> {
    let Some(ImageId(id)) = requested else {
        return Ok(ImageId(wb.next_object_id()));
    };
    let used = wb.sheets.iter().any(|sheet| {
        sheet.images.iter().any(|object| object.id == id)
            || sheet.charts.iter().any(|object| object.id == id)
            || sheet.shapes.iter().any(|object| object.id == id)
            || sheet.tables.iter().any(|object| object.id == id)
            || sheet.slicers.iter().any(|object| object.id == id)
    });
    if id == 0 || used {
        return Err(Error::invalid(format!("image_id {id} is already in use")));
    }
    Ok(ImageId(id))
}

fn model_anchor(anchor: &ImageAnchor) -> Anchor {
    Anchor {
        cell: anchor.cell.0,
        dx: anchor.dx,
        dy: anchor.dy,
        width: anchor.width,
        height: anchor.height,
        mode: AnchorMode::MoveOnly,
    }
}

fn check_anchor(anchor: &ImageAnchor) -> Result<(), Error> {
    let offset = |value: f32| value.is_finite() && (0.0..=MAX_IMAGE_PX).contains(&value);
    let size = |value: f32| value.is_finite() && value > 0.0 && value <= MAX_IMAGE_PX;
    if !offset(anchor.dx) || !offset(anchor.dy) || !size(anchor.width) || !size(anchor.height) {
        return Err(Error::invalid(format!(
            "a picture's offsets must lie in 0..={MAX_IMAGE_PX} and its size in 1..={MAX_IMAGE_PX} pixels"
        )));
    }
    Ok(())
}

fn check_picture(picture: &Picture) -> Result<(), Error> {
    let data = picture.data.0.as_slice();
    if data.is_empty() || data.len() > MAX_PICTURE_BYTES {
        return Err(Error::invalid(format!(
            "a picture holds 1 to {MAX_PICTURE_BYTES} bytes"
        )));
    }
    let matches = match picture.mime {
        PictureMime::Png => data.starts_with(b"\x89PNG\r\n\x1a\n"),
        PictureMime::Jpeg => data.starts_with(&[0xFF, 0xD8, 0xFF]),
    };
    if !matches {
        return Err(Error::invalid(format!(
            "the picture data is not {}",
            picture.mime.as_str()
        )));
    }
    if picture.alt.chars().count() > MAX_ALT_CHARS {
        return Err(Error::invalid(format!(
            "a picture's alternative text holds at most {MAX_ALT_CHARS} characters"
        )));
    }
    Ok(())
}

/// Whether Excel can show a picture of this MIME type in a cell.
fn cell_mime(mime: &str) -> bool {
    matches!(
        mime.to_ascii_lowercase().as_str(),
        "image/png" | "image/jpeg" | "image/jpg"
    )
}
