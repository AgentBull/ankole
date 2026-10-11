// This module defines an {@link GardState editor state} data
// structure, a {@link Transaction transaction} abstraction for
// updating such a state, and a {@link GardSelection selection
// model}.

// ### Editor State

// The editor state captures the situation in a Wordgard editor at
// any given point in time. The editor starts with a given state when
// created. On every state-affecting user action, it applies a {@link
// Transaction transaction}, which produces the new editor state.

export { GardState } from './state'
export { Transaction } from './transaction'

// ### Selection

// Editor selections are objects that derive from {@link
// GardSelection}. This module defines {@link GardSelection.Text
// text} and {@link GardSelection.Node node} selection types. It is
// possible for extension code to {@link GardSelection.define define}
// custom selection types.

export { GardSelection } from './selection'

// ### Textblocks

// It is often helpful to look at a textblock (a block plot
// containing inline content) as a flat line of text. A {@link
// TextblockMap textblock map} is a data structure intended to make
// that easy.

export { TextblockMap } from './textblock'
export { BidiSpan } from './bidi'

// ### Corrections

// Corrections provide an abstraction for enforcing certain types of
// invariants about a document's shape. They watch for some kinds of
// document changes on specific types of nodes and, when they occur,
// run a function to verify that some condition holds and optionally
// adjust the content by making more changes.

// The correcting function will be passed a {@link Pos.Node} object
// pointing at the matched node, as well as the editor state _before_
// the transaction. Changes it produces will be interpreted as
// relative to the document _after_ the transaction (so `node.doc`).

// Corrections are wrappers around {@link Transaction.extender
// transaction extenders}. This means that their effect will be
// included in transactions as they are applied.

export { Correction } from './correction'
