defmodule Ankole.Connectors.Browser.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Ankole.Connectors.{Accounts, OAuth, Registry, Store, Triggers}

  @impl true
  def run(input, _opts, %{actor: %{principal: actor}}) do
    attrs = Map.reject(input.arguments, fn {_key, value} -> is_nil(value) end)

    {result, encode} =
      case input.action.name do
        :catalog ->
          {{:ok, Registry.catalog()},
           &%{
             connectors: &1,
             can_manage: Store.admin(actor) == :ok,
             oauth_callback_url: OAuth.callback_url()
           }}

        :connections ->
          {Store.list_auth_configs(actor), &%{connections: &1}}

        :create_connection ->
          {Store.create_auth_config(actor, attrs), &%{connection: Store.public(&1)}}

        :update_connection ->
          {Store.update_auth_config(actor, attrs.id, attrs), &%{connection: Store.public(&1)}}

        :accounts ->
          {Accounts.list_accounts(actor, attrs[:scope] || "mine"), &%{accounts: &1}}

        :connect_personal_credentials ->
          {Accounts.connect_credentials(actor, attrs, "human"), &%{account: Accounts.public(&1)}}

        :connect_team_credentials ->
          {Accounts.connect_credentials(actor, attrs, "app"), &%{account: Accounts.public(&1)}}

        :disconnect ->
          {Accounts.disconnect_account(actor, attrs.id), &%{account: Accounts.public(&1)}}

        :oauth_begin ->
          {OAuth.begin(actor, attrs), &Function.identity/1}

        :oauth_claim ->
          {OAuth.claim(actor, attrs.completion_code), &%{account: &1}}

        :triggers ->
          {Triggers.list(actor), &%{triggers: &1}}

        :create_trigger ->
          {Triggers.create(actor, attrs), &%{trigger: &1}}

        :retry_trigger ->
          {Triggers.retry(actor, attrs.id), &%{trigger: &1}}

        :delete_trigger ->
          {Triggers.delete(actor, attrs.id), &%{trigger: &1}}
      end

    Ankole.Pod.APIError.result(result, encode)
  end
end
