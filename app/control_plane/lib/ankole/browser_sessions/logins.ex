defmodule Ankole.BrowserSessions.Logins do
  @moduledoc """
  Browser authentication completion and outbound upstream OIDC ceremony state.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{
    Authentication,
    Identity,
    OidcState,
    PodAccess,
    Revocation
  }

  alias Ankole.OIDC.{AuthorizationRequests, LoginPolicy}
  alias Ankole.Repo

  @oidc_state_ttl 10 * 60
  @tenant_purposes [:console, :oauth, :pod]
  @site_purposes [:console, :oauth, :pod, :site]

  def begin_oidc_state(ref, attrs) when is_map(attrs) do
    Repo.transact_top_level(fn -> begin_oidc_state_in_tx(ref, attrs) end)
  end

  @doc "Creates an outbound upstream OIDC state in the caller's transaction."
  def begin_oidc_state_in_tx(ref, attrs) when is_map(attrs) do
    Identity.in_transaction!(:begin_oidc_state_in_tx)
    purpose = Map.fetch!(attrs, :purpose)

    with {:ok, browser} <- Identity.fetch_browser(ref, true) do
      Ankole.Ash.create(OidcState, :begin_in_tx, %{
        state: Map.fetch!(attrs, :state),
        browser_id: browser.id,
        tenant_id: Repo.tenant_id!(),
        provider_id: Map.fetch!(attrs, :provider_id),
        purpose: purpose,
        mode: Map.get(attrs, :mode) || default_mode(purpose),
        started_revision: Map.get(attrs, :started_revision) || browser.revision,
        redirect_uri: Map.fetch!(attrs, :redirect_uri),
        return_to: Map.get(attrs, :return_to) || "/",
        prompt: Map.get(attrs, :prompt) || [],
        invitation_id: Map.get(attrs, :invitation_id),
        expected_authentication_id: Map.get(attrs, :expected_authentication_id),
        reauthentication_principal_uid: Map.get(attrs, :reauthentication_principal_uid),
        oauth_request_id: Map.get(attrs, :oauth_request_id),
        expires_at: DateTime.add(DateTime.utc_now(), @oidc_state_ttl)
      })
    end
  end

  def oidc_callback(ref, provider_id, state) when is_binary(state) and state != "" do
    with {:ok, browser} <- Identity.get(ref),
         %OidcState{} = oidc_state <-
           OidcState
           |> Ash.Query.filter(state == ^state and provider_id == ^provider_id)
           |> Ankole.Ash.read_one!(),
         true <- live_oidc_state?(oidc_state, browser) do
      {:ok, oidc_state}
    else
      _ -> {:error, :login_expired}
    end
  end

  def oidc_callback(_, _, _), do: {:error, :login_expired}

  @doc "Consumes an outbound OIDC state and completes its authentication in the caller's transaction."
  def consume_oidc_state_in_tx(ref, id, auth) do
    Identity.in_transaction!(:consume_oidc_state_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, id} <- Ecto.UUID.cast(id),
         %OidcState{} = oidc_state <-
           OidcState |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         {:live, true} <- {:live, live_oidc_state?(oidc_state, browser)},
         {:tenant, true} <- {:tenant, oidc_state.tenant_id == Repo.tenant_id!()},
         {:provider, true} <- {:provider, oidc_state.provider_id == auth["provider_id"]},
         {:ok, consumed} <-
           oidc_state |> Ankole.Ash.update(:consume_in_tx, %{}) |> Ankole.Errors.reason(),
         {:ok, completed} <-
           authenticate_in_tx(ref, consumed.purpose, auth,
             mode: consumed.mode,
             started_revision: consumed.started_revision,
             challenge_started_at: consumed.inserted_at,
             expected_authentication_id: consumed.expected_authentication_id,
             reauthentication_principal_uid: consumed.reauthentication_principal_uid,
             oauth_request_id: consumed.oauth_request_id,
             oidc_state_id: consumed.id
           ) do
      {:ok, Map.put(completed, :oidc_state, consumed)}
    else
      {:provider, false} -> {:error, :login_provider_mismatch}
      {:live, false} -> {:error, :login_expired}
      {:tenant, false} -> {:error, :login_expired}
      nil -> {:error, :login_expired}
      :error -> {:error, :login_expired}
      {:error, :stale} -> {:error, :login_expired}
      error -> error
    end
  end

  def authenticate(ref, purpose, auth, opts \\ []) when purpose in @tenant_purposes do
    Repo.transact_top_level(fn -> authenticate_in_tx(ref, purpose, auth, opts) end)
  end

  @doc "Completes an enterprise or local-tenant authentication in the caller's transaction."
  def authenticate_in_tx(ref, purpose, auth, opts \\ []) when purpose in @tenant_purposes do
    Identity.in_transaction!(:authenticate_in_tx)
    tenant_id = Repo.tenant_id!()
    started_at = Keyword.get_lazy(opts, :challenge_started_at, &DateTime.utc_now/0)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         :ok <- ensure_oauth_request_pending(ref, purpose, opts),
         false <- Ankole.IdentityProviders.SiteSources.registered?(auth["provider_id"]),
         {:ok, principal} <- Identity.lock_human(auth),
         :ok <- can_complete(purpose, started_at, principal, auth) do
      context = build_context(browser, purpose, tenant_id, opts)

      persist_login(
        ref,
        browser,
        context,
        auth["provider_id"],
        principal.uid,
        auth["auth_time"],
        auth["external_id"],
        [principal],
        %{challenge_started_at: started_at, amr: auth["amr"] || ["oidc"]}
      )
    else
      true -> {:error, :invalid_authentication}
      error -> error
    end
  end

  def authenticate_site(ref, purpose, provider_id, proof, opts \\ [])
      when purpose in @site_purposes do
    Repo.transact_top_level(fn ->
      authenticate_site_in_tx(ref, purpose, provider_id, proof, opts)
    end)
  end

  @doc "Completes a site credential authentication in the caller's transaction."
  def authenticate_site_in_tx(ref, purpose, provider_id, proof, opts \\ [])
      when purpose in @site_purposes do
    Identity.in_transaction!(:authenticate_site_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, context, oauth_request} <- site_context(ref, browser, purpose, opts),
         {:ok, %{subject_id: subject_id, auth_time: auth_time} = verified} <-
           Ankole.IdentityProviders.SiteSources.authenticate(provider_id, proof),
         :ok <- site_flow_policy(context, oauth_request, provider_id, verified),
         {:ok, principals} <- site_principals(context.tenant_id, provider_id, verified),
         :ok <- ensure_console_admin(context, principals) do
      persist_login(
        ref,
        browser,
        context,
        provider_id,
        subject_id,
        auth_time,
        subject_id,
        principals,
        verified
      )
    end
  end

  def replace_site_credential_in_tx(ref, %Ankole.AuthZ.Actor{} = actor, proof) do
    Identity.in_transaction!(:replace_site_credential_in_tx)
    tenant_id = Repo.tenant_id!()

    with true <- Ankole.AuthZ.Actor.tenant_id(actor) == tenant_id,
         {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, principals} <- site_principals(tenant_id, proof.provider_id, proof) do
      context = build_context(browser, :pod, tenant_id, mode: :add)

      persist_login(
        ref,
        browser,
        context,
        proof.provider_id,
        proof.subject_id,
        proof.auth_time,
        proof.subject_id,
        principals,
        proof
      )
    else
      false -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp ensure_oauth_request_pending(ref, :oauth, opts) do
    case Keyword.get(opts, :oauth_request_id) do
      nil ->
        :ok

      id ->
        case AuthorizationRequests.get(ref, id) do
          {:ok, %{status: :pending}} -> :ok
          {:ok, _} -> {:error, :login_expired}
          error -> error
        end
    end
  end

  defp ensure_oauth_request_pending(_ref, _purpose, _opts), do: :ok

  defp site_context(ref, browser, :oauth, opts) do
    oauth_request_id = Keyword.fetch!(opts, :oauth_request_id)

    with {:ok, %{status: :pending} = oauth_request} <-
           AuthorizationRequests.get(ref, oauth_request_id) do
      opts =
        opts
        |> Keyword.put_new(:started_revision, oauth_request.started_revision)
        |> Keyword.put_new(:expected_authentication_id, oauth_request.expected_authentication_id)

      {:ok, build_context(browser, :oauth, oauth_request.tenant_id, opts), oauth_request}
    else
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  defp site_context(_ref, browser, :site, opts),
    do: {:ok, build_context(browser, :site, nil, opts), nil}

  defp site_context(_ref, browser, purpose, opts) when purpose in [:pod, :console],
    do: {:ok, build_context(browser, purpose, Repo.tenant_id!(), opts), nil}

  defp build_context(browser, purpose, tenant_id, opts) do
    %{
      purpose: purpose,
      tenant_id: tenant_id,
      mode: Keyword.get(opts, :mode) || default_mode(purpose),
      started_revision: Keyword.get(opts, :started_revision) || browser.revision,
      expected_authentication_id: Keyword.get(opts, :expected_authentication_id),
      reauthentication_principal_uid: Keyword.get(opts, :reauthentication_principal_uid),
      oauth_request_id: Keyword.get(opts, :oauth_request_id),
      oidc_state_id: Keyword.get(opts, :oidc_state_id)
    }
  end

  defp default_mode(:pod), do: :add
  defp default_mode(:site), do: :add
  defp default_mode(_), do: :replace

  defp site_flow_policy(%{purpose: :site}, _oauth_request, _provider_id, _proof), do: :ok

  defp site_flow_policy(
         %{purpose: :oauth, tenant_id: tenant_id},
         oauth_request,
         provider_id,
         proof
       ) do
    Repo.with_tenant(tenant_id, fn ->
      with :ok <- LoginPolicy.authorize_login(oauth_request, provider_id) do
        LoginPolicy.completed_authentication_allowed?(
          %{"auth_time" => proof.auth_time},
          oauth_request.request
        )
      end
    end)
  end

  defp site_flow_policy(
         %{purpose: purpose, tenant_id: tenant_id},
         _oauth_request,
         provider_id,
         _proof
       ) do
    Repo.with_tenant(tenant_id, fn -> LoginPolicy.authorize_login(purpose, provider_id) end)
  end

  defp ensure_console_admin(%{purpose: :console, tenant_id: tenant_id}, principals) do
    admin? =
      Repo.with_tenant(tenant_id, fn ->
        Enum.any?(
          principals,
          &(&1.tenant_id == tenant_id and Ankole.AuthZ.site_admin?(&1.uid))
        )
      end)

    if admin?, do: :ok, else: {:error, :not_an_admin}
  end

  defp ensure_console_admin(_context, _principals), do: :ok

  defp site_principal(tenant_id, uid, candidate, provider_id, proof) do
    Repo.with_tenant(tenant_id, fn ->
      case Identity.lock_principal(uid) do
        %{type: :human, status: :active} = principal ->
          validate_site_principal(tenant_id, principal, candidate, provider_id, proof)

        _ ->
          {:error, :human_access_revoked}
      end
    end)
  end

  defp validate_site_principal(tenant_id, principal, candidate, provider_id, proof) do
    cond do
      not fresh_for_human_at?(proof.challenge_started_at, principal) ->
        {:error, :human_access_revoked}

      not Ankole.Tenants.accepting_work?(tenant_id) ->
        {:error, :tenant_suspended}

      not Ankole.Principals.PodLoginPolicy.authentication_allowed?(
        principal,
        provider_id,
        proof
      ) ->
        {:error, :login_policy_rejected}

      candidate && candidate.uid == principal.uid ->
        bind_claimed_principal(principal, proof)

      true ->
        {:ok, principal}
    end
  end

  defp bind_claimed_principal(principal, proof) do
    with true <- Ankole.Principals.site_credential_claim_current?(proof),
         {:ok, _} <- Ankole.Principals.bind_site_credential_in_tx(principal.uid, proof),
         do: {:ok, principal},
         else: (
           false -> {:error, :reauthentication_required}
           error -> error
         )
  end

  defp site_principals(target_tenant_id, provider_id, proof) do
    bindings =
      provider_id
      |> Ankole.Principals.list_site_credentials(proof.subject_id)
      |> Enum.map(&{&1.tenant_id, &1.principal_uid})

    candidate =
      if target_tenant_id && not List.keymember?(bindings, target_tenant_id, 0) do
        proof
        |> Ankole.Principals.pending_site_memberships()
        |> Enum.find(&(&1.tenant_id == target_tenant_id))
      end

    targets = if candidate, do: [{candidate.tenant_id, candidate.uid} | bindings], else: bindings

    targets
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.reduce_while({:ok, []}, fn {tenant_id, uid}, {:ok, principals} ->
      case site_principal(tenant_id, uid, candidate, provider_id, proof) do
        {:ok, principal} -> {:cont, {:ok, [principal | principals]}}
        {:error, _} = error when tenant_id == target_tenant_id -> {:halt, error}
        {:error, _} -> {:cont, {:ok, principals}}
      end
    end)
    |> case do
      {:ok, principals} ->
        if target_tenant_id && not Enum.any?(principals, &(&1.tenant_id == target_tenant_id)),
          do: {:error, :not_a_member},
          else: {:ok, principals}

      error ->
        error
    end
  end

  defp persist_login(
         browser_ref,
         browser,
         context,
         provider_id,
         subject_id,
         auth_time,
         external_id,
         principals,
         proof
       ) do
    site? = Ankole.IdentityProviders.SiteSources.registered?(provider_id)

    attributes = [
      browser_id: browser.id,
      provider_id: provider_id,
      subject_id: subject_id,
      purpose: if(site?, do: :site, else: context.purpose),
      tenant_id: if(site?, do: nil, else: context.tenant_id)
    ]

    old = find_subject(attributes)
    renew_site? = site? and live?(old)

    with :ok <- unchanged_target(context, old),
         :ok <- expected_subject(context, provider_id, subject_id, principals),
         :ok <- replace_context(browser, context, old, subject_id),
         :ok <- if(renew_site?, do: :ok, else: Revocation.end_authentication(old)),
         {:ok, authentication} <-
           persist_authentication(old, attributes, %{
             revision: if(renew_site?, do: old.revision, else: browser.revision + 1),
             auth_time: auth_time,
             authenticated_at: DateTime.utc_now(),
             challenge_started_at: Map.fetch!(proof, :challenge_started_at),
             amr: Map.get(proof, :amr, []),
             verified_email: Map.get(proof, :verified_email),
             verified_phone: Map.get(proof, :verified_phone),
             external_id: external_id,
             console_authenticated:
               context.purpose == :console or (renew_site? and old.console_authenticated),
             csrf_token: if(renew_site?, do: old.csrf_token, else: Identity.csrf_state()),
             expires_at: DateTime.add(DateTime.utc_now(), Identity.session_ttl())
           }),
         :ok <- PodAccess.save_pod_authentications(authentication, principals),
         {:ok, browser} <-
           Ankole.Ash.update(browser, :record_login_in_tx, %{
             revision: max(browser.revision, authentication.revision),
             active_authentication_id: authentication.id,
             active_tenant_id: context.tenant_id,
             expires_at:
               if(DateTime.compare(browser.expires_at, authentication.expires_at) == :gt,
                 do: browser.expires_at,
                 else: authentication.expires_at
               )
           }),
         {:ok, oauth_request} <-
           complete_oauth_request(browser_ref, context, authentication, site?) do
      {:ok, %{browser: browser, authentication: authentication, oauth_request: oauth_request}}
    end
  end

  defp complete_oauth_request(_browser_ref, %{oauth_request_id: nil}, _authentication, _site?),
    do: {:ok, nil}

  defp complete_oauth_request(
         browser_ref,
         %{oauth_request_id: id, tenant_id: tenant_id},
         authentication,
         site?
       ) do
    Repo.with_tenant(tenant_id, fn ->
      with {:ok, request} <-
             AuthorizationRequests.authenticate_in_tx(browser_ref, id, authentication) do
        if site? do
          AuthorizationRequests.select_identity_in_tx(
            browser_ref,
            request.id,
            Identity.reference(authentication)
          )
        else
          {:ok, request}
        end
      end
    end)
  end

  defp live?(%Authentication{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp live?(_), do: false

  defp live_oidc_state?(oidc_state, browser) do
    oidc_state.browser_id == browser.id and
      oidc_state.started_revision >= browser.logout_revision and
      is_nil(oidc_state.consumed_at) and
      DateTime.compare(oidc_state.expires_at, DateTime.utc_now()) == :gt
  end

  defp persist_authentication(nil, subject, proof),
    do: Ankole.Ash.create(Authentication, :create_in_tx, Map.merge(Map.new(subject), proof))

  defp persist_authentication(authentication, _subject, proof),
    do: Ankole.Ash.update(authentication, :renew_in_tx, proof)

  defp unchanged_target(_context, nil), do: :ok

  defp unchanged_target(context, authentication) do
    if authentication.revision <= context.started_revision,
      do: :ok,
      else: {:error, :login_expired}
  end

  defp find_subject(attributes) do
    tenant_id = attributes[:tenant_id]

    query =
      Ash.Query.filter(
        Authentication,
        browser_id == ^attributes[:browser_id] and provider_id == ^attributes[:provider_id] and
          subject_id == ^attributes[:subject_id] and purpose == ^attributes[:purpose]
      )

    query =
      if is_nil(tenant_id),
        do: Ash.Query.filter(query, is_nil(tenant_id)),
        else: Ash.Query.filter(query, tenant_id == ^tenant_id)

    Ankole.Ash.read_one!(query)
  end

  defp expected_subject(
         %{purpose: :pod, reauthentication_principal_uid: uid} = context,
         _provider_id,
         _subject_id,
         principals
       )
       when is_binary(uid) do
    case Identity.read_authentication(context.expected_authentication_id) do
      %Authentication{revoked_at: nil, revision: revision}
      when revision <= context.started_revision ->
        if Enum.any?(principals, &(&1.uid == uid and &1.tenant_id == context.tenant_id)),
          do: :ok,
          else: {:error, :login_subject_mismatch}

      _ ->
        {:error, :login_expired}
    end
  end

  defp expected_subject(%{expected_authentication_id: nil}, _, _, _), do: :ok

  defp expected_subject(context, provider_id, subject_id, _principals) do
    case Identity.read_authentication(context.expected_authentication_id) do
      %Authentication{revoked_at: nil, revision: revision} = expected
      when revision <= context.started_revision ->
        if expected.provider_id == provider_id and expected.subject_id == subject_id,
          do: :ok,
          else: {:error, :login_subject_mismatch}

      _ ->
        {:error, :login_expired}
    end
  end

  defp replace_context(_browser, %{mode: :add}, _old, _subject_id), do: :ok

  defp replace_context(browser, context, old, subject_id) do
    replaced =
      browser.id
      |> Revocation.live_authentications()
      |> Enum.filter(fn authentication ->
        authentication.id != (old && old.id) and
          (authentication.purpose == context.purpose or
             (context.purpose in [:console, :oauth] and
                authentication.purpose in [:console, :oauth] and
                authentication.subject_id != subject_id))
      end)

    purposes =
      if context.purpose in [:console, :oauth],
        do: [:console, :oauth],
        else: [context.purpose]

    with :ok <- Revocation.revoke_records(replaced, browser.revision + 1),
         :ok <- maybe_cancel_oauth_requests(browser.id, context) do
      query =
        OidcState
        |> Ash.Query.filter(
          browser_id == ^browser.id and purpose in ^purposes and is_nil(consumed_at)
        )

      query =
        if context.oidc_state_id,
          do: Ash.Query.filter(query, id != ^context.oidc_state_id),
          else: query

      Revocation.expire_oidc_states(query)
    end
  end

  defp maybe_cancel_oauth_requests(browser_id, %{purpose: purpose, oauth_request_id: except_id})
       when purpose in [:console, :oauth],
       do: AuthorizationRequests.cancel_for_browser_in_tx(browser_id, except_id: except_id)

  defp maybe_cancel_oauth_requests(_browser_id, _context), do: :ok

  defp can_complete(purpose, started_at, principal, auth) do
    cond do
      not Ankole.Tenants.accepting_work?(principal.tenant_id) ->
        {:error, :tenant_suspended}

      not fresh_for_human_at?(started_at, principal) ->
        {:error, :human_access_revoked}

      not Ankole.Principals.PodLoginPolicy.authentication_allowed?(
        principal,
        auth["provider_id"],
        auth
      ) ->
        {:error, :login_policy_rejected}

      purpose == :console and not Ankole.AuthZ.site_admin?(principal.uid) ->
        {:error, :not_an_admin}

      true ->
        :ok
    end
  end

  defp fresh_for_human_at?(started_at, principal),
    do:
      is_nil(principal.access_revoked_at) or
        DateTime.compare(started_at, principal.access_revoked_at) == :gt
end
