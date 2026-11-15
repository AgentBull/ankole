# sqlparser 0.64.0

Source: the `sqlparser` 0.64.0 crates.io package from
https://github.com/apache/datafusion-sqlparser-rs/tree/v0.64.0.
The Apache license and notice are included alongside the upstream source.

Ankole charges each iteration of `parse_subexpr`,
`parse_remaining_set_exprs`, array type suffixes, and PIVOT/UNPIVOT chains
against the parser's existing recursion budget. These loops wrap an
accumulated subtree without recursive calls. Holding their depth guards
until the loop returns bounds those trees before visiting or error cleanup
can recursively destroy them. `parse_joins` and `parse_pattern` use the same
budget for their recursive calls. Independent expressions release their
budgets separately.

The kernel's SQL tests exercise long expression and set-operation chains,
including rejected statements and malformed input, on a small thread stack.
