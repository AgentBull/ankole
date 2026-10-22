defmodule Ankole.AIGateway.ProviderConfigs.Domain do
  @moduledoc "Durable provider endpoints and encrypted credential pools."
  use Ankole.Ash.Domain

  resources do
    resource Ankole.AIGateway.ProviderConfigs.Provider do
      define(:get_provider, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_providers, action: :read)
      define(:create_provider, action: :create)
      define(:configure_provider, action: :configure)
      define(:enable_provider, action: :enable)
      define(:disable_provider, action: :disable)
      define(:add_credential_provider, action: :add_credential)
      define(:replace_credential_provider, action: :replace_credential)
      define(:remove_credential_provider, action: :remove_credential)
      define(:select_strategy_provider, action: :select_strategy)
      define(:refresh_credential_provider, action: :refresh_credential)
      define(:cooldown_provider, action: :cooldown)
      define(:remove_provider, action: :remove)
    end
  end
end
