defmodule Ankole.BrowserSessions.Identity do
  @moduledoc """
  Browser and authentication references, tenant identity resolution, and shared row locks.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{Authentication, PodAuthentication, Session}
  alias Ankole.Repo

  @session_ttl 24 * 60 * 60

  def session_ttl, do: @session_ttl

  def create do
    Ankole.Ash.create(Session, :create_in_tx, %{
      expires_at: DateTime.add(DateTime.utc_now(), @session_ttl)
    })
  end

  def reference(%Session{id: id}), do: %{"id" => id}

  def reference(%Authentication{id: id, revision: revision}),
    do: %{"id" => id, "revision" => revision}

  def encode_reference(%{"id" => id, "revision" => revision}), do: "#{id}.#{revision}"

  def decode_reference(value) when is_binary(value) do
    with [id, revision] <- String.split(value, "."),
         {:ok, id} <- Ecto.UUID.cast(id),
         {revision, ""} when revision > 0 <- Integer.parse(revision) do
      {:ok, %{"id" => id, "revision" => revision}}
    else
      _ -> {:error, :invalid_authentication}
    end
  end

  def decode_reference(_), do: {:error, :invalid_authentication}

  def get(ref), do: fetch_browser(ref, false)

  def lock_browser_in_tx(ref) do
    in_transaction!(:lock_browser_in_tx)
    fetch_browser(ref, true)
  end

  def get_authentication(ref), do: fetch_authentication(ref)

  def authentication_evidence(nil), do: %{}

  def authentication_evidence(id) do
    case read_authentication(id) do
      nil -> %{}
      authentication -> Map.from_struct(authentication)
    end
  end

  def current_reference(ref) do
    with {:ok, browser} <- get(ref),
         id when is_binary(id) <- browser.active_authentication_id,
         %Authentication{} = authentication <- read_authentication(id),
         {:ok, _} <- get_authentication(reference(authentication)) do
      reference(authentication)
    else
      _ -> nil
    end
  end

  def identity(ref, tenant_id) when is_binary(tenant_id) do
    with {:ok, authentication} <- get_authentication(ref) do
      identity_for_authentication(authentication, tenant_id)
    else
      _ -> nil
    end
  end

  def identity(_, _), do: nil

  def identities(ref) do
    with {:ok, authentication} <- get_authentication(ref) do
      PodAuthentication
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(authentication_id == ^authentication.id)
      |> Ankole.Ash.read_across_tenants!()
      |> Enum.flat_map(fn proof ->
        case identity_for_authentication(authentication, proof.tenant_id) do
          nil -> []
          identity -> [identity]
        end
      end)
    else
      _ -> []
    end
  end

  @doc false
  def authentication_identity(%Authentication{} = authentication, tenant_id)
      when is_binary(tenant_id),
      do: identity_for_authentication(authentication, tenant_id)

  defp identity_for_authentication(authentication, tenant_id),
    do: Repo.with_tenant(tenant_id, fn -> identity_in_tenant(authentication) end)

  defp identity_in_tenant(authentication) do
    with %PodAuthentication{} = proof <-
           PodAuthentication
           |> Ash.Query.filter(authentication_id == ^authentication.id)
           |> Ankole.Ash.read_one!(),
         {:ok, principal} <- Ankole.Principals.get_principal(proof.principal_uid),
         :ok <- Ankole.Principals.HumanAccess.check(principal, proof.access_version),
         true <- Ankole.Tenants.accepting_work?(proof.tenant_id),
         true <- current_binding?(authentication, proof),
         true <-
           Ankole.Principals.PodLoginPolicy.authentication_allowed?(
             principal,
             authentication.provider_id,
             Map.from_struct(authentication)
           ) do
      %{
        "authentication_id" => authentication.id,
        "authentication_revision" => authentication.revision,
        "browser_id" => authentication.browser_id,
        "tenant_id" => proof.tenant_id,
        "principal_uid" => proof.principal_uid,
        "access_version" => proof.access_version,
        "provider_id" => authentication.provider_id,
        "external_id" => authentication.external_id,
        "auth_time" => authentication.auth_time,
        "authenticated_at" => DateTime.to_unix(authentication.authenticated_at),
        "provider_scope" => Atom.to_string(authentication.scope),
        "amr" => authentication.amr,
        "challenge_started_at" => authentication.challenge_started_at,
        "verified_email" => authentication.verified_email,
        "verified_phone" => authentication.verified_phone,
        "expires_at" => DateTime.to_unix(authentication.expires_at)
      }
    else
      _ -> nil
    end
  end

  @doc false
  def current_binding?(%Authentication{scope: :site} = authentication, proof) do
    Ankole.IdentityProviders.SiteSources.registered?(authentication.provider_id) and
      Ankole.Principals.site_credential_bound?(
        proof.principal_uid,
        authentication.provider_id,
        authentication.subject_id
      )
  end

  def current_binding?(authentication, proof),
    do:
      authentication.tenant_id == proof.tenant_id and
        authentication.subject_id == proof.principal_uid

  def activate(browser_ref, authentication_ref, tenant_id \\ nil) do
    Repo.transact_top_level(fn ->
      activate_in_tx(browser_ref, authentication_ref, tenant_id)
    end)
  end

  @doc "Activates an authentication in the caller's transaction."
  def activate_in_tx(browser_ref, authentication_ref, tenant_id \\ nil) do
    in_transaction!(:activate_in_tx)

    with {:ok, browser} <- fetch_browser(browser_ref, true),
         {:ok, authentication} <- fetch_authentication(authentication_ref),
         true <- authentication.browser_id == browser.id,
         target_tenant <- tenant_id || authentication.tenant_id,
         true <- is_nil(target_tenant) or is_map(identity(authentication_ref, target_tenant)) do
      Ankole.Ash.update(browser, :activate_in_tx, %{
        active_authentication_id: authentication.id,
        active_tenant_id: target_tenant
      })
    else
      false -> {:error, :invalid_authentication}
      error -> error
    end
  end

  @doc """
  Holds a live authentication for an OAuth grant in the caller's transaction.

  The function locks the browser and the Human, and checks that the
  authentication still gives the same Human, access version, and provider.
  """
  def authorize_in_tx(authentication_ref, auth) do
    in_transaction!(:authorize_in_tx)

    with {:ok, authentication} <- fetch_authentication(authentication_ref),
         {:ok, _browser} <- fetch_browser(%{"id" => authentication.browser_id}, true),
         %{} = current <- identity(authentication_ref, Repo.tenant_id!()),
         true <-
           Map.take(current, ~w(principal_uid access_version provider_id)) ==
             Map.take(auth, ~w(principal_uid access_version provider_id)),
         {:ok, _} <- lock_human(current) do
      :ok
    else
      false -> {:error, :browser_session_expired}
      nil -> {:error, :browser_session_expired}
      error -> error
    end
  end

  @doc false
  def fetch_browser(%{"id" => id}, lock?) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      now = DateTime.utc_now()
      query = Ash.Query.filter(Session, id == ^id and expires_at > ^now)
      query = if lock?, do: Ash.Query.lock(query, :for_update), else: query
      opts = if lock?, do: [lock_identity: {"browser_sessions", id}], else: []

      case Ankole.Ash.read_one!(query, opts) do
        %Session{} = browser -> {:ok, browser}
        nil -> {:error, :browser_session_expired}
      end
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  def fetch_browser(_, _), do: {:error, :browser_session_expired}

  @doc false
  def fetch_authentication(%{"id" => id, "revision" => revision})
      when is_integer(revision) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Authentication{revision: ^revision, revoked_at: nil} = authentication <-
           read_authentication(id),
         true <- DateTime.compare(authentication.expires_at, DateTime.utc_now()) == :gt,
         {:ok, _} <- fetch_browser(%{"id" => authentication.browser_id}, false) do
      {:ok, authentication}
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  def fetch_authentication(_), do: {:error, :browser_session_expired}

  @doc false
  def read_authentication(id),
    do: Authentication |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()

  @doc false
  def lock_human(%{"principal_uid" => uid, "access_version" => version}) do
    case lock_principal(uid) do
      %{type: :human, status: :active, access_version: ^version} = principal ->
        {:ok, principal}

      _ ->
        {:error, :human_access_revoked}
    end
  end

  def lock_human(_), do: {:error, :invalid_authentication}

  # FOR SHARE holds the Human's status and access version until the commit.
  @doc false
  def lock_principal(uid) do
    case Ankole.Principals.lock_principal_in_tx(uid, :share) do
      {:ok, principal} -> principal
      {:error, _reason} -> nil
    end
  end

  @doc false
  def in_transaction!(operation) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {Ankole.BrowserSessions, operation}
        )

    :ok
  end

  @doc false
  def csrf_state, do: Base.url_encode64(:crypto.strong_rand_bytes(18))
end
