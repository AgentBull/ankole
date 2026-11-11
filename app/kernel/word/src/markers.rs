//! Paired inline marker balance checks across all paragraphs of a story.

use std::collections::BTreeSet;
use std::sync::Arc;

use wordcraft_doc::para::InlineObject;
use wordcraft_doc::{Block, Document, Paragraph, StoryRef};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum SeqMarker {
    Field,
    Control,
}

#[derive(Default)]
struct MarkerState {
    seq_stack: Vec<SeqMarker>,
    open_comments: BTreeSet<u32>,
    open_bookmarks: BTreeSet<String>,
    open_perms: BTreeSet<u32>,
}

impl MarkerState {
    fn visit_paragraph(&mut self, para: &Paragraph) -> bool {
        for obj in &para.objects {
            let ok = match obj {
                InlineObject::FieldStart { .. } => {
                    self.seq_stack.push(SeqMarker::Field);
                    true
                }
                InlineObject::FieldEnd => self.seq_stack.pop() == Some(SeqMarker::Field),
                InlineObject::ControlStart { .. } => {
                    self.seq_stack.push(SeqMarker::Control);
                    true
                }
                InlineObject::ControlEnd => self.seq_stack.pop() == Some(SeqMarker::Control),
                InlineObject::CommentStart { id } => self.open_comments.insert(*id),
                InlineObject::CommentEnd { id } => self.open_comments.remove(id),
                InlineObject::BookmarkStart { name } => self.open_bookmarks.insert(name.clone()),
                InlineObject::BookmarkEnd { name } => self.open_bookmarks.remove(name),
                InlineObject::PermStart { id, .. } => self.open_perms.insert(*id),
                InlineObject::PermEnd { id } => self.open_perms.remove(id),
                _ => true,
            };
            if !ok {
                return false;
            }
        }
        true
    }

    fn visit_blocks(&mut self, blocks: &[Arc<Block>]) -> bool {
        for block in blocks {
            match block.as_ref() {
                Block::Para(para) => {
                    if !self.visit_paragraph(para) {
                        return false;
                    }
                }
                Block::Table(table) => {
                    for row in &table.rows {
                        for cell in &row.cells {
                            if !self.visit_blocks(&cell.blocks) {
                                return false;
                            }
                        }
                    }
                }
            }
        }
        true
    }

    fn is_balanced(&self) -> bool {
        self.seq_stack.is_empty()
            && self.open_comments.is_empty()
            && self.open_bookmarks.is_empty()
            && self.open_perms.is_empty()
    }
}

/// Returns `true` when sequential (`FieldStart`/`FieldEnd`, `ControlStart`/`ControlEnd`) and
/// keyed (`CommentStart`/`CommentEnd`, `BookmarkStart`/`BookmarkEnd`, `PermStart`/`PermEnd`)
/// inline markers are properly paired across every paragraph and table cell in `story`.
pub(crate) fn story_markers_balanced(doc: &Document, story: StoryRef) -> bool {
    let Some(blocks) = doc.story(story) else {
        return true;
    };
    let mut state = MarkerState::default();
    state.visit_blocks(blocks) && state.is_balanced()
}
