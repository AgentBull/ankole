defmodule Ankole.Plugins.Microsoft365Adapter.GraphSubscriptions do
  @moduledoc """
  Graph change-notification subscription state machine for one provider.

  Two subscriptions per provider — `/users` and `/groups`, changeType
  `"updated,deleted"` (creation and soft-deletion also arrive as `updated`
  per Graph's documented behavior). Directory subscriptions live at most
  41,760 minutes (under 29 days); entries are created with a 7-day expiration
  and renewed once they fall inside the 48-hour renewal window, so a missed
  reconciler run has days of slack before notifications stop.

  Subscription rows (id, resource, expiration, clientState secret) are
  machine-managed values persisted under the declared encrypted AppConfigure
  pattern `principals.entra_id.graph_subscriptions.<provider_id>`.
  """

  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.Config
  alias MicrosoftOpenAPI.Error
  alias MicrosoftOpenAPI.Graph

  @resources ["/users", "/groups"]
  @change_type "updated,deleted"
  @subscription_lifetime_days 7
  @renewal_window_hours 48

  # Unit tests inspect the same implementation that the production entry uses.
  if Mix.env() == :test do
    @doc """
    Ensures both directory subscriptions exist and are outside the renewal window.

    Each resource persists on its own success, so a later resource's failure (for
    example a missing Graph permission) cannot orphan an already-created remote
    subscription. Failed resources are aggregated into one loud error return.
    """
    @spec ensure(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
    def ensure(provider_id, config, opts \\ []) do
      with_provider_lock(provider_id, fn -> ensure_locked(provider_id, config, opts) end)
    end
  end

  # Desired mode is read after arbitration, rather than by each scheduler before
  # waiting for another node's in-flight create/delete operation.
  def reconcile_current(provider_id, config_key, opts \\ []) do
    with_provider_lock(provider_id, fn ->
      with {:ok, {config, enabled}} <- fresh_desired(provider_id, config_key),
           {:ok, config} <- Config.validate_identity_config(config) do
        enabled? =
          enabled and get_in(config, ["sync", "contacts"]) != false and
            get_in(config, ["sync", "realtime"]) == true

        if enabled? do
          case ensure_locked(provider_id, config, opts) do
            {:ok, _} -> {:ensured, provider_id}
            {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
          end
        else
          case delete_all_locked(provider_id, config) do
            {:ok, %{deleted: 0}} -> {:skipped, provider_id}
            {:ok, _} -> {:removed, provider_id}
            {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
          end
        end
      else
        {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
        :error -> {:error, %{provider_id: provider_id, reason: :provider_config_missing}}
      end
    end)
  end

  defp with_provider_lock(provider_id, fun) do
    :global.trans({{__MODULE__, Repo.tenant_id!(), provider_id}, self()}, fun)
  end

  defp ensure_locked(provider_id, config, opts) do
    client = Config.identity_client(config)
    notification_url = notification_url(provider_id, config)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    {entries, failures} =
      Enum.reduce(@resources, {[], []}, fn resource, {entries, failures} ->
        # Each resource can leave a durable creation intent even when POST fails.
        # Reload before the next resource so that intent cannot be overwritten.
        result =
          with {:ok, state} <- fresh_state(provider_id) do
            existing = Enum.find(state, &(MapHelpers.optional_text(&1, "resource") == resource))

            with {:ok, entry} <-
                   ensure_resource(
                     provider_id,
                     client,
                     state,
                     resource,
                     existing,
                     notification_url,
                     now
                   ),
                 {:ok, _} <-
                   persist_resource_entry(provider_id, client, state, resource, entry, existing),
                 do: {:ok, entry}
          end

        case result do
          {:ok, entry} -> {[entry | entries], failures}
          {:error, reason} -> {entries, [%{resource: resource, reason: reason} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, %{subscriptions: Enum.reverse(entries)}}
      failures -> {:error, {:graph_subscription_ensure_failed, Enum.reverse(failures)}}
    end
  end

  defp persist_resource_entry(provider_id, client, state, resource, entry, existing) do
    state = put_resource_entry(state, resource, entry)

    case persist_state(provider_id, state) do
      {:ok, _persisted} ->
        {:ok, state}

      {:error, reason} ->
        # A subscription created in this pass but never reaching durable state
        # would become an untracked remote orphan; delete it best-effort.
        if MapHelpers.optional_text(entry, "id") !=
             MapHelpers.optional_text(existing || %{}, "id"),
           do: delete_subscription(client, entry)

        {:error, reason}
    end
  end

  defp put_resource_entry(state, resource, entry) do
    Enum.reject(state, &(MapHelpers.optional_text(&1, "resource") == resource)) ++ [entry]
  end

  @doc """
  Deletes every tracked subscription for one provider.

  Failed deletions stay in local state so a later reconciliation can retry them.
  """
  @spec delete_all(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def delete_all(provider_id, config) do
    with_provider_lock(provider_id, fn -> delete_all_locked(provider_id, config) end)
  end

  defp delete_all_locked(provider_id, config) do
    client = Config.identity_client(config)

    with {:ok, state} <- fresh_state(provider_id) do
      {deleted, remaining, failures} =
        Enum.reduce(state, {0, [], []}, fn entry, {deleted, remaining, failures} ->
          case delete_entry(client, entry) do
            :ok ->
              {deleted + 1, remaining, failures}

            {:error, reason} ->
              failure = %{subscription_id: MapHelpers.optional_text(entry, "id"), reason: reason}
              {deleted, [entry | remaining], [failure | failures]}
          end
        end)

      with {:ok, _} <- persist_state(provider_id, Enum.reverse(remaining)) do
        case failures do
          [] -> {:ok, %{deleted: deleted}}
          failures -> {:error, {:graph_subscription_deletion_failed, Enum.reverse(failures)}}
        end
      end
    end
  end

  @doc """
  Checks a notification's clientState against the provider's stored secrets.
  """
  @spec valid_client_state?(String.t(), String.t() | nil) :: boolean()
  def valid_client_state?(_provider_id, nil), do: false

  def valid_client_state?(provider_id, client_state) when is_binary(client_state) do
    provider_id
    |> load_state()
    |> Enum.any?(&(MapHelpers.optional_text(&1, "clientState") == client_state))
  end

  defp ensure_resource(provider, client, state, resource, nil, url, now),
    do: create_subscription(provider, client, state, resource, url, now)

  defp ensure_resource(provider, client, state, resource, existing, url, now) do
    cond do
      existing["notificationUrl"] != url ->
        with :ok <- delete_entry(client, existing),
             do: create_subscription(provider, client, state, resource, url, now)

      existing["phase"] == "creating" ->
        recover_creation(client, existing, now)

      true ->
        case Graph.get(client, "subscriptions/" <> existing["id"]) do
          {:ok, remote} ->
            if remote["notificationUrl"] && remote["notificationUrl"] != url do
              with :ok <- delete_subscription(client, existing),
                   do: create_subscription(provider, client, state, resource, url, now)
            else
              existing =
                Map.put(
                  existing,
                  "expiration",
                  remote["expirationDateTime"] || existing["expiration"]
                )

              case renew_subscription(client, existing, now) do
                {:error, %Error{status: 404}} ->
                  create_subscription(provider, client, state, resource, url, now)

                result ->
                  result
              end
            end

          {:error, %Error{status: 404}} ->
            create_subscription(provider, client, state, resource, url, now)

          error ->
            error
        end
    end
  end

  defp renew_subscription(client, existing, now) do
    if needs_renewal?(existing, now) do
      case Graph.patch(client, "subscriptions/" <> existing["id"],
             body: %{"expirationDateTime" => expiration(now)}
           ) do
        {:ok, remote} ->
          {:ok, Map.put(existing, "expiration", remote["expirationDateTime"] || expiration(now))}

        error ->
          error
      end
    else
      {:ok, existing}
    end
  end

  defp create_subscription(provider, client, state, resource, url, now) do
    # GET cannot recover clientState. Clear an old untracked subscription only
    # when its callback belongs to this provider, then persist the secret before
    # POST. A crash after POST can now recover the remote id without losing it.
    with {:ok, remote} <- matching_subscriptions(client, resource),
         :ok <- clear_untracked(client, remote, url) do
      pending = %{
        "phase" => "creating",
        "resource" => resource,
        "notificationUrl" => url,
        "expiration" => expiration(now),
        "clientState" => generate_client_state()
      }

      with {:ok, _} <- persist_state(provider, put_resource_entry(state, resource, pending)),
           do: post_subscription(client, pending, now)
    end
  end

  defp recover_creation(client, pending, now, may_post \\ true) do
    with {:ok, remote} <- matching_subscriptions(client, pending["resource"]) do
      case remote do
        [] when may_post ->
          # A permission failure can leave this intent pending past its first
          # expiration. Keep its saved secret and request a fresh lifetime.
          post_subscription(client, Map.put(pending, "expiration", expiration(now)), now)

        [] ->
          {:error, :graph_subscription_conflict_not_visible}

        [entry] ->
          if entry["notificationUrl"] == pending["notificationUrl"],
            do: {:ok, created_entry(pending, entry)},
            else: {:error, :graph_subscription_owned_elsewhere}

        _ ->
          {:error, :graph_subscription_owned_elsewhere}
      end
    end
  end

  defp post_subscription(client, pending, now) do
    body = %{
      "resource" => pending["resource"],
      "notificationUrl" => pending["notificationUrl"],
      "clientState" => pending["clientState"],
      "expirationDateTime" => pending["expiration"],
      "changeType" => @change_type
    }

    case Graph.post(client, "subscriptions", body: body) do
      {:ok, remote} -> {:ok, created_entry(pending, remote)}
      # The original POST may have succeeded before its response was lost.
      {:error, %Error{status: 409}} -> recover_creation(client, pending, now, false)
      error -> error
    end
  end

  defp created_entry(pending, remote) do
    pending
    |> Map.delete("phase")
    |> Map.put("id", remote["id"])
    |> Map.put("expiration", remote["expirationDateTime"] || pending["expiration"])
  end

  defp matching_subscriptions(client, resource),
    do: matching_subscriptions(client, "subscriptions", resource, [])

  defp matching_subscriptions(client, path, resource, found) do
    with {:ok, response} <- Graph.get(client, path) do
      matches =
        Enum.filter(Map.get(response, "value", []), fn entry ->
          String.trim_leading(entry["resource"] || "", "/") == String.trim_leading(resource, "/") and
            Enum.sort(String.split(entry["changeType"] || "", ",")) ==
              Enum.sort(String.split(@change_type, ","))
        end)

      case response["@odata.nextLink"] do
        next when is_binary(next) ->
          matching_subscriptions(client, next, resource, found ++ matches)

        _ ->
          {:ok, found ++ matches}
      end
    end
  end

  defp clear_untracked(client, remote, url) do
    Enum.reduce_while(remote, :ok, fn entry, :ok ->
      if entry["notificationUrl"] == url do
        case delete_subscription(client, entry) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:halt, {:error, :graph_subscription_owned_elsewhere}}
      end
    end)
  end

  defp delete_entry(client, %{"phase" => "creating"} = pending) do
    with {:ok, remote} <- matching_subscriptions(client, pending["resource"]),
         do: clear_untracked(client, remote, pending["notificationUrl"])
  end

  defp delete_entry(client, entry), do: delete_subscription(client, entry)

  defp needs_renewal?(entry, now) do
    case entry |> MapHelpers.optional_text("expiration") |> Ankole.Attrs.parse_datetime() do
      nil ->
        true

      expiration ->
        DateTime.compare(expiration, DateTime.add(now, @renewal_window_hours, :hour)) != :gt
    end
  end

  defp expiration(now) do
    now
    |> DateTime.add(@subscription_lifetime_days, :day)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp generate_client_state, do: Ankole.Kernel.generate_key()

  defp delete_subscription(client, entry) do
    case MapHelpers.optional_text(entry, "id") do
      nil ->
        {:error, :missing_subscription_id}

      subscription_id ->
        case Graph.delete(client, "subscriptions/" <> subscription_id) do
          {:ok, _body} -> :ok
          {:error, %Error{status: 404}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec notification_url(String.t(), map()) :: String.t()
  defp notification_url(provider_id, config) do
    base = config |> Map.fetch!("publicBaseURL") |> String.trim_trailing("/")
    instance_id = Ankole.Repo.tenant_id!() <> "." <> provider_id
    base <> "/webhooks/v1/entra-id/" <> URI.encode(instance_id) <> "/directory"
  end

  defp load_state(provider_id) do
    case AppConfigure.get_by_key(Config.subscription_state_key(provider_id)) do
      {:ok, %{"subscriptions" => subscriptions}} when is_list(subscriptions) -> subscriptions
      _missing -> []
    end
  end

  defp fresh_desired(provider_id, key) do
    Repo.transact(fn repo ->
      activation_key = Ankole.IdentityProviders.Config.active_definition().key

      with {:ok, providers} <- AppConfigure.get_tenant_by_key_in_tx(repo, activation_key),
           {:ok, config} <- AppConfigure.get_tenant_by_key_in_tx(repo, key) do
        provider =
          Enum.find(
            providers,
            &(&1["provider_id"] == provider_id and &1["config_key"] == key and
                &1["adapter_id"] == "entra-id")
          )

        {:ok, {config, not is_nil(provider) and provider["enabled"] != false}}
      else
        :error -> {:error, :provider_config_missing}
        error -> error
      end
    end)
  end

  defp fresh_state(provider_id) do
    Repo.transact(fn repo ->
      case AppConfigure.get_tenant_by_key_in_tx(repo, Config.subscription_state_key(provider_id)) do
        {:ok, %{"subscriptions" => subscriptions}} when is_list(subscriptions) ->
          {:ok, subscriptions}

        :error ->
          {:ok, []}

        {:error, _} = error ->
          error

        _ ->
          {:error, :invalid_graph_subscription_state}
      end
    end)
  end

  defp persist_state(provider_id, entries) do
    AppConfigure.put_tenant_by_key(Config.subscription_state_key(provider_id), %{
      "subscriptions" => entries
    })
  end
end
