defmodule Ankole.Connectors.LegacyUpgrade do
  @moduledoc "Imports existing tenant integration credentials before plugin connections start."
  alias Ankole.Connectors.LegacyConfig
  alias Ankole.Repo

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(_opts) do
    run()
    :ignore
  end

  def run do
    Enum.reduce(Ankole.Tenants.list(), :ok, fn tenant, result ->
      case Repo.with_tenant(tenant.id, &migrate_tenant/0) do
        :ok ->
          result

        {:error, reason} ->
          Ankole.Logging.warning(
            "connectors.credential_import_failed",
            "Some integration credentials were not imported; repair their configuration and rerun Ankole.Connectors.LegacyUpgrade.run/0",
            %{tenant_id: tenant.id}
          )

          if result == :ok,
            do: {:error, {:connector_credentials_migration, tenant.id, reason}},
            else: result
      end
    end)
  end

  defp migrate_tenant do
    with {:ok, providers} <- Ankole.IdentityProviders.Config.active_providers() do
      bindings =
        Ankole.Signals.list_bindings!(
          query: [
            filter: [
              auth_config_id: [is_nil: true],
              adapter: [
                in: ~w(lark slack dingtalk wecom teams discord telegram whatsapp line email)
              ]
            ]
          ]
        )

      (Enum.map(providers, &{:provider, &1}) ++ Enum.map(bindings, &{:binding, &1}))
      |> Enum.sort_by(fn
        {:provider, provider} -> provider["enabled"] == false
        {:binding, binding} -> not binding.enabled
      end)
      |> each(fn
        {:provider, provider} -> migrate_provider(provider)
        {:binding, binding} -> migrate_binding(binding)
      end)
    end
  end

  defp migrate_provider(provider) do
    with {:ok, imported?} <- imported_provider?(provider["config_key"]) do
      if imported?, do: :ok, else: import_provider(provider)
    end
  end

  defp import_provider(provider) do
    key = provider["config_key"]

    with {:ok, config} <- Ankole.AppConfigure.read_configuration(key),
         {:ok, adapter} <- Ankole.IdentityProviders.fetch_adapter(provider["adapter_id"]),
         {:ok, module} <- Ankole.IdentityProviders.adapter_module(adapter),
         {:ok, application} <-
           application_identity(key, module, config, :identity_provider),
         {:ok, write} <-
           Repo.transact_top_level(fn ->
             with {:ok, stored, _id} <-
                    LegacyConfig.ensure_in_tx(
                      provider["plugin_id"],
                      config,
                      application,
                      "system",
                      status(provider["enabled"])
                    ),
                  do: Ankole.AppConfigure.put_tenant_by_key_in_tx(key, stored)
           end),
         {:ok, _} <- Ankole.AppConfigure.cache_committed_write(write),
         do: :ok
  end

  defp imported_provider?(key) do
    scope = "tenant:" <> Repo.tenant_id!()

    with {:ok, tenant_row} <- Ankole.AppConfigure.get_app_config(scope, key),
         {:ok, row, stored_scope} <-
           if(tenant_row, do: {:ok, tenant_row, scope}, else: global_row(key)) do
      case row do
        %{value: %{"type" => "cipher", "value" => value}} ->
          with {:ok, config} <- Ankole.AppConfigure.Crypto.unseal(value, stored_scope, key),
               do: {:ok, is_binary(config["authConfigId"])}

        _ ->
          {:ok, false}
      end
    end
  end

  defp global_row(key) do
    with {:ok, row} <- Ankole.AppConfigure.get_site_config("global", key),
         do: {:ok, row, "global"}
  end

  defp migrate_binding(binding) do
    key = String.replace_prefix(binding.config_ref, "app-config://", "")

    with {:ok, config} <- Ankole.Signals.Bindings.stored_binding_config(binding),
         {:ok, definition} <- Ankole.Signals.Adapters.fetch(binding.adapter),
         {:ok, application} <-
           application_identity(key, definition.config_module, config, :binding),
         {:ok, write} <-
           Repo.transact_top_level(fn ->
             with {:ok, stored, id} <-
                    LegacyConfig.ensure_in_tx(
                      binding.adapter,
                      config,
                      application,
                      "system",
                      status(binding.enabled)
                    ),
                  {:ok, _} <-
                    Ankole.Signals.link_binding_auth_config(binding, %{auth_config_id: id}),
                  do:
                    Ankole.AppConfigure.put_global_by_key_in_tx(
                      key,
                      stored
                    )
           end),
         {:ok, _} <- Ankole.AppConfigure.cache_committed_write(write),
         do: :ok
  end

  defp application_identity(key, module, config, source) do
    scope = "tenant:" <> Repo.tenant_id!()

    with {:ok, tenant_row} <- Ankole.AppConfigure.get_app_config(scope, key),
         {:ok, row, _scope} <-
           if(tenant_row, do: {:ok, tenant_row, scope}, else: global_row(key)) do
      case row do
        %{value: %{"platform_application" => application}} when is_binary(application) ->
          {:ok, application}

        _ ->
          Ankole.Signals.Bindings.resolve_platform_application(module, config, source)
      end
    end
  end

  defp status(false), do: "disabled"
  defp status(_), do: "active"

  defp each(items, fun) do
    Enum.reduce(items, :ok, fn {kind, item} = entry, result ->
      case fun.(entry) do
        :ok ->
          result

        {:error, reason} ->
          key = if kind == :provider, do: item["config_key"], else: item.config_ref

          Ankole.Logging.warning(
            "connectors.configuration_import_failed",
            "Integration configuration was preserved because its credentials could not be imported",
            %{tenant_id: Repo.tenant_id!(), configuration: key}
          )

          if result == :ok, do: {:error, {key, reason}}, else: result
      end
    end)
  end
end
