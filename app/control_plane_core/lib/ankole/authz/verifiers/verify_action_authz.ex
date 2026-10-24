defmodule Ankole.AuthZ.Verifiers.VerifyActionAuthz do
  @moduledoc false
  use Spark.Dsl.Verifier

  def verify(dsl) do
    entities = Spark.Dsl.Verifier.get_entities(dsl, [:authz])
    rules = Enum.filter(entities, &is_struct(&1, Ankole.AuthZ.Rule))
    params = Enum.filter(entities, &is_struct(&1, Ankole.AuthZ.Param))
    routes = AshJsonApi.Resource.Info.routes(dsl)
    covered = Enum.map(rules, & &1.name)

    invalid =
      Enum.find(routes, fn route ->
        Enum.any?([route.action, route.read_action], &(&1 && &1 not in covered))
      end)

    public? = Spark.Dsl.Verifier.get_option(dsl, [:authz], :scope) == :public

    bad_rule =
      Enum.find(rules, fn rule ->
        is_nil(Ash.Resource.Info.action(dsl, rule.name)) or
          public? != (rule.check == :public) or
          (rule.check == :grant and (is_nil(rule.resource) or is_nil(rule.action))) or
          Enum.any?(Regex.scan(~r/\{(\w+)\}/, rule.resource || ""), fn [_, key] ->
            not Enum.any?(
              params,
              &(to_string(&1.name) == key and
                  &1.type in [
                    :principal_key,
                    :uuid,
                    :group,
                    :string,
                    :provider_id,
                    :model_profile
                  ])
            )
          end)
      end)

    if invalid || bad_rule do
      {:error,
       Spark.Error.DslError.exception(
         module: Spark.Dsl.Verifier.get_persisted(dsl, :module),
         path: [:authz],
         message:
           "Every routed action needs one authorization rule with explicit target resolvers: #{inspect(invalid || bad_rule)}"
       )}
    else
      :ok
    end
  end
end
