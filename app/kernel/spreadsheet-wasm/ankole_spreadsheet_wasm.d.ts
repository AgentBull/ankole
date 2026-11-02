/* tslint:disable */
/* eslint-disable */

/**
 * One spreadsheet document held by the worker.
 */
export class Spreadsheet {
    private constructor();
    free(): void;
    [Symbol.dispose](): void;
    /**
     * Executes one canonical operation locally, without rebasing, and returns
     * `{"op": …, "structural_edit": … | null}` as JSON: the operation as the control plane would
     * commit it on the same document.
     */
    apply(op_json: string): string;
    /**
     * Rebases one operation over `prior_ops_json`, the JSON array of operations committed after
     * the revision the operation was based on, executes it, and returns the same JSON as
     * [`Spreadsheet::apply`]. When the rebase would have to guess, the error message is exactly
     * the conflict's wire name, such as `target_deleted`, so the caller can tell a conflict from
     * an invalid operation.
     */
    apply_rebased(op_json: string, prior_ops_json: string): string;
    /**
     * The text a cell editor starts from for the A1 cell `cell`.
     */
    cell_input(sheet_id: number, cell: string): string;
    /**
     * The encoded bytes of the picture in the A1 cell `cell`.
     */
    cell_picture(sheet_id: number, cell: string): Uint8Array;
    /**
     * The cells of the A1 range `range` with their inputs, values, and formats, as the JSON a
     * later [`paste_op`] takes.
     */
    copy_block(sheet_id: number, range: string): string;
    /**
     * Creates a workbook with one empty sheet whose `sheet_id` is 1.
     */
    static create_blank(title: string): Spreadsheet;
    /**
     * The document as `.xlsx` bytes.
     */
    export_xlsx(): Uint8Array;
    /**
     * A second document that starts equal to this one. Documents are copy-on-write, so the fork
     * shares every sheet with this one until either side applies an operation.
     */
    fork(): Spreadsheet;
    /**
     * The encoded bytes of the floating picture `image_id`.
     */
    image_data(sheet_id: number, image_id: number): Uint8Array;
    /**
     * The floating pictures of one sheet, as JSON.
     */
    images(sheet_id: number): string;
    /**
     * Reads `.xlsx` bytes and replays the committed operations that are not yet compacted into
     * them, given as a JSON array in revision order.
     */
    static open(bytes: Uint8Array | number[], tail_ops_json: string): Spreadsheet;
    /**
     * The count, sum, average, minimum, and maximum of the A1 range `range`, as JSON.
     */
    selection_stats(sheet_id: number, range: string): string;
    /**
     * The sheet tabs in order, as JSON.
     */
    sheets(): string;
    /**
     * The cells, styles, merged areas, spills, and line sizes of the zero-based rectangle from
     * `(r0, c0)` to `(r1, c1)`, as JSON.
     */
    viewport(sheet_id: number, r0: number, c0: number, r1: number, c1: number): string;
}

/**
 * Every function a formula can call, sorted by name, as JSON.
 */
export function functions(): string;

/**
 * The `range.paste` operation, as JSON, that pastes the block JSON of
 * [`Spreadsheet::copy_block`] with its top-left cell on the A1 cell `cell`. `mode` is `all`,
 * `values`, `formulas`, or `formats`.
 */
export function paste_op(block_json: string, sheet_id: number, cell: string, mode: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_spreadsheet_free: (a: number, b: number) => void;
    readonly functions: () => [number, number, number, number];
    readonly paste_op: (a: number, b: number, c: number, d: number, e: number, f: number, g: number) => [number, number, number, number];
    readonly spreadsheet_apply: (a: number, b: number, c: number) => [number, number, number, number];
    readonly spreadsheet_apply_rebased: (a: number, b: number, c: number, d: number, e: number) => [number, number, number, number];
    readonly spreadsheet_cell_input: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly spreadsheet_cell_picture: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly spreadsheet_copy_block: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly spreadsheet_create_blank: (a: number, b: number) => [number, number, number];
    readonly spreadsheet_export_xlsx: (a: number) => [number, number, number, number];
    readonly spreadsheet_fork: (a: number) => number;
    readonly spreadsheet_image_data: (a: number, b: number, c: number) => [number, number, number, number];
    readonly spreadsheet_images: (a: number, b: number) => [number, number, number, number];
    readonly spreadsheet_open: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly spreadsheet_selection_stats: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly spreadsheet_sheets: (a: number) => [number, number, number, number];
    readonly spreadsheet_viewport: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number, number];
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
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
