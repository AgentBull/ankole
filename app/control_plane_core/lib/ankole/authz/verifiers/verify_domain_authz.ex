defmodule Ankole.AuthZ.Verifiers.VerifyDomainAuthz do
  @moduledoc false
  use Spark.Dsl.Verifier

  defp native_authorizer?(resource),
    do: Enum.any?(Ash.Resource.Info.authorizers(resource), &Ankole.AuthZ.Dsl.native_authorizer?/1)

  def verify(dsl) do
    resources = Ash.Domain.Info.resources(dsl)

    routes =
      AshJsonApi.Domain.Info.routes(dsl) ++
        Enum.flat_map(resources, fn resource ->
          if AshJsonApi.Resource in Spark.extensions(resource),
            do: Enum.map(AshJsonApi.Resource.Info.routes(resource), &%{&1 | resource: resource}),
            else: []
        end)

    protected? = Enum.any?(resources, &native_authorizer?/1)

    bad_route =
      Enum.find(routes, fn route ->
        resource = route.resource

        not native_authorizer?(resource) or
          Ankole.AuthZ.Extension not in Spark.extensions(resource) or
          Enum.any?([route.action, route.read_action], fn action ->
            action && is_nil(Ankole.AuthZ.Dsl.rule(resource, action))
          end)
      end)

    if bad_route || ((routes != [] or protected?) and not AshJsonApi.Domain.Info.authorize?(dsl)) do
      {:error,
       Spark.Error.DslError.exception(
         module: Spark.Dsl.Verifier.get_persisted(dsl, :module),
         path: [:json_api],
         message:
           "Protected routes must enable authorization and declare every action: #{inspect(bad_route)}"
       )}
    else
      :ok
    end
  end
end
