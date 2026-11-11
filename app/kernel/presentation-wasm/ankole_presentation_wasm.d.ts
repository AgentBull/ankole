/* tslint:disable */
/* eslint-disable */

/**
 * Stateful presentation editor and previewer owned by a browser Web Worker.
 */
export class PresentationEditor {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Returns the zero-based index of the active slide.
     */
    active_slide(): number;
    /**
     * Adds a raw font blob to this Worker's `FontDb`, returning the number of font faces loaded.
     */
    static add_font(bytes: Uint8Array | number[]): number;
    /**
     * Advances `confirmed` by `confirmed_ops_json` and rebases `pending_ops_json` plus any
     * uncommitted local draft onto `confirmed`, returning rebase status JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if the operation lists cannot be parsed or carry a future `model_version`.
     */
    apply_remote(confirmed_ops_json: string, pending_ops_json: string): string;
    /**
     * Lists safe editor commands matching `query` as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if JSON serialization fails.
     */
    commands(query: string): string;
    /**
     * Derives a canonical `ChangeSet` JSON string from `optimistic_base` to the current session
     * document and advances `optimistic_base`, returning `None` when nothing changed.
     *
     * # Errors
     *
     * Throws a `JsError` if the derived operation violates wire or picture limits.
     */
    commit_local_step(): string | undefined;
    /**
     * Creates a clean 1-slide blank presentation editor with `title`.
     *
     * # Errors
     *
     * Throws a `JsError` if initialization fails.
     */
    static create_blank(title: string): PresentationEditor;
    /**
     * Executes a safe DeckCraft command with JSON parameters on the local session.
     *
     * # Errors
     *
     * Throws a `JsError` if the command is blocked, `params_json` is invalid, or execution fails.
     */
    execute_command(command_id: string, params_json: string): string;
    /**
     * Exports the current presentation as PDF bytes.
     *
     * # Errors
     *
     * Throws a `JsError` if PDF serialization fails.
     */
    export_pdf(): Uint8Array;
    /**
     * Exports the current presentation as `.pptx` bytes.
     *
     * # Errors
     *
     * Throws a `JsError` if `.pptx` serialization fails.
     */
    export_pptx(): Uint8Array;
    /**
     * Searches all slide shapes and speaker notes for `query`, returning matches as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if JSON serialization fails.
     */
    find(query: string, match_case: boolean): string;
    /**
     * Reports whether uncommitted local draft changes exist relative to `optimistic_base`.
     */
    has_local_changes(): boolean;
    /**
     * Feeds a keyboard press with modifier flags to the session.
     *
     * # Errors
     *
     * Throws a `JsError` if `mods_json` is malformed or key handling fails.
     */
    key_event(key: string, mods_json: string): string;
    /**
     * Decodes and registers embedded presentation fonts in this Worker's `FontDb`, returning the
     * number of font faces loaded.
     */
    load_embedded_fonts(): number;
    /**
     * Returns canonical site fallback font families needed for uncovered CJK characters as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if JSON serialization fails.
     */
    missing_glyph_fonts(): string;
    /**
     * Opens `.pptx` bytes, applies an optional compaction identity checkpoint, and replays
     * committed `tail_ops_json` in revision order.
     *
     * # Errors
     *
     * Throws a `JsError` if `bytes` or `checkpoint_json` cannot be decoded, an operation is
     * invalid, or an operation carries a newer `model_version` than this build supports.
     */
    static open(bytes: Uint8Array | number[], tail_ops_json: string, checkpoint_json?: string | null): PresentationEditor;
    /**
     * Feeds a pointer event in slide coordinates (points) to the session's active tool.
     *
     * # Errors
     *
     * Throws a `JsError` if `event_json` is malformed or tool execution fails.
     */
    pointer_event(event_json: string): string;
    /**
     * Redoes the last undone personal single-slide edit and returns the derived `slide.put`
     * `ChangeSet` JSON, or `None` when the Redo stack is empty.
     *
     * # Errors
     *
     * Throws a `JsError` if change set derivation fails.
     */
    redo(): string | undefined;
    /**
     * Rasterizes `slide_index` at `scale` into encoded PNG bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when `slide_index` or `scale` is invalid or PNG encoding fails.
     */
    render_slide_png(slide_index: number, scale: number): Uint8Array;
    /**
     * Rasterizes `slide_index` at `scale` into straight RGBA8 bytes.
     *
     * # Errors
     *
     * Throws a `JsError` when `slide_index` or `scale` is invalid.
     */
    render_slide_rgba(slide_index: number, scale: number): Uint8Array;
    /**
     * Discards pending and draft local edits, restoring the session to `confirmed`.
     */
    reset_to_confirmed(): void;
    /**
     * Returns plain text of the active text selection, selected table cells, or selected shapes.
     */
    selected_text(): string;
    /**
     * Returns the current slide selection, shape selection, text caret/range, notes, editing
     * state, and Undo/Redo availability as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if serialization fails.
     */
    selection_info(): string;
    /**
     * Sets the active slide by zero-based `slide_index` and returns updated selection info JSON.
     *
     * # Errors
     *
     * Throws a `JsError` when `slide_index` is out of bounds.
     */
    set_active_slide(slide_index: number): string;
    /**
     * Updates the speaker notes text of `slide_id`.
     *
     * # Errors
     *
     * Throws a `JsError` if `slide_id` does not exist.
     */
    set_slide_notes(slide_id: number, notes: string): void;
    /**
     * Returns `[width, height]` in pixels for slides rendered at `scale`.
     */
    slide_pixel_size(scale: number): Uint32Array;
    /**
     * Returns slide list metadata across the presentation as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if serialization fails.
     */
    slides_info(): string;
    /**
     * Returns missing font families and their substituted faces as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if JSON serialization fails.
     */
    substituted_fonts(): string;
    /**
     * Undoes the last personal single-slide edit and returns the derived `slide.put` `ChangeSet`
     * JSON, or `None` when the Undo stack is empty.
     *
     * # Errors
     *
     * Throws a `JsError` if change set derivation fails.
     */
    undo(): string | undefined;
    /**
     * Returns import warnings reported when the presentation was opened as JSON.
     *
     * # Errors
     *
     * Throws a `JsError` if JSON serialization fails.
     */
    warnings(): string;
}

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_presentationeditor_free: (a: number, b: number) => void;
    readonly presentationeditor_active_slide: (a: number) => number;
    readonly presentationeditor_add_font: (a: number, b: number) => number;
    readonly presentationeditor_apply_remote: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly presentationeditor_commands: (a: number, b: number, c: number) => [number, number, number, number];
    readonly presentationeditor_commit_local_step: (a: number) => [number, number, number, number];
    readonly presentationeditor_create_blank: (a: number, b: number) => [number, number, number];
    readonly presentationeditor_execute_command: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly presentationeditor_export_pdf: (a: number) => [number, number, number, number];
    readonly presentationeditor_export_pptx: (a: number) => [number, number, number, number];
    readonly presentationeditor_find: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly presentationeditor_has_local_changes: (a: number) => number;
    readonly presentationeditor_key_event: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly presentationeditor_load_embedded_fonts: (a: number) => number;
    readonly presentationeditor_missing_glyph_fonts: (a: number) => [number, number, number, number];
    readonly presentationeditor_open: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number];
    readonly presentationeditor_pointer_event: (a: number, b: number, c: number) => [number, number, number, number];
    readonly presentationeditor_redo: (a: number) => [number, number, number, number];
    readonly presentationeditor_render_slide_png: (a: number, b: number, c: number) => [number, number, number, number];
    readonly presentationeditor_render_slide_rgba: (a: number, b: number, c: number) => [number, number, number, number];
    readonly presentationeditor_reset_to_confirmed: (a: number) => void;
    readonly presentationeditor_selected_text: (a: number) => [number, number];
    readonly presentationeditor_selection_info: (a: number) => [number, number, number, number];
    readonly presentationeditor_set_active_slide: (a: number, b: number) => [number, number, number, number];
    readonly presentationeditor_set_slide_notes: (a: number, b: number, c: number, d: number) => [number, number];
    readonly presentationeditor_slide_pixel_size: (a: number, b: number) => [number, number];
    readonly presentationeditor_slides_info: (a: number) => [number, number, number, number];
    readonly presentationeditor_substituted_fonts: (a: number) => [number, number, number, number];
    readonly presentationeditor_undo: (a: number) => [number, number, number, number];
    readonly presentationeditor_warnings: (a: number) => [number, number, number, number];
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
