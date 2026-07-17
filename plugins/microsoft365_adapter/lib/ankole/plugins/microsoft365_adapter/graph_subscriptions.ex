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

  alias Ankole.AppConfigure
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.Config
  alias MicrosoftOpenAPI.Error
  alias MicrosoftOpenAPI.Graph

  @resources ["/users", "/groups"]
  @change_type "updated,deleted"
  @subscription_lifetime_days 7
  @renewal_window_hours 48

  @spec resources() :: [String.t()]
  def resources, do: @resources

  @doc """
  Ensures both directory subscriptions exist and are outside the renewal window.
  """
  @spec ensure(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def ensure(provider_id, config, opts \\ []) do
    client = Config.identity_client(config, Keyword.get(opts, :client_opts, []))
    notification_url = notification_url(provider_id, config)
    state = load_state(provider_id)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    @resources
    |> Enum.reduce_while({:ok, []}, fn resource, {:ok, entries} ->
      existing = Enum.find(state, &(MapHelpers.optional_text(&1, "resource") == resource))

      case ensure_resource(client, resource, existing, notification_url, now) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} ->
        entries = Enum.reverse(entries)

        with {:ok, _persisted} <- persist_state(provider_id, entries) do
          {:ok, %{subscriptions: entries}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Deletes every tracked subscription for one provider and clears its state.
  """
  @spec delete_all(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete_all(provider_id, config, opts \\ []) do
    client = Config.identity_client(config, Keyword.get(opts, :client_opts, []))
    state = load_state(provider_id)

    deleted =
      Enum.count(state, fn entry ->
        case MapHelpers.optional_text(entry, "id") do
          nil ->
            false

          subscription_id ->
            case Graph.delete(client, "subscriptions/" <> subscription_id) do
              {:ok, _body} -> true
              {:error, %Error{status: 404}} -> true
              {:error, _reason} -> false
            end
        end
      end)

    with {:ok, _persisted} <- persist_state(provider_id, []) do
      {:ok, %{deleted: deleted}}
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

  defp ensure_resource(client, resource, nil, notification_url, now),
    do: create_subscription(client, resource, notification_url, now)

  defp ensure_resource(client, resource, existing, notification_url, now) do
    if needs_renewal?(existing, now) do
      renew_subscription(client, resource, existing, notification_url, now)
    else
      {:ok, existing}
    end
  end

  defp create_subscription(client, resource, notification_url, now) do
    client_state = generate_client_state()
    expiration = expiration(now)

    case Graph.post(client, "subscriptions",
           body: %{
             "changeType" => @change_type,
             "notificationUrl" => notification_url,
             "resource" => resource,
             "expirationDateTime" => expiration,
             "clientState" => client_state
           }
         ) do
      {:ok, subscription} ->
        {:ok,
         %{
           "id" => Map.get(subscription, "id"),
           "resource" => resource,
           "expiration" => Map.get(subscription, "expirationDateTime") || expiration,
           "clientState" => client_state
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp renew_subscription(client, resource, existing, notification_url, now) do
    subscription_id = MapHelpers.optional_text(existing, "id")
    expiration = expiration(now)

    case Graph.patch(client, "subscriptions/" <> subscription_id,
           body: %{"expirationDateTime" => expiration}
         ) do
      {:ok, subscription} ->
        {:ok,
         Map.put(existing, "expiration", Map.get(subscription, "expirationDateTime") || expiration)}

      {:error, %Error{status: 404}} ->
        create_subscription(client, resource, notification_url, now)

      {:error, _reason} = error ->
        error
    end
  end

  defp needs_renewal?(entry, now) do
    case entry |> MapHelpers.optional_text("expiration") |> parse_datetime() do
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

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp generate_client_state, do: Ankole.Kernel.generate_key()

  @doc false
  @spec notification_url(String.t(), map()) :: String.t()
  def notification_url(provider_id, config) do
    base = config |> Map.fetch!("publicBaseURL") |> String.trim_trailing("/")
    base <> "/webhooks/v1/entra-id/" <> URI.encode(provider_id) <> "/directory"
  end

  defp load_state(provider_id) do
    case AppConfigure.get_by_key(Config.subscription_state_key(provider_id)) do
      {:ok, %{"subscriptions" => subscriptions}} when is_list(subscriptions) -> subscriptions
      _missing -> []
    end
  end

  defp persist_state(provider_id, entries) do
    AppConfigure.put_global_by_key(Config.subscription_state_key(provider_id), %{
      "subscriptions" => entries,
      "updatedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
    })
  end
end
