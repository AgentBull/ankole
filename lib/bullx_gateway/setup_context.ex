defmodule BullXGateway.SetupContext do
  @moduledoc """
  Setup-time orchestration for Gateway adapter configuration.

  Owns the persistence flow that ties adapter entry storage, runtime
  reconciliation, and the derived accounts authn match rules together so the
  HTTP controller can stay focused on `Plug.Conn` concerns.
  """

  alias BullX.Config.Accounts, as: AccountsConfig
  alias BullXGateway.AdapterConfig
  alias BullXGateway.AdapterSupervisor

  @accounts_match_rules_key "bullx.accounts.authn_match_rules"
  @managed_external_org_members_rule "setup.gateway.external_org_members"

  @doc """
  Persists the encoded adapter list, reconciles the running adapter supervisor,
  and synchronises the accounts authn match rule managed by the setup wizard.
  """
  @spec persist_adapters(String.t(), [map()]) :: :ok | {:error, term()}
  def persist_adapters(encoded, entries) when is_binary(encoded) and is_list(entries) do
    with :ok <- BullX.Config.put(AdapterConfig.config_key(), encoded),
         :ok <- reconcile_gateway_adapters(entries),
         :ok <- sync_authn_match_rules(entries) do
      :ok
    end
  end

  @spec reconcile_gateway_adapters([map()]) :: :ok | {:error, term()}
  def reconcile_gateway_adapters(entries) when is_list(entries) do
    with {:ok, specs} <- AdapterConfig.runtime_specs(entries) do
      AdapterSupervisor.reconcile_configured_channels(specs)
    end
  end

  @spec sync_authn_match_rules([map()]) :: :ok | {:error, term()}
  def sync_authn_match_rules(entries) when is_list(entries) do
    entries
    |> external_tenant_keys()
    |> update_external_org_members_rule()
  end

  defp external_tenant_keys(entries) do
    entries
    |> Enum.filter(&Map.get(&1, "enabled", true))
    |> Enum.flat_map(&external_tenant_key/1)
    |> Enum.uniq()
  end

  defp external_tenant_key(%{
         "authn" => %{
           "external_org_members" => %{"enabled" => true, "tenant_key" => tenant_key}
         }
       })
       when is_binary(tenant_key) and tenant_key != "",
       do: [tenant_key]

  defp external_tenant_key(_entry), do: []

  defp update_external_org_members_rule(tenant_keys) do
    rules =
      AccountsConfig.accounts_authn_match_rules!()
      |> Enum.reject(&managed_external_org_members_rule?/1)
      |> append_external_org_members_rule(tenant_keys)

    with {:ok, encoded} <- Jason.encode(rules) do
      BullX.Config.put(@accounts_match_rules_key, encoded)
    end
  end

  defp managed_external_org_members_rule?(%{"managed_by" => @managed_external_org_members_rule}),
    do: true

  defp managed_external_org_members_rule?(_rule), do: false

  defp append_external_org_members_rule(rules, []), do: rules

  defp append_external_org_members_rule(rules, tenant_keys) do
    rules ++
      [
        %{
          "result" => "allow_create_user",
          "op" => "equals_any",
          "source_path" => "metadata.tenant_key",
          "values" => tenant_keys,
          "managed_by" => @managed_external_org_members_rule
        }
      ]
  end
end
