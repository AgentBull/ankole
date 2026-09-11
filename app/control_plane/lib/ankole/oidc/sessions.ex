defmodule Ankole.OIDC.Sessions do
  @moduledoc false
  import Ecto.Query
  alias Ankole.{BrowserSessions, OIDC, Repo}
  alias Ankole.OIDC.{Client, LoginPolicy, Session}
  alias Ankole.Principals.HumanAccess

  def ensure(client_id, auth, scope) do
    ref = %{"id" => auth["browser_id"], "generation" => auth["browser_generation"]}

    BrowserSessions.authorize(ref, auth, fn repo ->
      with {:ok, client} <- OIDC.get_active_client(client_id),
           :ok <- LoginPolicy.authorize_source(client, auth["provider_id"]) do
        now = DateTime.utc_now()

        expiry =
          if offline?(scope),
            do: DateTime.add(now, 30 * 24 * 60 * 60),
            else: DateTime.from_unix!(auth["expires_at"] * 1_000_000, :microsecond)

        attributes = %{
          client_id: client_id,
          principal_uid: auth["principal_uid"],
          browser_id: auth["browser_id"],
          browser_generation: auth["browser_generation"],
          access_version: auth["access_version"],
          provider_id: auth["provider_id"],
          auth_time: auth["auth_time"],
          expires_at: expiry
        }

        %Session{}
        |> Ecto.Changeset.change(attributes)
        |> repo.insert(
          on_conflict:
            from(s in Session,
              update: [
                set: [
                  updated_at: ^now,
                  expires_at: fragment("GREATEST(?, ?)", s.expires_at, ^expiry)
                ]
              ]
            ),
          conflict_target: [:client_id, :browser_id, :browser_generation, :provider_id],
          returning: true
        )
      end
    end)
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Session{} = session <- Repo.get(Session, id) do
      {:ok, session}
    else
      _ -> {:error, :authorization_revoked}
    end
  end

  def validate(id, client_id, principal_uid, scope, kind \\ :access) do
    with {:ok, session} <- get(id),
         true <- session.client_id == client_id and session.principal_uid == principal_uid,
         true <-
           is_nil(session.revoked_at) and
             DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt,
         true <-
           (kind != :code and offline?(scope)) or
             (is_nil(session.ended_at) and BrowserSessions.active?(session.browser_id)),
         :ok <- HumanAccess.check(principal_uid, session.access_version),
         {:ok, client} <- OIDC.get_active_client(client_id),
         :ok <- LoginPolicy.authorize_source(client, session.provider_id),
         true <-
           MapSet.subset?(
             MapSet.new(String.split(scope, " ", trim: true)),
             MapSet.new(client.scopes)
           ) do
      {:ok, session}
    else
      false -> {:error, :authorization_revoked}
      {:error, _} = error -> error
    end
  end

  def authentication(%Session{} = session) do
    %{
      "principal_uid" => session.principal_uid,
      "access_version" => session.access_version,
      "provider_id" => session.provider_id,
      "auth_time" => session.auth_time,
      "browser_id" => session.browser_id,
      "browser_generation" => session.browser_generation,
      "sid" => session.id
    }
  end

  def revoke(id) do
    Repo.transact(fn repo ->
      with {:ok, session} <- get(id) do
        session |> Ecto.Changeset.change(revoked_at: DateTime.utc_now()) |> repo.update()
      end
    end)
  end

  def end_browser_in_tx(repo, browser_id) do
    terminate(repo, from(s in Session, where: s.browser_id == ^browser_id), :browser)
  end

  def revoke_human_in_tx(repo, principal_uid, access_version) do
    terminate(
      repo,
      from(s in Session,
        where: s.principal_uid == ^principal_uid and s.access_version < ^access_version
      ),
      :human
    )
  end

  defp terminate(repo, query, kind) do
    now = DateTime.utc_now()
    sessions = repo.all(query |> order_by([s], s.id) |> lock("FOR UPDATE"))

    Enum.reduce_while(sessions, :ok, fn session, :ok ->
      attrs =
        if kind == :human,
          do: [revoked_at: session.revoked_at || now, ended_at: session.ended_at || now],
          else: [ended_at: session.ended_at || now]

      with {:ok, session} <- session |> Ecto.Changeset.change(attrs) |> repo.update(),
           %Client{} = client <- repo.get(Client, session.client_id),
           :ok <- Ankole.OIDC.Logout.enqueue_in_tx(repo, session, client) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp offline?(scope), do: "offline_access" in String.split(scope, " ", trim: true)
end
