use std::collections::BTreeSet;
use std::sync::Arc;

use cel::common::ast::{EntryExpr, Expr, IdedEntryExpr, IdedExpr};
use cel::common::types::{self, CelBool};
use cel::common::value::CowVal;
use cel::{Context, Env, Program, Value as CelValue, functions};
use serde_json::Value as JSONValue;

use crate::common::{KernelError, KernelResult};

#[derive(Debug, Eq, PartialEq)]
pub enum BoolEvalError {
    Execution(String),
    ResultType(String),
}

pub fn validate_condition_source(condition: &str) -> KernelResult<()> {
    let program = compile_condition(condition)?;
    validate_program_variables(&program, &["principal", "resource", "action", "context"])
}

pub fn validate_drive_condition_source(condition: &str) -> KernelResult<()> {
    let program = compile_condition(condition)?;
    validate_drive_condition_program(&program)
}

pub(crate) fn validate_drive_condition_program(program: &Program) -> KernelResult<()> {
    validate_program_variables(program, &["principal", "context"])
}

pub fn condition_free_variables(condition: &str) -> KernelResult<Vec<String>> {
    let program = compile_condition(condition)?;
    Ok(program_free_variables(&program))
}

fn validate_program_variables(program: &Program, allowed: &[&str]) -> KernelResult<()> {
    let invalid: Vec<_> = program_free_variables(program)
        .into_iter()
        .filter(|name| !allowed.contains(&name.as_str()))
        .collect();
    if invalid.is_empty() {
        Ok(())
    } else {
        Err(KernelError::new(format!(
            "invalid cel condition free variables: {}",
            invalid.join(", ")
        )))
    }
}

fn program_free_variables(program: &Program) -> Vec<String> {
    let mut variables = BTreeSet::new();
    collect_free_variables(program.expression(), &mut Vec::new(), &mut variables);
    variables.into_iter().map(str::to_owned).collect()
}

fn collect_free_variables<'a>(
    expression: &'a IdedExpr,
    bindings: &mut Vec<&'a str>,
    variables: &mut BTreeSet<&'a str>,
) {
    match &expression.expr {
        Expr::Ident(name) => {
            if !bindings.contains(&name.as_str()) {
                variables.insert(name);
            }
        }
        Expr::Call(call) => {
            if let Some(target) = &call.target {
                collect_free_variables(target, bindings, variables);
            }
            for argument in &call.args {
                collect_free_variables(argument, bindings, variables);
            }
        }
        Expr::Select(select) => collect_free_variables(&select.operand, bindings, variables),
        Expr::List(list) => {
            for element in &list.elements {
                collect_free_variables(element, bindings, variables);
            }
        }
        Expr::Map(map) => collect_entry_variables(&map.entries, bindings, variables),
        Expr::Struct(structure) => collect_entry_variables(&structure.entries, bindings, variables),
        Expr::Comprehension(comprehension) => {
            collect_free_variables(&comprehension.iter_range, bindings, variables);
            collect_free_variables(&comprehension.accu_init, bindings, variables);
            let outer_scope = bindings.len();
            bindings.push(&comprehension.accu_var);
            bindings.push(&comprehension.iter_var);
            if let Some(iter_var2) = &comprehension.iter_var2 {
                bindings.push(iter_var2);
            }
            collect_free_variables(&comprehension.loop_cond, bindings, variables);
            collect_free_variables(&comprehension.loop_step, bindings, variables);
            bindings.truncate(outer_scope + 1);
            collect_free_variables(&comprehension.result, bindings, variables);
            bindings.truncate(outer_scope);
        }
        Expr::Unspecified | Expr::Literal(_) => {}
    }
}

fn collect_entry_variables<'a>(
    entries: &'a [IdedEntryExpr],
    bindings: &mut Vec<&'a str>,
    variables: &mut BTreeSet<&'a str>,
) {
    for entry in entries {
        match &entry.expr {
            EntryExpr::StructField(field) => {
                collect_free_variables(&field.value, bindings, variables);
            }
            EntryExpr::MapEntry(entry) => {
                collect_free_variables(&entry.key, bindings, variables);
                collect_free_variables(&entry.value, bindings, variables);
            }
        }
    }
}

/// Compiles a CEL condition used by computed groups or grants.
pub fn compile_condition(condition: &str) -> KernelResult<Program> {
    Program::compile(condition)
        .map_err(|reason| KernelError::new(format!("invalid cel condition: {reason}")))
}

/// Persisted AuthZ conditions and signal filters can use list and map
/// `contains`, `max`, and `min`.
pub fn base_context() -> Context<'static, 'static> {
    let mut env = Env::stdlib();
    for (target, id) in [
        (types::LIST_TYPE, "ankole_list_contains"),
        (types::MAP_TYPE, "ankole_map_contains"),
    ] {
        env.add_member_overload("contains", id, target, vec![types::DYN_TYPE], |args| {
            let container = args[0]
                .as_container()
                .expect("contains receiver is a list or map");
            let contains = container.contains(args[1].as_ref())?;
            Ok(CowVal::owned(CelBool::from(contains)))
        })
        .expect("list and map contains are absent from the CEL standard library");
    }

    let mut context = Context::with_env(Arc::new(env));
    context
        .add_function("max", functions::max)
        .expect("max is absent from the CEL standard library");
    context
        .add_function("min", functions::min)
        .expect("min is absent from the CEL standard library");
    context
}

