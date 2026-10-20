// This module defines the library's document data structure, change
// model, and some helper functionality for working with those.

// ### Document

// A document is a tree of nodes. It is made up of these elements:

// - {@link Node Nodes} can be {@link Plot plots} (nodes with content
//   nodes) or {@link Leaf leaves}. The top document node is a plot.

// - Each node has a {@link Node.Type type}.

// - {@link Mark Marks} are pieces of information attached to nodes.
//   They are used for things like text style, image alt text, or
//   block alignment.

// - {@link Node.Tag Tags} describes a node's nature, it combines a
//   {@link Node.Type node type}, an optional parameter value, and a
//   set of marks. Leaf nodes {@link Leaf _are_} tags, plot nodes
//   {@link Plot.tag _have_} tags.

export { Node, Leaf, Plot } from './node'
export { Mark } from './mark'

// ### Shapes

// Node and mark shapes (the way they are converted to and from
// DOM/HTML structure) can be defined with these data structures.

export { Elt, Attributes } from './shape'
export type { Shape } from './shape'

// ### Schema

// Each document has a {@link Schema schema} associated with it that
// configures the set of nodes and marks that can occur in it, and
// their relations.

export { Schema } from './schema'
export { SchemaError, ValidationError } from './error'

// ### Changes

// Change sets provide a precise description of how a document
// changed. Any modification to the editor's document goes through a
// transaction, which describes it using a change set.

export { ChangeSet } from './change'
export { Slice, Token } from './slice'

// ### Resolved Positions

// Positions in a wordgard document are expressed with offset numbers.
// On its own, such a number doesn't tell you much about its context.
// Resolved positions are data structures that describe a node or a
// position in a node, plus that node's parents (if any).

export { Pos } from './pos'

// ### Parsing and Serialization

// These functions allow conversion between HTML and Wordgard
// document formats. Note that, because not all of HTML is
// expressible in a given Wordgard schema, parsing is lossy.

export { parse } from './parse'
export { serialize } from './serialize'
