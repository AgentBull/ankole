defmodule Ankole.OIDC.Sessions do
  @moduledoc false
  require Ash.Query
  alias Ankole.{BrowserSessions, OIDC, Repo}
  alias Ankole.OIDC.Client
  alias Ankole.OIDC.LoginPolicy
  alias Ankole.OIDC.Session
  alias Ankole.Principals.HumanAccess

  def actor_for_session(id, principal, ip) do
    with %Session{} = session <-
           Session
           |> Ash.Query.filter(id == ^id and principal_uid == ^principal.uid)
           |> Ankole.Ash.read_one!(),
         %{provider_id: _} = proof <-
           BrowserSessions.authentication_evidence(session.authentication_id),
         do: {:ok, Ankole.AuthZ.Actor.from_evidence(principal, proof, "oidc_token", ip)},
         else: (_ -> {:error, :invalid_authentication})
  end

  def ensure(client_id, auth, scope),
    do: Repo.transact_top_level(fn -> ensure_in_tx(client_id, auth, scope) end)

  @doc """
  Inserts or extends the Session of one browser authentication and Client.

  The tenant and Client locks are access checks: they keep the tenant and the
  Client while the Session refers to them. `BrowserSessions.authorize_in_tx/2`
  locks the browser and the Human. The Session write is one upsert.
  """
  def ensure_in_tx(client_id, auth, scope) do
    ref = %{"id" => auth["authentication_id"], "revision" => auth["authentication_revision"]}

    with :ok <- lock_tenant(),
         :ok <- BrowserSessions.authorize_in_tx(ref, auth),
         :ok <- accepting_work(),
         {:ok, %Client{enabled: true} = client} <- lock_client(client_id),
         :ok <- LoginPolicy.authorize_source(client, auth["provider_id"]) do
      expiry =
        if offline?(scope),
          do: DateTime.add(DateTime.utc_now(), 30 * 24 * 60 * 60),
          else: DateTime.from_unix!(auth["expires_at"] * 1_000_000, :microsecond)

      Ankole.Ash.create(Session, :authorize_in_tx, %{
        client_id: client_id,
        principal_uid: auth["principal_uid"],
        browser_id: auth["browser_id"],
        authentication_id: auth["authentication_id"],
        authentication_revision: auth["authentication_revision"],
        access_version: auth["access_version"],
        provider_id: auth["provider_id"],
        auth_time: auth["auth_time"],
        expires_at: expiry
      })
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
         {:ok, principal} <- Ankole.Principals.get_principal(principal_uid),
         true <-
           Ankole.Principals.PodLoginPolicy.authentication_allowed?(
             principal,
             session.provider_id,
             BrowserSessions.authentication_evidence(session.authentication_id)
           ),
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
    with {:ok, session} <- get(id), do: Ankole.Ash.update(session, :revoke_in_tx, %{})
  end

  def end_authentication_in_tx(id, revision) do
    Session
    |> Ash.Query.for_read(:lookup_across_tenants)
    |> Ash.Query.filter(
      authentication_id == ^id and authentication_revision == ^revision and is_nil(ended_at)
    )
    |> lock_sessions()
    |> Ankole.Ash.read_across_tenants!(lock_identity: {:rows, "oidc_sessions", :id})
    |> terminate_sessions(:browser)
  end

  def end_browser_in_tx(browser_id) do
    Session
    |> Ash.Query.for_read(:lookup_across_tenants)
    |> Ash.Query.filter(browser_id == ^browser_id)
    |> lock_sessions()
    |> Ankole.Ash.read_across_tenants!(lock_identity: {:rows, "oidc_sessions", :id})
    |> terminate_sessions(:browser)
  end

  def revoke_human_in_tx(principal_uid, access_version) do
    Session
    |> Ash.Query.filter(principal_uid == ^principal_uid and access_version < ^access_version)
    |> lock_sessions()
    |> Ankole.Ash.read!(lock_identity: {:rows, "oidc_sessions", :id})
    |> terminate_sessions(:human)
  end

  defp lock_sessions(query),
    do: query |> Ash.Query.sort(id: :asc) |> Ash.Query.lock(:for_update)

  defp terminate_sessions(sessions, kind) do
    now = DateTime.utc_now()
    action = if kind == :human, do: :revoke_and_end_in_tx, else: :end_in_tx

    Enum.reduce_while(sessions, :ok, fn session, :ok ->
      Repo.with_tenant(session.tenant_id, fn ->
        with {:ok, session} <- Ankole.Ash.update(session, action, %{at: now}),
             %Client{} = client <- read_client(session.client_id),
             :ok <- Ankole.OIDC.Logout.enqueue_in_tx(session, client) do
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
         :ok <- lock_tenant(),
         %{} <- lock_principal(subject),
         {:ok, _client} <- lock_client(client_id),
         %Session{} <-
           Session
           |> Ash.Query.filter(
             id == ^session_id and client_id == ^client_id and principal_uid == ^subject
           )
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(lock_identity: {"oidc_sessions", session_id}) do
      :ok
    else
      _ -> {:error, :context_unavailable}
    end
  end

  # FOR KEY SHARE keeps the tenant while a credential refers to it.
  defp lock_tenant do
    case Ankole.Tenants.lock_tenant_in_tx(Repo.tenant_id!(), :key_share) do
      {:ok, _tenant} -> :ok
      {:error, :not_found} -> {:error, :context_unavailable}
    end
  end

  # FOR KEY SHARE keeps the Human while a credential refers to it.
  defp lock_principal(uid) do
    case Ankole.Principals.lock_principal_in_tx(uid, :key_share) do
      {:ok, principal} -> principal
      {:error, _reason} -> nil
    end
  end

  defp lock_client(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Client{} = client <-
           Client
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock("FOR KEY SHARE")
           |> Ankole.Ash.read_one!() do
      {:ok, client}
    else
      _ -> {:error, :not_found}
    end
  end

  defp read_client(id), do: Client |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  defp offline?(scope), do: "offline_access" in String.split(scope, " ", trim: true)
end
