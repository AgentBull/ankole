defmodule Ankole.OIDC.Logout do
  @moduledoc """
  Persistent delivery of session-specific OIDC Back-Channel Logout.
  """
  require Ash.Query
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.LogoutDelivery
  alias Ankole.OIDC.LogoutWorker
  alias Ankole.OIDC.Session
  alias Ankole.Repo

  def enqueue_in_tx(_repo, _session, %Client{backchannel_logout_uri: uri}) when uri in [nil, ""],
    do: :ok

  def enqueue_in_tx(_repo, session, client) do
    case LogoutDelivery
         |> Ash.Query.filter(session_id == ^session.id)
         |> Ankole.Ash.read_one!() do
      nil ->
        now = DateTime.utc_now()

        with {:ok, delivery} <-
               Ankole.Ash.create(LogoutDelivery, :enqueue_in_tx, %{
                 session_id: session.id,
                 endpoint: client.backchannel_logout_uri,
                 deadline: DateTime.add(now, 24 * 60 * 60),
                 next_attempt_at: now
               }),
             {:ok, _} <- Oban.insert(LogoutWorker.new(%{"delivery_id" => delivery.id})) do
          :ok
        end

      %LogoutDelivery{} ->
        :ok
    end
  end

  @doc false
  def console_retry_in_tx(client_id, id) do
    case LogoutDelivery
         |> Ash.Query.filter(id == ^id and session.client_id == ^client_id)
         |> Ankole.Ash.read_one!() do
      %LogoutDelivery{} ->
        with {:ok, delivery} <- retry_in_tx(id) do
          {:ok,
           Ash.load!(delivery, [:principal_uid], tenant: Repo.tenant_id(), authorize?: false)}
        end

      nil ->
        {:error, :not_found}
    end
  end

  def retry(id), do: Ankole.Ash.run_action(LogoutDelivery, :retry, %{id: id})

  @doc false
  def retry_in_tx(id) do
    case lock_delivery(id) do
      nil ->
        {:error, :not_found}

      %LogoutDelivery{status: :delivered} = delivery ->
        {:ok, delivery}

      delivery ->
        now = DateTime.utc_now()

        with {:ok, delivery} <-
               Ankole.Ash.update(delivery, :restart_in_tx, %{
                 deadline: DateTime.add(now, 24 * 60 * 60),
                 next_attempt_at: now
               }),
             {:ok, job} <- Oban.insert(LogoutWorker.new(%{"delivery_id" => delivery.id})),
             :ok <- Oban.retry_job(job) do
          {:ok, delivery}
        end
    end
  end

  def deliver_browser(browser_id) do
    deliveries =
      Repo.across_tenants(fn ->
        session_ids =
          Session
          |> Ash.Query.for_read(:lookup_across_tenants, %{}, authorize?: false)
          |> Ash.Query.filter(browser_id == ^browser_id)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.id)

        LogoutDelivery
        |> Ash.Query.for_read(:lookup_across_tenants, %{}, authorize?: false)
        |> Ash.Query.filter(session_id in ^session_ids and status in [:pending, :delivering])
        |> Ash.read!(authorize?: false)
      end)

    Enum.each(deliveries, fn delivery ->
      Repo.with_tenant(delivery.tenant_id, fn -> deliver(delivery.id) end)
    end)

    :ok
  end

  def deliver(id) do
    case Ankole.Ash.run_action(LogoutDelivery, :claim, %{id: id}) do
      {:ok, :complete} ->
        :ok

      {:ok, :expired} ->
        Ankole.Logging.warning(
          "oidc.logout.delivery_exhausted",
          "Logout delivery deadline reached; retry from the OIDC Client page",
          %{delivery_id: id}
        )

        {:discard, :delivery_deadline}

      {:ok, {:wait, seconds}} ->
        {:snooze, seconds}

      {:ok, delivery} ->
        case transmit(delivery) do
          :ok -> finish(delivery, :ok)
          {:error, reason} -> finish(delivery, {:error, reason})
        end

      {:error, _} = error ->
        error
    end
  end

  @doc false
  def claim_in_tx(id) do
    case lock_delivery(id) do
      nil ->
        {:ok, :complete}

      %LogoutDelivery{status: :delivered} ->
        {:ok, :complete}

      delivery ->
        now = DateTime.utc_now()

        cond do
          delivery.status == :delivering and is_struct(delivery.last_attempt_at, DateTime) and
              DateTime.diff(now, delivery.last_attempt_at) < 15 ->
            {:ok, {:wait, 15}}

          delivery.status == :failed ->
            {:ok, :expired}

          DateTime.compare(now, delivery.deadline) != :lt ->
            with {:ok, _} <- Ankole.Ash.update(delivery, :exhaust_in_tx, %{}),
                 do: {:ok, :expired}

          is_struct(delivery.next_attempt_at, DateTime) and
              DateTime.compare(delivery.next_attempt_at, now) == :gt ->
            {:ok, {:wait, max(1, DateTime.diff(delivery.next_attempt_at, now))}}

          true ->
            Ankole.Ash.update(delivery, :claim_in_tx, %{at: now})
        end
    end
  end

  defp lock_delivery(id) do
    LogoutDelivery
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp transmit(delivery) do
    with %Session{} = session <-
           Session |> Ash.Query.filter(id == ^delivery.session_id) |> Ankole.Ash.read_one!(),
         {:ok, token} <-
           Attesto.LogoutToken.mint(Ankole.OIDC.attesto_config(), session.client_id,
             sub: session.principal_uid,
             sid: session.id,
             lifetime: 120
           ) do
      case Req.post(delivery.endpoint,
             form: [logout_token: token],
             retry: false,
             redirect: false,
             receive_timeout: 3000,
             connect_options: [timeout: 3000],
             decode_body: false
           ) do
        {:ok, %{status: status}} when status in [200, 204] -> :ok
        {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, transport_error(reason)}
      end
    else
      nil -> {:error, "session unavailable"}
      {:error, _} -> {:error, "signing key unavailable"}
    end
  end

  defp finish(delivery, result) do
    now = DateTime.utc_now()
    delay = min(30 * Integer.pow(2, min(delivery.attempt_count - 1, 7)), 3600)

    {action, attrs} =
      case result do
        :ok ->
          {:acknowledge_in_tx, %{at: now}}

        {:error, reason} ->
          {:reschedule_in_tx,
           %{at: now, next_attempt_at: DateTime.add(now, delay), last_error: reason}}
      end

    case LogoutDelivery
         |> Ash.Query.filter(id == ^delivery.id)
         |> Ankole.Ash.update_where(action, attrs) do
      {:ok, _} -> if result == :ok, do: :ok, else: {:snooze, delay}
      {:error, _} = error -> error
    end
  end

  defp transport_error(%{__struct__: module}), do: "Transport error: #{inspect(module)}"
  defp transport_error(_), do: "Transport error"
end