/// The kernel does not fetch DB state. The caller must pass every variable a condition can read.
pub fn build_context(variables: Vec<(&str, JSONValue)>) -> KernelResult<Context<'static, 'static>> {
    let mut context = base_context();

    for (name, value) in variables {
        context.add_variable(name, value).map_err(|reason| {
            KernelError::new(format!("invalid cel variable {name:?}: {reason}"))
        })?;
    }

    Ok(context)
}

/// Non-boolean results are diagnostics. Grants fail closed on invalid persisted data.
pub fn execute_bool(
    program: &Program,
    context: &Context<'_, '_>,
) -> std::result::Result<bool, BoolEvalError> {
    match program.execute(context) {
        Ok(CelValue::Bool(value)) => Ok(value),
        Ok(value) => Err(BoolEvalError::ResultType(format!(
            "condition returned {}",
            value.type_of()
        ))),
        Err(reason) => Err(BoolEvalError::Execution(reason.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn free_variables_follow_nested_and_shadowed_comprehension_scopes() {
        for (source, expected) in [
            ("[1].exists(resource, resource == 1)", vec![]),
            ("resource.exists(resource, resource == 1)", vec!["resource"]),
            ("[1].exists(x, [2].exists(x, x == 2) && x == 1)", vec![]),
            (
                "[1].exists(resource, [resource].all(action, action == resource)) && resource != ''",
                vec!["resource"],
            ),
            (
                "['10.0.0.1'].exists(ip, context.request.ip == ip) && principal.status == 'active'",
                vec!["context", "principal"],
            ),
            (
                "[1].map(resource, {resource: principal.uid}).exists(action, action[1] == principal.uid)",
                vec!["principal"],
            ),
        ] {
            assert_eq!(
                condition_free_variables(source).unwrap(),
                expected,
                "{source}"
            );
        }
    }

    #[test]
    fn comprehension_initializers_and_result_use_their_own_scopes() {
        use cel::common::ast::ComprehensionExpr;

        let ident = |name: &str| IdedExpr {
            id: 0,
            expr: Expr::Ident(name.to_owned()),
        };
        let expression = IdedExpr {
            id: 0,
            expr: Expr::Comprehension(Box::new(ComprehensionExpr {
                iter_var: "item".to_owned(),
                iter_var2: Some("value".to_owned()),
                accu_var: "accumulator".to_owned(),
                iter_range: ident("item"),
                accu_init: ident("accumulator"),
                loop_cond: ident("item"),
                loop_step: ident("value"),
                result: ident("value"),
            })),
        };
        let mut variables = BTreeSet::new();
        collect_free_variables(&expression, &mut Vec::new(), &mut variables);
        assert_eq!(variables, BTreeSet::from(["accumulator", "item", "value"]));
    }

    #[test]
    fn authorization_validators_enforce_their_variable_contracts() {
        assert!(
            validate_condition_source(
                "principal.uid != '' && resource != '' && action != '' && context.request.ip != ''"
            )
            .is_ok()
        );
        assert!(validate_condition_source("unknown == true").is_err());
        assert!(
            validate_drive_condition_source("['10.0.0.1'].exists(ip, context.request.ip == ip)")
                .is_ok()
        );
        assert!(validate_drive_condition_source("[1].exists(resource, resource == 1)").is_ok());
        for source in [
            "resource == 'page'",
            "action == 'node_view'",
            "resource.exists(resource, resource == 1)",
            "[1].exists(x, x == 1) && x == 1",
            "[",
        ] {
            assert!(validate_drive_condition_source(source).is_err(), "{source}");
        }
        assert!(condition_free_variables("[").is_err());
    }

    #[test]
    fn preserves_supported_functions_for_host_variables_and_literals() {
        let context = build_context(vec![
            ("roles", json!(["admin", "operator"])),
            ("claims", json!({"active": true})),
        ])
        .unwrap();

        for source in [
            "'hello world'.contains('hello')",
            "roles.contains('admin') && !roles.contains('guest')",
            "claims.contains('active') && !claims.contains('missing')",
            "[1, 2, 3].contains(2) && ![].contains(2)",
            "{1: 'one'}.contains(1) && !{}.contains('missing')",
            "max(1, 3, 2) == 3 && min(4, 2, 8) == 2",
            "max([1, 3, 2]) == 3 && min([4, 2, 8]) == 2",
        ] {
            let program = compile_condition(source).unwrap();
            assert_eq!(execute_bool(&program, &context), Ok(true), "{source}");
        }
    }
}
