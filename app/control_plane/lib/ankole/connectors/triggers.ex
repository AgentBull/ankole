defmodule Ankole.Connectors.Triggers do
  @moduledoc "Reconciles external subscriptions against live Signal Bindings."
  require Ash.Query
  alias Ankole.Connectors.{Accounts, AuthConfig, Credentials, OAuth, Registry, Store, Trigger}
  alias Ankole.Repo

  def event_connection_needed?(auth_config_id) do
    trigger_refs =
      Trigger
      |> Ash.Query.filter(auth_config_id == ^auth_config_id)
      |> Ankole.Ash.read!()
      |> Enum.map(&("connector-trigger://" <> &1.id))

    prefix = "connector://" <> auth_config_id <> "/"

    Ankole.Signals.list_bindings!(
      query: [filter: [enabled: true, unavailable_reason: [is_nil: true]]]
    )
    |> Enum.any?(&(String.starts_with?(&1.config_ref, prefix) or &1.config_ref in trigger_refs))
  end

  def list_event_triggers(auth_config_id, trigger_type, scope_key) do
    with {:ok, triggers} <-
           Trigger
           |> Ash.Query.filter(
             auth_config_id == ^auth_config_id and trigger_type == ^trigger_type and
               scope_key == ^scope_key and status == "active"
           )
           |> Ankole.Ash.read(),
         do: {:ok, Enum.filter(triggers, &active_account?/1)}
  end

  def list(actor) do
    with :ok <- Store.member(actor) do
      actor = unwrap(actor)

      query =
        if Ankole.AuthZ.pod_admin?(actor.uid) do
          Ash.Query.new(Trigger)
        else
          ids = actor.uid |> Ankole.Principals.authority_uid() |> Accounts.owned_ids()
          Ash.Query.filter(Trigger, connected_account_id in ^ids)
        end

      {:ok, query |> Ankole.Ash.read!() |> Enum.map(&public/1)}
    end
  end

  def create(actor, attrs) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    with :ok <- Store.member(actor),
         {:ok, config} <- Store.get_auth_config(attrs["auth_config_id"]),
         {:ok, adapter} <- Registry.adapter(config.plugin_id),
         true <- function_exported?(adapter, :reconcile_trigger, 4),
         {:ok, account_id} <- trigger_account(config, attrs["connected_account_id"]),
         :ok <- account_for_config(account_id, config.id),
         :ok <- authorize_selected_account(actor, account_id),
         :ok <- require_grant(actor, config, adapter, attrs["trigger_type"], account_id),
         :ok <- authorize_account(actor, account_id),
         true <- is_binary(attrs["trigger_type"]) and is_binary(attrs["scope_key"]) do
      id = Ankole.Kernel.gen_uuid_v7()

      with {:ok, sealed} <-
             Credentials.seal(
               %{"webhook_secret" => Ankole.Authn.SecretDigest.token()},
               "connector_trigger",
               id
             ),
           {:ok, trigger} <-
             Ankole.Ash.create(Trigger, :create, %{
               id: id,
               auth_config_id: config.id,
               plugin_id: config.plugin_id,
               connected_account_id: account_id,
               trigger_type: attrs["trigger_type"],
               scope_key: attrs["scope_key"],
               config: attrs["config"] || %{},
               sealed_secret: sealed
             }),
           do: {:ok, public(trigger)}
    else
      false -> {:error, :unsupported_connector_trigger}
      error -> error
    end
  end

  def delete(actor, id) do
    with {:ok, trigger} <- get(id), :ok <- authorize(actor, trigger) do
      Repo.transact_top_level(fn ->
        reference = "connector-trigger://" <> id
        :ok = Ankole.Signals.lock_source_bindings_in_tx(reference)

        row =
          Trigger
          |> Ash.Query.filter(id == ^id)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [id]})

        if row do
          with :ok <- Ankole.Signals.remove_disabled_source_bindings_in_tx(reference),
               {:ok, deleting} <-
                 Ankole.Ash.update(row, :update, %{status: "deleting", last_error: nil}),
               {:ok, _} <-
                 Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => id})) do
            {:ok, public(deleting)}
          end
        else
          {:error, :not_found}
        end
      end)
    end
  end

  def retry(actor, id) do
    with {:ok, trigger} <- get(id), :ok <- authorize(actor, trigger) do
      Repo.transact_top_level(fn ->
        row =
          Trigger
          |> Ash.Query.filter(id == ^id)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [id]})

        cond do
          is_nil(row) ->
            {:error, :not_found}

          row.lease_expires_at &&
              DateTime.compare(row.lease_expires_at, DateTime.utc_now()) == :gt ->
            {:error, :connector_trigger_busy}

          true ->
            with :ok <- require_retry_grant(actor, row),
                 {:ok, retried} <-
                   Ankole.Ash.update(row, :update, %{
                     status: if(deleting?(row), do: "deleting", else: "provisioning"),
                     last_error: nil,
                     lease_expires_at: nil
                   }),
                 {:ok, _} <-
                   Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => id})),
                 do: {:ok, public(retried)}
        end
      end)
    end
  end

  defp require_retry_grant(actor, trigger) do
    if deleting?(trigger) do
      :ok
    else
      with {:ok, config} <- Store.get_auth_config(trigger.auth_config_id),
           {:ok, adapter} <- Registry.adapter(config.plugin_id),
           do:
             require_grant(
               actor,
               config,
               adapter,
               trigger.trigger_type,
               trigger.connected_account_id
             )
    end
  end

  defp deleting?(trigger),
    do:
      trigger.status == "deleting" or
        (is_map(trigger.last_error) and trigger.last_error["operation"] == "delete")

  defp require_grant(actor, config, adapter, type, account_id) do
    with {:ok, declaration} <-
           Ankole.Plugins.Registry.fetch_adapter("connectors.connector", config.plugin_id),
         definition when not is_nil(definition) <-
           Enum.find(Map.get(declaration, :trigger_types, []), &(&1.id == type)),
         {:ok, account} <- Accounts.get_by_id(account_id) do
      require_personal_grant(unwrap(actor), config, adapter, definition, account)
    else
      nil -> {:error, :unsupported_connector_trigger}
      error -> error
    end
  end

  defp require_personal_grant(
         actor,
         config,
         adapter,
         %{requires_personal_account: true} = definition,
         account
       ) do
    required = Map.get(definition, :oauth_scopes, [])

    owner =
      if account,
        do: account.owner_principal_uid,
        else: Ankole.Principals.authority_uid(actor.uid)

    with {:ok, %{type: :human, status: :active}} <- Ankole.Principals.get_principal(owner) do
      if account && account.subject_kind == "human" && Accounts.valid?(account) &&
           adapter.scopes_satisfied?(required, account.granted_scopes, config) do
        :ok
      else
        personal_consent(actor, config, definition, required, owner)
      end
    else
      _ -> {:error, :human_authority_required}
    end
  end

  defp require_personal_grant(_actor, _config, _adapter, _definition, _account), do: :ok

  defp personal_consent(actor, config, definition, required, owner) do
    {:error, details} =
      OAuth.consent_required(config.slug, required, %{"trigger_type" => definition.id})

    details = Map.put(details, :owner_principal_uid, owner)

    details =
      if owner == Ankole.Principals.authority_uid(actor.uid),
        do: details,
        else: Map.delete(details, :authorization_url)

    {:error, details}
  end

  def get(id) do
    case Trigger |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :not_found}
      result -> result
    end
  end

  def get_ingress(id) do
    with {:ok, trigger} <- get(id),
         true <- trigger.status in ["active", "provisioning"] and active_account?(trigger),
         {:ok, config} <- Store.get_auth_config(trigger.auth_config_id),
         {:ok, root} <- Credentials.secret(config),
         {:ok, secret} <-
           Credentials.unseal(trigger.sealed_secret, "connector_trigger", trigger.id) do
      {:ok, %{auth_config: config, trigger: trigger, secret: Map.merge(root, secret)}}
    else
      false -> {:error, :connector_trigger_inactive}
      error -> error
    end
  end

  def authorize(actor, trigger),
    do: authorize_account(unwrap(actor), trigger.connected_account_id)

  defp unwrap(%Ankole.AuthZ.Actor{principal: actor}), do: actor
  defp unwrap(actor), do: actor
  defp authorize_selected_account(_actor, nil), do: :ok
  defp authorize_selected_account(actor, id), do: authorize_account(actor, id)
  defp authorize_account(actor, nil), do: Store.admin(actor)

  defp authorize_account(actor, id) do
    with :ok <- Store.member(actor), {:ok, account} <- Accounts.get_by_id(id) do
      if account && account.owner_principal_uid == Ankole.Principals.authority_uid(actor.uid),
        do: :ok,
        else: Store.admin(actor)
    end
  end

  def source_access(actor, "connector-trigger://" <> id) do
    result =
      if Repo.in_transaction?() do
        row =
          Trigger
          |> Ash.Query.filter(id == ^id)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [id]})

        if row, do: {:ok, row}, else: {:error, :not_found}
      else
        get(id)
      end

    with {:ok, trigger} <- result,
         true <- trigger.status != "deleting",
         do: authorize(actor, trigger),
         else: (
           false -> {:error, :connector_trigger_inactive}
           error -> error
         )
  end

  def source_access(actor, "connector://" <> suffix) do
    with [id, stream] when stream != "" <- String.split(suffix, "/", parts: 2),
         {:ok, _} <- Store.get_auth_config_for_configuration(id),
         do: Store.admin(unwrap(actor)),
         else: (_ -> {:error, :invalid_signal_source})
  end

  def reconcile(id), do: reconcile(id, :normal)

  defp reconcile(id, mode) do
    with {:ok, leased} <- claim(id),
         {:ok, adapter} <- Registry.adapter(leased.plugin_id),
         {:ok, config} <- get_any_config(leased.auth_config_id),
         {:ok, secret} <- Credentials.secret(config) do
      desired = desired?(leased, config)
      result = adapter.reconcile_trigger(config, secret, leased, desired)

      result =
        if mode == :tenant_teardown and unavailable_subscription?(result),
          do: {:ok, %{}},
          else: result

      complete(leased, desired, result)
    end
  end

  def teardown_tenant do
    Trigger
    |> Ash.Query.limit(50)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn trigger, _result ->
      case teardown_for_tenant(trigger.id) do
        :ok -> {:cont, {:snooze, 1}}
        result -> {:halt, result}
      end
    end)
  end

  defp teardown_for_tenant(id) do
    with {:ok, _} <- mark_deleting(id) do
      case reconcile(id, :tenant_teardown) do
        {:ok, %{__meta__: %{state: :deleted}}} -> :ok
        {:error, :not_found} -> :ok
        {:error, :connector_trigger_busy} -> {:snooze, 1}
        {:ok, _} -> {:error, :connector_subscription_cleanup_failed}
        error -> error
      end
    end
  end

  defp unavailable_subscription?({:error, %{status: status}}) when status in [401, 403, 404],
    do: true

  defp unavailable_subscription?({:error, reason})
       when reason in [:invalid_grant, :oauth_reauthorization_required, :oauth_consent_required],
       do: true

  defp unavailable_subscription?(_result), do: false

  defp mark_deleting(id) do
    Repo.transact_top_level(fn ->
      row =
        Trigger
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [id]})

      if row,
        do: Ankole.Ash.update(row, :update, %{status: "deleting", last_error: nil}),
        else: {:ok, nil}
    end)
  end

  defp claim(id) do
    Repo.transact_top_level(fn ->
      row =
        Trigger
        |> Ash.Query.filter(id == ^id)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [id]})

      cond do
        is_nil(row) ->
          {:error, :not_found}

        row.status == "degraded" ->
          {:error, :connector_trigger_degraded}

        row.lease_expires_at && DateTime.compare(row.lease_expires_at, DateTime.utc_now()) == :gt ->
          {:error, :connector_trigger_busy}

        true ->
          Ankole.Ash.update(row, :update, %{
            lease_expires_at: DateTime.add(DateTime.utc_now(), 30)
          })
      end
    end)
  end

  defp complete(leased, previous_desired, result) do
    Repo.transact_top_level(fn ->
      row =
        Trigger
        |> Ash.Query.filter(id == ^leased.id)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read_one!(lock_identity: {"connector_triggers", [leased.id]})

      if row && row.lease_expires_at == leased.lease_expires_at do
        {:ok, config} = get_any_config(row.auth_config_id)
        desired = desired?(row, config)

        finish_reconciliation(row, previous_desired, desired, result)
      else
        {:error, :connector_trigger_changed}
      end
    end)
  end

  defp finish_reconciliation(row, previous_desired, desired, result) do
    case result do
      {:ok, _observed} when row.status == "deleting" and not previous_desired ->
        Ankole.Ash.destroy(row, :destroy)

      {:ok, observed} ->
        with {:ok, updated} <-
               Ankole.Ash.update(row, :update, %{
                 external_subscription_id: observed.external_subscription_id,
                 status: reconciled_status(row, previous_desired, desired),
                 last_error: nil,
                 lease_expires_at: nil
               }) do
          if desired != previous_desired,
            do:
              Oban.insert(Ankole.Connectors.Jobs.ReconcileTrigger.new(%{"trigger_id" => row.id}))

          {:ok, updated}
        end

      {:error, _reason} ->
        Ankole.Ash.update(row, :update, %{
          status: "degraded",
          lease_expires_at: nil,
          last_error: %{
            "code" => "subscription_reconciliation_failed",
            "operation" => if(row.status == "deleting", do: "delete", else: "reconcile")
          }
        })
    end
  end

  defp reconciled_status(%{status: "deleting"}, _, _), do: "deleting"
  defp reconciled_status(_row, previous, desired) when previous != desired, do: "provisioning"
  defp reconciled_status(_row, _previous, true), do: "active"
  defp reconciled_status(_row, _previous, false), do: "paused"

  defp desired?(trigger, config) do
    reference = "connector-trigger://" <> trigger.id

    config.status == "active" and active_account?(trigger) and trigger.status != "deleting" and
      Ankole.Signals.list_bindings!(
        query: [
          filter: [config_ref: reference, enabled: true, unavailable_reason: [is_nil: true]],
          limit: 1
        ]
      ) != []
  end

  defp active_account?(%{connected_account_id: nil}), do: true

  defp active_account?(%{connected_account_id: id}) do
    case Accounts.get_by_id(id) do
      {:ok, account} when not is_nil(account) -> Accounts.valid?(account)
      _ -> false
    end
  end

  defp trigger_account(%{auth_scheme: "oauth2"} = config, nil) do
    case Accounts.application_account(config) do
      {:ok, nil} -> {:error, :connection_account_required}
      {:ok, account} -> {:ok, account.id}
      error -> error
    end
  end

  defp trigger_account(_config, id), do: {:ok, id}

  defp account_for_config(nil, _), do: :ok

  defp account_for_config(id, config_id) do
    case Accounts.get_by_id(id) do
      {:ok, %{auth_config_id: ^config_id}} -> :ok
      _ -> {:error, :connection_account_not_found}
    end
  end

  defp get_any_config(id) do
    case AuthConfig |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one() do
      {:ok, nil} -> {:error, :connection_required}
      value -> value
    end
  end

  def public(row),
    do:
      row
      |> Map.from_struct()
      |> Map.take([
        :id,
        :auth_config_id,
        :connected_account_id,
        :plugin_id,
        :trigger_type,
        :scope_key,
        :config,
        :external_subscription_id,
        :status,
        :last_error,
        :updated_at
      ])
      |> Map.put(:config_ref, "connector-trigger://" <> row.id)
end
