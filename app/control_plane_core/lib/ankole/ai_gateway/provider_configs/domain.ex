defmodule Ankole.AIGateway.ProviderConfigs.Domain do
  @moduledoc "Durable provider endpoints and encrypted credential pools."
  use Ash.Domain

  resources do
    resource(Ankole.AIGateway.ProviderConfigs.Provider)
  end
end
