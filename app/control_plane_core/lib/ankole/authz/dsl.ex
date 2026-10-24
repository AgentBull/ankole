defmodule Ankole.AuthZ.Dsl do
  @moduledoc false
  def native_authorizer?(module),
    do:
      Code.ensure_loaded?(module) and function_exported?(module, :__ankole_authz__?, 0) and
        module.__ankole_authz__?()

  def rules(resource),
    do:
      Spark.Dsl.Extension.get_entities(resource, [:authz])
      |> Enum.filter(&is_struct(&1, Ankole.AuthZ.Rule))

  def rule(resource, name), do: Enum.find(rules(resource), &(&1.name == name))

  def params(resource),
    do:
      Spark.Dsl.Extension.get_entities(resource, [:authz])
      |> Enum.filter(&is_struct(&1, Ankole.AuthZ.Param))

  def sections do
    [
      %Spark.Dsl.Section{
        name: :authz,
        schema: [
          scope: [
            type: {:in, [:site_console, :tenant_console, :agent, :pod, :self, :public]},
            required: true
          ]
        ],
        entities: [
          %Spark.Dsl.Entity{
            name: :resolve_param,
            target: Ankole.AuthZ.Param,
            args: [:name, :type],
            schema: [name: [type: :atom, required: true], type: [type: :atom, required: true]]
          },
          %Spark.Dsl.Entity{
            name: :allow,
            target: Ankole.AuthZ.Rule,
            args: [:name],
            schema: [
              name: [type: :atom, required: true],
              resource: [type: :string],
              action: [type: :string],
              permissions: [type: {:mfa_or_fun, 4}],
              check: [type: {:in, [:grant, :guardrail, :pod_filter, :public]}, default: :grant]
            ]
          }
        ]
      }
    ]
  end
end
