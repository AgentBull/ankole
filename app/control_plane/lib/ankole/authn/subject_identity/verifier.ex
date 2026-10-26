defmodule Ankole.Authn.SubjectIdentity.Verifier do
  @moduledoc false
  use Spark.Dsl.Verifier

  def verify(dsl) do
    identity = Ash.Resource.Info.identity(dsl, :subject)

    if (identity && identity.keys == [:provider, :external_id]) and
         Ash.Resource.Info.multitenancy_attribute(dsl) == :tenant_id do
      :ok
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Spark.Dsl.Verifier.get_persisted(dsl, :module),
         path: [:authn],
         message: "Enterprise subjects need a unique tenant provider/external_id binding."
       )}
    end
  end
end
