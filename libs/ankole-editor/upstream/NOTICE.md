# Test source notices

The tests use data and scenarios from these repositories at fixed commits. The fixture files keep the original inputs and expected values. The dialect files record each changed input or expectation, with its reason.

| Source | Commit | Used in |
| --- | --- | --- |
| [Tiptap](https://github.com/ueberdosis/tiptap) | `c402400e60192895cfed85e1a72adf3fbb43d08e` | `fixtures/tiptap-*.json`, `tests/tiptap-*.test.ts` |
| [ProseMirror view](https://github.com/ProseMirror/prosemirror-view) | `ca4c78e9b56f1b164c0b3758b59d8748f11b7534` | `e2e/upstream-clipboard.spec.ts` |
| [ProseMirror schema-list](https://github.com/ProseMirror/prosemirror-schema-list) | `15016199fc6defd2a605466f4ebffb4ef128620a` | `e2e/upstream-lists.spec.ts` |
| [BlockSuite](https://github.com/toeverything/blocksuite) | `5cb5cb68471ca692f3c162258f0087cb22fcb82d` | `fixtures/blocksuite-*.json`, `e2e/blocksuite-html.spec.ts` |
| [AFFiNE](https://github.com/toeverything/AFFiNE) | `b71bb7cfc45f66998ed3827ba5606e0420f8fbb4` | `e2e/affine-editing.spec.ts`, `e2e/input-events.spec.ts` |
| [Slate](https://github.com/ianstormtaylor/slate) | `0f847cb9b059debdfd125dd62e967cb3b3ca3a62` | `fixtures/slate-*.json`, `e2e/slate-editing.spec.ts`, `compat/native.test.ts` |
| [Docs](https://github.com/suitenumerique/docs) | `03838c14d4d3b0a70a01010e5afdd93acc9fec90` | `e2e/docs-editing.spec.ts` |
| [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/) | official `spec.json` | `fixtures/commonmark-*.json`, `tests/commonmark.test.ts` |

- Tiptap test fixtures and expected JSON are from Tiptap GmbH, under the [MIT license](licenses/tiptap.txt).
- ProseMirror browser scenarios are derived from tests by Marijn Haverbeke and contributors, under the MIT license. See [pm-view](licenses/pm-view.txt) and [pm-schema-list](licenses/pm-schema-list.txt).
- BlockSuite HTML fixtures are from TOEVERYTHING PTE. LTD., under [MPL-2.0](licenses/blocksuite.txt). `fixtures/blocksuite-html.json` and `fixtures/blocksuite-dialect.json` are derived files under the same license. Workspace IDs and document wrappers are removed.
- AFFiNE browser scenarios are from TOEVERYTHING PTE. LTD. and its affiliates, under the [MIT license](licenses/affine.txt). The [root license notice](licenses/affine-scope.txt) restricts other directories. The tests derive only from `tests/blocksuite/e2e`, not from the restricted backend or native code.
- Slate JSX fixtures and browser scenarios are from Ian Storm Taylor and contributors, under the [MIT license](licenses/slate.txt). The fixtures keep the original input, output and range data.
- Docs browser scenarios are from DINUM and contributors, under the [MIT license](licenses/docs.txt). The local cases replace its BlockNote and server setup with this editor and local file persistence.
- CommonMark 0.31.2 is by John MacFarlane, under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). `fixtures/commonmark-0.31.2.json` is the unmodified [official example corpus](https://spec.commonmark.org/0.31.2/spec.json). `fixtures/commonmark-dialect.json` is derived from it under the same license.

This notice does not imply endorsement by the source authors.

The CommonMark dialect file records each example where the page differs from the reference renderer: the exact page in XML, or the exact error. A passing run does not claim conformance to the CommonMark HTML renderer.
