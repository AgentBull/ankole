defmodule Ankole.Connectors.Jobs.RefreshAccounts do
  @moduledoc "Refreshes idle OAuth connections before their refresh grant expires."
  use Ankole.Job, tenancy: :site, queue: :default, max_attempts: 3
  require Ash.Query
  alias Ankole.Connectors.{ConnectedAccount, Registry, Store, TokenRefresher}

  @impl Ankole.Job
  def run(_job) do
    threshold = DateTime.add(DateTime.utc_now(), 7 * 86_400)

    ConnectedAccount
    |> Ash.Query.for_read(:across_tenants)
    |> Ash.Query.filter(
      status == "active" and not is_nil(refresh_expires_at) and refresh_expires_at < ^threshold
    )
    |> Ankole.Ash.read_across_tenants!()
    |> Enum.each(fn account ->
      Ankole.Repo.with_tenant(account.tenant_id, fn ->
        with {:ok, config} <- Store.get_auth_config(account.auth_config_id),
             {:ok, adapter} <- Registry.adapter(account.plugin_id),
             do: TokenRefresher.refresh(config, account, adapter)
      end)
    end)

    :ok
  end
end
