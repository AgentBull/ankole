defmodule Ankole.Upgrade202610 do
  @moduledoc """
  Temporary data upgrade for the 2026-10 tenant and binding changes.

  Mix and Release run this file after schema migrations. To repeat only the data
  steps, run `mix run --no-start -e 'Ankole.Upgrade202610.run()'` with the original
  encryption key and every control-plane replica stopped.

  Remove this file, its Mix alias and its Release call when every supported
  direct-upgrade origin includes these steps and upgrade checks find no old
  identity-provider scope, shared Slack/Teams key or missing application identity.
  """

  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Crypto
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Tenants.Tenant

  @tenant_schema_version 20_261_009_120_000

  @doc false
  def migrate(repo, paths, :up, opts) do
    migrated = Ecto.Migrator.run(repo, paths, :up, opts)

    # A partial schema migration can stop before tenant ownership exists.
    if repo == Repo and @tenant_schema_version in Ecto.Migrator.migrated_versions(repo, opts),
      do: run()

    migrated
  end

  @doc "Runs the temporary data steps without starting the control-plane application."
  @spec run() :: :ok
  def run do
    {:ok, _apps} = Application.ensure_all_started(:ankole_kernel)
    {:ok, _apps} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _apps} = Application.ensure_all_started(:req)

    {:ok, :ok, _apps} =
      Ecto.Migrator.with_repo(Repo, fn _repo ->
        Repo.without_tenant(fn ->
          migrate_identity_provider_configurations()

          with_processes(
            [{Registry, []}, {Phoenix.PubSub.Supervisor, [name: Ankole.PubSub]}, {Cache, []}],
            &migrate_binding_configurations/0
          )
        end)
      end)

    :ok
  end

  # Stop only the processes this invocation starts. Mix can start the full
  # application after migration, as ecto.setup does when it runs seeds.
  defp with_processes([], fun), do: fun.()

  defp with_processes([{module, opts} | rest], fun) do
    case module.start_link(opts) do
      {:ok, pid} ->
        try do
          with_processes(rest, fun)
        after
          GenServer.stop(pid)
        end

      {:error, {:already_started, _pid}} ->
        with_processes(rest, fun)

      {:error, reason} ->
        raise "failed to start #{inspect(module)} for the 2026-10 upgrade: #{inspect(reason)}"
    end
  end

  # Scope participates in key derivation. Decrypt, seal for the new scope and
  # delete the old row in one transaction; copying ciphertext cannot work.
  defp migrate_identity_provider_configurations do
    case Repo.transact(fn repo ->
           rows =
             repo.all(
               from config in SiteConfig,
                 where:
                   config.scope == "global" and fragment("?->>'type' = 'cipher'", config.value) and
                     (like(config.key, "principals.identity_providers.%") or
                        like(config.key, "principals.entra_id.graph_subscriptions.%")),
                 lock: "FOR UPDATE"
             )

           # A later run remains a no-op after the original tenant is renamed.
           tenant = if rows != [], do: repo.get_by!(Tenant, slug: "default")
           scope = if tenant, do: "tenant:" <> tenant.id

           Enum.reduce_while(rows, {:ok, :migrated}, fn row, result ->
             case migrate_identity_provider_row(repo, row, tenant, scope) do
               :ok -> {:cont, result}
               {:error, reason} -> {:halt, {:error, {row.key, reason}}}
             end
           end)
         end) do
      {:ok, :migrated} -> :ok
      {:error, reason} -> raise "identity provider tenant migration failed: #{inspect(reason)}"
    end
  end

  defp migrate_identity_provider_row(
         repo,
         %{value: %{"type" => "cipher", "value" => cipher}} = row,
         tenant,
         scope
       ) do
    with {:ok, value} <- Crypto.unseal(cipher, "global", row.key),
         {:ok, resealed} <- Crypto.seal(value, scope, row.key),
         {:ok, _} <-
           Repo.with_tenant(tenant.id, fn ->
             repo.insert(
               AppConfig.changeset(%AppConfig{tenant_id: tenant.id}, %{
                 scope: scope,
                 key: row.key,
                 value: %{"type" => "cipher", "value" => resealed}
               })
             )
           end) do
      repo.delete_all(
        from old in SiteConfig, where: old.scope == "global" and old.key == ^row.key
      )

      :ok
    end
  end

  # One transaction covers every reference to each shared binding key.
  defp migrate_binding_configurations do
    {:ok, snapshot} = Ankole.Plugins.Registry.prepare_snapshot()
    specs = Map.values(snapshot.discovered)

    :ok =
      Registry.replace_declarations(
        :plugins,
        Enum.flat_map(specs, & &1.app_config_definitions),
        Enum.flat_map(specs, & &1.app_config_patterns)
      )

    # Only discovery crosses tenants. Each binding write runs in its tenant.
    bindings =
      Repo.across_tenants(fn ->
        Repo.all(from binding in Binding, where: binding.adapter in ["slack", "teams"])
      end)

    bindings
    |> Enum.filter(fn binding ->
      binding.config_ref == "app-config://#{config_module(binding).chat_config_key(binding.name)}"
    end)
    |> Enum.group_by(& &1.config_ref)
    |> Enum.each(fn {"app-config://" <> old_key, bindings} ->
      case Repo.transact(fn repo -> migrate_shared_key(repo, old_key, bindings) end) do
        {:ok, :ok} -> :ok
        {:error, reason} -> raise "binding configuration migration failed: #{inspect(reason)}"
      end
    end)

    backfill_application_identities(specs)
  end

  defp migrate_shared_key(repo, old_key, bindings) do
    with {:ok, config} <- AppConfigure.get_global_by_key_in_tx(repo, old_key),
         :ok <- migrate_bindings(repo, bindings, config) do
      old_ref = "app-config://#{old_key}"

      remaining? =
        Repo.across_tenants(fn ->
          repo.exists?(from binding in Binding, where: binding.config_ref == ^old_ref)
        end)

      unless remaining? do
        repo.delete_all(
          from row in SiteConfig, where: row.scope == "global" and row.key == ^old_key
        )
      end

      {:ok, :ok}
    else
      :error -> {:error, {:missing_binding_configuration, old_key}}
      {:error, _reason} = error -> error
    end
  end

  defp migrate_bindings(repo, bindings, config) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      new_key = config_module(binding).binding_config_key(binding.agent_uid, binding.name)

      result =
        Repo.with_tenant(binding.tenant_id, fn ->
          with :ok <- ensure_destination(repo, new_key, config),
               {:ok, _write} <- AppConfigure.put_global_by_key_in_tx(repo, new_key, config),
               {:ok, _binding} <-
                 binding
                 |> Ecto.Changeset.change(config_ref: "app-config://#{new_key}")
                 |> repo.update() do
            :ok
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_destination(repo, key, config) do
    case AppConfigure.get_global_by_key_in_tx(repo, key) do
      :error -> :ok
      {:ok, ^config} -> :ok
      {:ok, _different} -> {:error, {:binding_configuration_key_conflict, key}}
      {:error, _reason} = error -> error
    end
  end

  # Resolve credentials outside transactions. Report the owning tenant and key
  # on failure so the operator can repair the configuration and repeat the command.
  defp backfill_application_identities(specs) do
    declarations = Enum.flat_map(specs, & &1.adapter_declarations)
    bindings = Repo.across_tenants(fn -> Repo.all(Binding) end)

    Enum.each(bindings, fn binding ->
      declaration =
        Enum.find(
          declarations,
          &(&1[:contract_id] == "signals.adapter" and &1[:id] == binding.adapter)
        )

      if declaration do
        "app-config://" <> key = binding.config_ref
        backfill_identity(binding.tenant_id, "global", key, declaration[:config_module], :binding)
      end
    end)

    Enum.each(Repo.all(Tenant), fn tenant ->
      Repo.with_tenant(tenant.id, fn ->
        {:ok, providers} =
          AppConfigure.get_tenant_by_key_in_tx(Repo, "principals.identity_providers.active")

        Enum.each(providers, fn provider ->
          declaration =
            Enum.find(
              declarations,
              &(&1[:contract_id] == "principals.identity_provider" and
                  &1[:id] == provider["adapter_id"])
            )

          if declaration,
            do:
              backfill_identity(
                tenant.id,
                "tenant:" <> tenant.id,
                provider["config_key"],
                declaration[:module],
                :identity_provider
              )
        end)
      end)
    end)

    :ok
  end

  defp backfill_identity(tenant_id, scope, key, module, source) do
    row =
      Repo.with_tenant(tenant_id, fn ->
        Repo.get_by(AppConfig.for_scope(scope), scope: scope, key: key)
      end)

    if row && not Map.has_key?(row.value, "platform_application") do
      result =
        with {:ok, definition} <- Registry.require_key(key),
             {:ok, config} <- AppConfigure.Codec.load(definition, scope, key, row.value),
             {:ok, application} <- Bindings.resolve_platform_application(module, config, source) do
          Repo.with_tenant(tenant_id, fn ->
            Repo.transact(&record_identity_in_tx(&1, row, config, application))
          end)
        end

      case result do
        {:ok, :recorded} ->
          :ok

        {:error, reason} ->
          raise "platform application migration failed for tenant #{tenant_id}, configuration #{key}: #{inspect(reason)}; repair the configuration and rerun mix ecto.migrate or Release.migrate"
      end
    end
  end

  defp record_identity_in_tx(repo, row, config, application) do
    schema = AppConfig.for_scope(row.scope)

    locked =
      repo.one(
        from config in schema,
          where: config.scope == ^row.scope and config.key == ^row.key,
          lock: "FOR UPDATE"
      )

    if locked.value == row.value do
      with :ok <- Bindings.validate_platform_application_in_tx(repo, application),
           :ok <-
             Bindings.record_platform_application_in_tx(
               repo,
               {config, row.scope, row.key},
               application
             ),
           do: {:ok, :recorded}
    else
      {:error, :configuration_changed}
    end
  end

  defp config_module(%Binding{adapter: "slack"}), do: Ankole.Plugins.SlackAdapter.Config
  defp config_module(%Binding{adapter: "teams"}), do: Ankole.Plugins.Microsoft365Adapter.Config
end
