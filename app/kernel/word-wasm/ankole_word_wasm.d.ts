/* tslint:disable */
/* eslint-disable */

/**
 * Collaborative Word document editor and read-only page previewer held by a browser Web Worker.
 */
export class WordEditor {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Adds a dynamically fetched site font blob to the Worker's font database and returns the
     * number of loaded font faces.
     */
    static add_font(bytes: Uint8Array | number[]): number;
    /**
     * Advances `confirmed` by `confirmed_ops_json`, rebases `pending_ops_json` and any active
     * local draft, updates `Session::set_document`, shifts the caret block index, and returns
     * JSON `{"dropped_pending", "draft_conflict", "conflict_reason", "active_block"}`.
     *
     * # Errors
     *
     * Throws a `JsError` when operation JSON is malformed or carries an unsupported future
     * `model_version`.
     */
    apply_remote(confirmed_ops_json: string, pending_ops_json: string): string;
    /**
     * Returns page bounding rectangles `[{"page", "x", "y", "w", "h"}, ...]` for `block_index`
     * in `story_json` so collaborators' soft-locked blocks can be outlined.
     *
     * # Errors
     *
     * Throws a `JsError` when `story_json` is invalid.
     */
    block_rects(story_json: string, block_index: number): string;
    /**
     * Returns JSON describing the active caret, selection rectangles, Presence coordinates, and
     * active formatting flags.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    caret_and_selection(): string;
    /**
     * Lists safe WordCraft commands matching `query` as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    commands(query: string): string;
    /**
     * Derives a canonical `ChangeSet` JSON string from `optimistic_base` to the session document
     * and advances `optimistic_base`. Never commits while [`Self::is_composing`] is `true`.
     *
     * # Errors
     *
     * Throws a `JsError` when deriving or serializing the change set fails.
     */
    commit_local_step(): string | undefined;
    /**
     * Creates a blank macro-enabled `.docm` Word document editor with the given metadata title.
     *
     * # Errors
     *
     * Throws a `JsError` when the kernel cannot initialize the blank document.
     */
    static create_blank_docm(title: string): WordEditor;
    /**
     * Creates a blank `.docx` Word document editor with the given metadata title.
     *
     * # Errors
     *
     * Throws a `JsError` when the kernel cannot initialize the blank document.
     */
    static create_blank(title: string): WordEditor;
    /**
     * Runs a safe WordCraft command by ID with JSON parameters.
     *
     * # Errors
     *
     * Throws a `JsError` when the command is blocked, `params_json` is malformed, or execution
     * fails.
     */
    execute_command(command_id: string, params_json: string): string;
    /**
     * Exports the current document as `.docx` or `.docm` bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when OOXML serialization fails.
     */
    export_docx(): Uint8Array;
    /**
     * Exports the current document as PDF bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when PDF export fails.
     */
    export_pdf(): Uint8Array;
    /**
     * Searches all stories of the document for `query`, returning match positions, snippets, and
     * page highlight rectangles as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    find(query: string, match_case: boolean): string;
    /**
     * Returns `true` when the active session document differs from `optimistic_base` (and no IME
     * composition is active).
     */
    has_local_changes(): boolean;
    /**
     * Cancels an active IME composition and restores the pre-composition document state.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    ime_cancel(): string;
    /**
     * Commits an active IME composition with `text`.
     *
     * # Errors
     *
     * Throws a `JsError` when inserting the committed text fails.
     */
    ime_commit(text: string): string;
    /**
     * Updates active IME preedit text and relative cursor offsets.
     *
     * # Errors
     *
     * Throws a `JsError` when updating the preedit range fails.
     */
    ime_preedit(text: string, cursor_start: number, cursor_end: number): string;
    /**
     * Inserts plain text at the current selection outside IME composition.
     *
     * # Errors
     *
     * Throws a `JsError` when the insertion is refused by the active selection.
     */
    insert_text(text: string): string;
    /**
     * Returns `true` while an IME composition session is active.
     */
    is_composing(): boolean;
    /**
     * Dispatches a keyboard shortcut, navigation key, or character key event.
     *
     * # Errors
     *
     * Throws a `JsError` when command execution or JSON serialization fails.
     */
    key_event(key: string, ctrl_or_meta: boolean, shift: boolean, alt: boolean): string;
    /**
     * Loads any fonts embedded in the opened document into the Worker's font database and returns
     * the number of loaded font faces.
     */
    load_embedded_fonts(): number;
    /**
     * Returns canonical site fallback font families needed for uncovered CJK glyphs as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    missing_glyph_fonts(): string;
    /**
     * Returns diagnostic entries for pictures that could not be loaded on open, as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    missing_pictures(): string;
    /**
     * Opens `.docx` or `.docm` bytes, restores an optional compaction identity checkpoint, and
     * replays the uncompacted JSON array `tail_ops_json`.
     *
     * # Errors
     *
     * Throws a `JsError` when the package, checkpoint, or uncompacted operations are invalid or
     * newer than supported.
     */
    static open(bytes: Uint8Array | number[], tail_ops_json: string, checkpoint_json?: string | null): WordEditor;
    /**
     * Returns `[width_px, height_px]` for `page_index` rendered at `scale` pixels per point.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds or `scale` is invalid.
     */
    page_pixel_size(page_index: number, scale: number): Uint32Array;
    /**
     * Lays out the document, caches the layout, and returns page geometry
     * `[{"index", "width_pt", "height_pt"}, ...]` as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    pages_info(): string;
    /**
     * Handles a pointer down gesture at `(x_pt, y_pt)` on `page_index`.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
     */
    pointer_down(page_index: number, x_pt: number, y_pt: number, clicks: number, shift: boolean, alt: boolean): string;
    /**
     * Updates an active pointer gesture at `(x_pt, y_pt)` on `page_index`.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
     */
    pointer_move(page_index: number, x_pt: number, y_pt: number): string;
    /**
     * Finishes an active pointer gesture at `(x_pt, y_pt)` on `page_index`.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds or coordinates are non-finite.
     */
    pointer_up(page_index: number, x_pt: number, y_pt: number): string;
    /**
     * Resolves a collaborator's Presence selection JSON into page highlight rectangles.
     *
     * # Errors
     *
     * Throws a `JsError` when `selection_json` is malformed.
     */
    presence_selection_rects(selection_json: string): string;
    /**
     * Redoes the latest undone personal block snapshot and returns any resulting `blocks.splice`
     * `ChangeSet` JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when deriving or serializing the redo change set fails.
     */
    redo(): string | undefined;
    /**
     * Rasterizes `page_index` at `scale` pixels per point and encodes it as PNG bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds, `scale` is invalid, or PNG encoding
     * fails.
     */
    render_page_png(page_index: number, scale: number): Uint8Array;
    /**
     * Rasterizes `page_index` at `scale` pixels per point into straight RGBA8 bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when `page_index` is out of bounds or `scale` is invalid.
     */
    render_page_rgba(page_index: number, scale: number): Uint8Array;
    /**
     * Discards unconfirmed local edits and resets the session document to `confirmed`.
     */
    reset_to_confirmed(): void;
    /**
     * Returns HTML markup for the active selection.
     */
    selected_html(): string;
    /**
     * Returns the plain text of the active selection.
     */
    selected_text(): string;
    /**
     * Returns font family substitutions recorded during layout as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when JSON serialization fails.
     */
    substituted_fonts(): string;
    /**
     * Undoes the latest personal block snapshot and returns any resulting `blocks.splice`
     * `ChangeSet` JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when deriving or serializing the undo change set fails.
     */
    undo(): string | undefined;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_wordeditor_free: (a: number, b: number) => void;
    readonly wordeditor_add_font: (a: number, b: number) => number;
    readonly wordeditor_apply_remote: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly wordeditor_block_rects: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly wordeditor_caret_and_selection: (a: number) => [number, number, number, number];
    readonly wordeditor_commands: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_commit_local_step: (a: number) => [number, number, number, number];
    readonly wordeditor_create_blank: (a: number, b: number) => [number, number, number];
    readonly wordeditor_create_blank_docm: (a: number, b: number) => [number, number, number];
    readonly wordeditor_execute_command: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly wordeditor_export_docx: (a: number) => [number, number, number, number];
    readonly wordeditor_export_pdf: (a: number) => [number, number, number, number];
    readonly wordeditor_find: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly wordeditor_has_local_changes: (a: number) => number;
    readonly wordeditor_ime_cancel: (a: number) => [number, number, number, number];
    readonly wordeditor_ime_commit: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_ime_preedit: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly wordeditor_insert_text: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_is_composing: (a: number) => number;
    readonly wordeditor_key_event: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number, number];
    readonly wordeditor_load_embedded_fonts: (a: number) => number;
    readonly wordeditor_missing_glyph_fonts: (a: number) => [number, number, number, number];
    readonly wordeditor_missing_pictures: (a: number) => [number, number, number, number];
    readonly wordeditor_open: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number];
    readonly wordeditor_page_pixel_size: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_pages_info: (a: number) => [number, number, number, number];
    readonly wordeditor_pointer_down: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => [number, number, number, number];
    readonly wordeditor_pointer_move: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly wordeditor_pointer_up: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly wordeditor_presence_selection_rects: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_redo: (a: number) => [number, number, number, number];
    readonly wordeditor_render_page_png: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_render_page_rgba: (a: number, b: number, c: number) => [number, number, number, number];
    readonly wordeditor_reset_to_confirmed: (a: number) => void;
    readonly wordeditor_selected_html: (a: number) => [number, number];
    readonly wordeditor_selected_text: (a: number) => [number, number];
    readonly wordeditor_substituted_fonts: (a: number) => [number, number, number, number];
    readonly wordeditor_undo: (a: number) => [number, number, number, number];
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
