defmodule Ankole.Authn.SiteCredentialResource.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  def verify(dsl) do
    required = [:principal_uid, :provider, :identifier, :kind]
    identity = Ash.Resource.Info.identity(dsl, :subject)

    complete? =
      Enum.all?(required, fn name ->
        match?(%{allow_nil?: false}, Ash.Resource.Info.attribute(dsl, name))
      end)

    subject? = match?(%{keys: [:provider, :identifier]}, identity)

    if complete? and subject? and Ash.Resource.Info.multitenancy_attribute(dsl) == :tenant_id do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Spark.Dsl.Verifier.get_persisted(dsl, :module),
         path: [:authn],
         message:
           "Site credentials need tenant ownership, a human owner, kind, provider, and a unique provider/identifier."
       )}
    end
  end
end
