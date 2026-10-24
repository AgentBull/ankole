defmodule Ankole.Authn.Strategies.Oidc do
  @moduledoc "Pod-scoped enterprise OAuth and OIDC verification through the provider owner."
  defstruct name: :enterprise,
            scope: :tenant,
            provider_id: :dynamic_tenant_provider,
            __spark_metadata__: nil
end
