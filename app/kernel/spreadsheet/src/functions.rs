//! The worksheet functions an editor offers while someone types a formula.
//!
//! GridCraft registers most functions with a signature and a description. The functions its
//! evaluator implements itself (`ROW`, `OFFSET`, `LET`, ...) are listed by name only, so this
//! module describes them, following GridCraft's own function list.

use gridcraft_functions::Category;
use serde::Serialize;

/// One worksheet function as the formula editor lists it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct FunctionInfo {
    /// The upper-case name, such as `SUM`.
    pub name: &'static str,
    /// The category key, such as `math_trig`.
    pub category: &'static str,
    /// The call shape with parameter names, such as `SUM(number1, [number2], ...)`.
    pub signature: &'static str,
    /// One sentence on what the function returns.
    pub description: &'static str,
}

/// Functions the evaluator implements itself, with the metadata the registry lacks for them.
const EVALUATOR_FUNCTIONS: &[FunctionInfo] = &[
    evaluator(
        "ROW",
        "lookup",
        "ROW([reference])",
        "Row number of a reference.",
    ),
    evaluator(
        "COLUMN",
        "lookup",
        "COLUMN([reference])",
        "Column number of a reference.",
    ),
    evaluator(
        "ROWS",
        "lookup",
        "ROWS(array)",
        "Number of rows in a reference or array.",
    ),
    evaluator(
        "COLUMNS",
        "lookup",
        "COLUMNS(array)",
        "Number of columns in a reference or array.",
    ),
    evaluator(
        "OFFSET",
        "lookup",
        "OFFSET(reference, rows, cols, [height], [width])",
        "A reference shifted from a starting point.",
    ),
    evaluator(
        "INDIRECT",
        "lookup",
        "INDIRECT(ref_text, [a1])",
        "The reference named by a text string.",
    ),
    evaluator(
        "INDEX",
        "lookup",
        "INDEX(array, row_num, [column_num], [area_num])",
        "The value or reference at a position.",
    ),
    evaluator(
        "SUBTOTAL",
        "math_trig",
        "SUBTOTAL(function_num, ref1, ...)",
        "A subtotal that can skip hidden rows.",
    ),
    evaluator(
        "AGGREGATE",
        "math_trig",
        "AGGREGATE(function_num, options, ref1, ...)",
        "An aggregate that can skip hidden rows and errors.",
    ),
    evaluator(
        "TEXT",
        "text",
        "TEXT(value, format_text)",
        "Formats a number as text.",
    ),
    evaluator(
        "LET",
        "logical",
        "LET(name1, value1, ..., calculation)",
        "Names intermediate results.",
    ),
    evaluator(
        "LAMBDA",
        "logical",
        "LAMBDA([parameter1, ...], calculation)",
        "Creates a reusable custom function.",
    ),
    evaluator(
        "MAP",
        "logical",
        "MAP(array1, ..., lambda)",
        "Applies a LAMBDA to each value.",
    ),
    evaluator(
        "REDUCE",
        "logical",
        "REDUCE(initial_value, array, lambda)",
        "Accumulates an array into one value.",
    ),
    evaluator(
        "SCAN",
        "logical",
        "SCAN(initial_value, array, lambda)",
        "Running accumulation of an array.",
    ),
    evaluator(
        "BYROW",
        "logical",
        "BYROW(array, lambda)",
        "Applies a LAMBDA to each row.",
    ),
    evaluator(
        "BYCOL",
        "logical",
        "BYCOL(array, lambda)",
        "Applies a LAMBDA to each column.",
    ),
    evaluator(
        "MAKEARRAY",
        "logical",
        "MAKEARRAY(rows, cols, lambda)",
        "Builds an array from a LAMBDA.",
    ),
    evaluator(
        "CELL",
        "information",
        "CELL(info_type, [reference])",
        "Information about a cell.",
    ),
    evaluator(
        "ISREF",
        "information",
        "ISREF(value)",
        "TRUE for references.",
    ),
    evaluator(
        "ISFORMULA",
        "information",
        "ISFORMULA(reference)",
        "TRUE when the cell has a formula.",
    ),
    evaluator(
        "FORMULATEXT",
        "lookup",
        "FORMULATEXT(reference)",
        "The formula of a cell as text.",
    ),
    evaluator("SHEET", "information", "SHEET([value])", "Sheet number."),
    evaluator(
        "SHEETS",
        "information",
        "SHEETS([reference])",
        "Number of sheets.",
    ),
    evaluator(
        "AREAS",
        "lookup",
        "AREAS(reference)",
        "Number of areas in a reference.",
    ),
    evaluator(
        "TRIMRANGE",
        "lookup",
        "TRIMRANGE(range, [trim_rows], [trim_cols])",
        "A range or array without its blank outer rows and columns.",
    ),
    evaluator(
        "ISOMITTED",
        "information",
        "ISOMITTED(argument)",
        "TRUE when a LAMBDA argument was left out.",
    ),
];

const fn evaluator(
    name: &'static str,
    category: &'static str,
    signature: &'static str,
    description: &'static str,
) -> FunctionInfo {
    FunctionInfo {
        name,
        category,
        signature,
        description,
    }
}

/// The category key the editor groups and translates functions by.
fn category_key(category: Category) -> &'static str {
    match category {
        Category::Financial => "financial",
        Category::Logical => "logical",
        Category::Text => "text",
        Category::DateTime => "date_time",
        Category::Lookup => "lookup",
        Category::MathTrig => "math_trig",
        Category::Statistical => "statistical",
        Category::Engineering => "engineering",
        Category::Information => "information",
        Category::Database => "database",
        Category::Compatibility => "compatibility",
        Category::Web => "web",
        Category::Cube => "cube",
        Category::AddIn => "add_in",
    }
}

/// Every function a formula can call, sorted by name. Each name appears once.
#[must_use]
pub fn functions() -> Vec<FunctionInfo> {
    let mut list: Vec<FunctionInfo> = gridcraft_functions::all()
        .iter()
        .map(|spec| FunctionInfo {
            name: spec.name,
            category: category_key(spec.category),
            signature: spec.signature,
            description: spec.description,
        })
        .collect();
    for info in EVALUATOR_FUNCTIONS {
        if !list.iter().any(|known| known.name == info.name) {
            list.push(*info);
        }
    }
    list.sort_unstable_by_key(|info| info.name);
    list
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::functions;

    #[test]
    fn the_list_names_every_function_the_evaluator_accepts_once() {
        let list = functions();
        let names: HashSet<_> = list.iter().map(|info| info.name).collect();
        assert_eq!(names.len(), list.len());
        for name in gridcraft_calc::SPECIAL_FUNCTIONS {
            assert!(names.contains(name), "{name} is missing");
        }
        let sum = list.iter().find(|info| info.name == "SUM");
        assert!(sum.is_some_and(|info| info.category == "math_trig"
            && info.signature.starts_with("SUM(")
            && !info.description.is_empty()));
        assert!(list.windows(2).all(|pair| pair[0].name < pair[1].name));
    }
}
