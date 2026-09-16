defmodule Ankole.OIDC.Logout do
  @moduledoc """
  Persistent delivery of session-specific OIDC Back-Channel Logout.
  """
  import Ecto.Query
  alias Ankole.OIDC.{Client, LogoutDelivery, LogoutWorker, Session}
  alias Ankole.{Repo, TokenSigning}

  def enqueue_in_tx(_repo, _session, %Client{backchannel_logout_uri: uri}) when uri in [nil, ""],
    do: :ok

  def enqueue_in_tx(repo, session, client) do
    case repo.get_by(LogoutDelivery, session_id: session.id) do
      nil ->
        now = DateTime.utc_now()

        with {:ok, delivery} <-
               %LogoutDelivery{}
               |> Ecto.Changeset.change(
                 session_id: session.id,
                 endpoint: client.backchannel_logout_uri,
                 deadline: DateTime.add(now, 24 * 60 * 60),
                 next_attempt_at: now
               )
               |> repo.insert(),
             {:ok, _} <- Oban.insert(LogoutWorker.new(%{"delivery_id" => delivery.id})) do
          :ok
        end

      %LogoutDelivery{} ->
        :ok
    end
  end

  def deliveries(client_id \\ nil) do
    query =
      from d in LogoutDelivery,
        join: s in Session,
        on: s.id == d.session_id,
        order_by: [desc: d.inserted_at],
        select: %{delivery: d, client_id: s.client_id, principal_uid: s.principal_uid}

    query = if client_id, do: where(query, [_d, s], s.client_id == ^client_id), else: query
    Repo.all(query)
  end

  def retry(id) do
    Repo.transact(fn repo ->
      case repo.one(from d in LogoutDelivery, where: d.id == ^id, lock: "FOR UPDATE") do
        nil ->
          {:error, :not_found}

        %LogoutDelivery{status: :delivered} = delivery ->
          {:ok, delivery}

        delivery ->
          now = DateTime.utc_now()

          with {:ok, delivery} <-
                 delivery
                 |> Ecto.Changeset.change(
                   status: :pending,
                   deadline: DateTime.add(now, 24 * 60 * 60),
                   next_attempt_at: now
                 )
                 |> repo.update(),
               {:ok, job} <- Oban.insert(LogoutWorker.new(%{"delivery_id" => delivery.id})),
               :ok <- Oban.retry_job(job) do
            {:ok, delivery}
          end
      end
    end)
  end

  def deliver_browser(browser_id) do
    ids =
      Repo.all(
        from d in LogoutDelivery,
          join: s in Session,
          on: s.id == d.session_id,
          where: s.browser_id == ^browser_id and d.status in [:pending, :delivering],
          select: d.id
      )

    Enum.each(ids, &deliver/1)
    :ok
  end

  def deliver(id) do
    case claim(id) do
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

  defp claim(id) do
    Repo.transact(fn repo ->
      case repo.one(from d in LogoutDelivery, where: d.id == ^id, lock: "FOR UPDATE") do
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
              with {:ok, _} <-
                     delivery
                     |> Ecto.Changeset.change(status: :failed, next_attempt_at: nil)
                     |> repo.update(),
                   do: {:ok, :expired}

            is_struct(delivery.next_attempt_at, DateTime) and
                DateTime.compare(delivery.next_attempt_at, now) == :gt ->
              {:ok, {:wait, max(1, DateTime.diff(delivery.next_attempt_at, now))}}

            true ->
              delivery
              |> Ecto.Changeset.change(
                status: :delivering,
                attempt_count: delivery.attempt_count + 1,
                last_attempt_at: now
              )
              |> repo.update()
          end
      end
    end)
  end

  defp transmit(delivery) do
    with %Session{} = session <- Repo.get(Session, delivery.session_id),
         now <- System.system_time(:second),
         {:ok, token} <-
           TokenSigning.sign(
             %{
               iss: TokenSigning.issuer(),
               aud: session.client_id,
               iat: now,
               exp: now + 120,
               jti: Ankole.Kernel.gen_uuid_v7(),
               sub: session.principal_uid,
               sid: session.id,
               events: %{"http://schemas.openid.net/event/backchannel-logout" => %{}}
             },
             "logout+jwt"
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

    attrs =
      case result do
        :ok ->
          [status: :delivered, delivered_at: now, next_attempt_at: nil, last_error: nil]

        {:error, reason} ->
          [status: :pending, next_attempt_at: DateTime.add(now, delay), last_error: reason]
      end

    Repo.update_all(
      from(d in LogoutDelivery, where: d.id == ^delivery.id and d.status != :delivered),
      set: attrs ++ [updated_at: now]
    )

    case result do
      :ok -> :ok
      {:error, _} -> {:snooze, delay}
    end
  end

  defp transport_error(%{__struct__: module}), do: "Transport error: #{inspect(module)}"
  defp transport_error(_), do: "Transport error"
end
