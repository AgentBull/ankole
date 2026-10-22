defmodule Ankole.OIDC.Sessions do
  @moduledoc false
  import Ecto.Query
  require Ash.Query
  alias Ankole.{BrowserSessions, OIDC, Repo}
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.LoginPolicy
  alias Ankole.OIDC.Session
  alias Ankole.Principals.{HumanAccess, Principal}
  alias Ankole.Tenants.Tenant

  def ensure(client_id, auth, scope) do
    ref = %{"id" => auth["authentication_id"], "revision" => auth["authentication_revision"]}

    Repo.transact(fn repo ->
      with :ok <- lock_tenant(repo) do
        BrowserSessions.authorize(ref, auth, fn repo ->
          ensure_session_in_tx(repo, client_id, auth, scope)
        end)
      end
    end)
  end

  defp ensure_session_in_tx(repo, client_id, auth, scope) do
    with :ok <- accepting_work(),
         {:ok, %Client{enabled: true} = client} <- lock_client(repo, client_id),
         :ok <- LoginPolicy.authorize_source(client, auth["provider_id"]) do
      now = DateTime.utc_now()

      expiry =
        if offline?(scope),
          do: DateTime.add(now, 30 * 24 * 60 * 60),
          else: DateTime.from_unix!(auth["expires_at"] * 1_000_000, :microsecond)

      attrs = %{
        client_id: client_id,
        principal_uid: auth["principal_uid"],
        browser_id: auth["browser_id"],
        authentication_id: auth["authentication_id"],
        authentication_revision: auth["authentication_revision"],
        access_version: auth["access_version"],
        provider_id: auth["provider_id"],
        auth_time: auth["auth_time"],
        expires_at: expiry
      }

      case repo.one(
             from s in Session,
               where:
                 s.client_id == ^client_id and
                   s.authentication_id == ^attrs.authentication_id and
                   s.authentication_revision == ^attrs.authentication_revision,
               lock: "FOR UPDATE"
           ) do
        nil -> Ankole.Ash.create(Session, :authorize_in_tx, attrs)
        session -> Ankole.Ash.update(session, :extend_in_tx, %{expires_at: expiry, at: now})
      end
    else
      {:ok, %Client{}} -> {:error, :not_found}
      error -> error
    end
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Session{} = session <- Session |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!() do
      {:ok, session}
    else
      _ -> {:error, :authorization_revoked}
    end
  end

  def validate(id, client_id, principal_uid, scope, kind \\ :access) do
    scopes = String.split(scope, " ", trim: true)

    with :ok <- accepting_work(),
         {:ok, session} <- get(id),
         true <- session.client_id == client_id and session.principal_uid == principal_uid,
         true <-
           is_nil(session.revoked_at) and
             DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt,
         true <-
           (kind != :code and "offline_access" in scopes) or
             (is_nil(session.ended_at) and live_authentication?(session)),
         :ok <- HumanAccess.check(principal_uid, session.access_version),
         {:ok, client} <- OIDC.get_active_client(client_id),
         :ok <- LoginPolicy.authorize_source(client, session.provider_id),
         true <-
           "openid" in scopes and MapSet.subset?(MapSet.new(scopes), MapSet.new(client.scopes)) do
      {:ok, session}
    else
      false -> {:error, :authorization_revoked}
      {:error, _} = error -> error
    end
  end

  defp live_authentication?(session) do
    ref = %{"id" => session.authentication_id, "revision" => session.authentication_revision}

    case BrowserSessions.identity(ref, session.tenant_id) do
      %{"principal_uid" => uid, "access_version" => version} ->
        uid == session.principal_uid and version == session.access_version

      _ ->
        false
    end
  end

  defp accepting_work do
    if Ankole.Tenants.accepting_work?(Repo.tenant_id!()),
      do: :ok,
      else: {:error, :tenant_suspended}
  end

  def revoke(id) do
    Repo.transact(fn _repo ->
      with {:ok, session} <- get(id), do: Ankole.Ash.update(session, :revoke_in_tx, %{})
    end)
  end

  def end_authentication_in_tx(repo, id, revision) do
    sessions =
      Repo.across_tenants(fn ->
        repo.all(
          from s in Session,
            where:
              s.authentication_id == ^id and s.authentication_revision == ^revision and
                is_nil(s.ended_at),
            order_by: s.id,
            lock: "FOR UPDATE"
        )
      end)

    terminate_sessions(repo, sessions, :browser)
  end

  def end_browser_in_tx(repo, browser_id) do
    sessions =
      Repo.across_tenants(fn ->
        repo.all(
          from s in Session,
            where: s.browser_id == ^browser_id,
            order_by: s.id,
            lock: "FOR UPDATE"
        )
      end)

    terminate_sessions(repo, sessions, :browser)
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
    sessions = repo.all(query |> order_by([s], s.id) |> lock("FOR UPDATE"))
    terminate_sessions(repo, sessions, kind)
  end

  defp terminate_sessions(repo, sessions, kind) do
    now = DateTime.utc_now()

    Enum.reduce_while(sessions, :ok, fn session, :ok ->
      action = if kind == :human, do: :revoke_and_end_in_tx, else: :end_in_tx

      Repo.with_tenant(session.tenant_id, fn ->
        with {:ok, session} <- Ankole.Ash.update(session, action, %{at: now}),
             %Client{} = client <- repo.get(Client, session.client_id),
             :ok <- Ankole.OIDC.Logout.enqueue_in_tx(repo, session, client) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
    end)
  end

  @doc false
  def lock_credential_parents_in_tx(subject, client_id, session_id) do
    with {:ok, session_id} <- Ecto.UUID.cast(session_id),
         :ok <- lock_tenant(Repo),
         %Principal{} <-
           Repo.across_tenants(fn ->
             Repo.one(from(p in Principal, where: p.uid == ^subject, lock: "FOR KEY SHARE"),
               lock_identity: {"principals", subject}
             )
           end),
         {:ok, _client} <- lock_client(Repo, client_id),
         %Session{} <-
           Repo.one(
             from s in Session,
               where:
                 s.id == ^session_id and s.client_id == ^client_id and s.principal_uid == ^subject,
               lock: "FOR UPDATE"
           ) do
      :ok
    else
      _ -> {:error, :context_unavailable}
    end
  end

  defp lock_tenant(repo) do
    tenant_id = Repo.tenant_id!()

    case repo.one(from t in Tenant, where: t.id == ^tenant_id, lock: "FOR KEY SHARE") do
      %Tenant{} -> :ok
      nil -> {:error, :context_unavailable}
    end
  end

  defp lock_client(repo, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Client{} = client <-
           repo.one(from c in Client, where: c.id == ^id, lock: "FOR KEY SHARE") do
      {:ok, client}
    else
      _ -> {:error, :not_found}
    end
  end

  defp offline?(scope), do: "offline_access" in String.split(scope, " ", trim: true)
end
