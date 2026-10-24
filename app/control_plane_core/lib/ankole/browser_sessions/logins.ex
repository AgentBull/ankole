defmodule Ankole.BrowserSessions.Logins do
  @moduledoc """
  One-use browser login transactions, provider binding, completion, and consumption.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{
    Authentication,
    Identity,
    LoginTransaction,
    PodAccess,
    Revocation
  }

  alias Ankole.Repo

  @login_ttl 10 * 60
  @purposes [:console, :oauth, :pod, :site]

  def begin_login(ref, purpose, request, opts \\ [])
      when purpose in @purposes and is_map(request) do
    Repo.transact_top_level(fn -> begin_login_in_tx(ref, purpose, request, opts) end)
  end

  @doc "Begins a login transaction in the caller's transaction."
  def begin_login_in_tx(ref, purpose, request, opts \\ [])
      when purpose in @purposes and is_map(request) do
    Identity.in_transaction!(:begin_login_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, authentication} <- login_authentication(browser, purpose, opts),
         {:ok, transaction} <-
           Ankole.Ash.create(LoginTransaction, :begin_in_tx, %{
             browser_id: browser.id,
             tenant_id: if(purpose == :site, do: nil, else: Repo.tenant_id!()),
             started_revision: browser.revision,
             purpose: purpose,
             mode: Keyword.get(opts, :mode, :replace),
             expected_authentication_id:
               if(authentication,
                 do: authentication.id,
                 else: Keyword.get(opts, :expected_authentication_id)
               ),
             request: request,
             csrf_token: Identity.csrf_state(),
             expires_at: DateTime.add(DateTime.utc_now(), @login_ttl)
           }) do
      bind_login_proof(transaction, authentication, opts)
    end
  end

  def login(ref, id) do
    with {:ok, browser} <- Identity.get(ref), do: fetch_login(browser, id)
  end

  def transaction_csrf(ref, id) do
    with {:ok, transaction} <- login(ref, id) do
      transaction.csrf_token
    else
      _ -> nil
    end
  end

  def callback(ref, provider_id, state) when is_binary(state) and state != "" do
    with %LoginTransaction{} = transaction <-
           LoginTransaction
           |> Ash.Query.filter(upstream_state == ^state and provider_id == ^provider_id)
           |> Ankole.Ash.read_one!(),
         {:ok, %{status: :pending} = transaction} <- login(ref, transaction.id),
         do: {:ok, transaction},
         else: (_ -> {:error, :login_expired})
  end

  def callback(_, _, _), do: {:error, :login_expired}

  def bind_provider(ref, id, provider_id, state \\ nil, redirect_uri \\ nil) do
    Repo.transact_top_level(fn ->
      bind_provider_in_tx(ref, id, provider_id, state, redirect_uri)
    end)
  end

  @doc "Selects the login provider in the caller's transaction."
  def bind_provider_in_tx(ref, id, provider_id, state \\ nil, redirect_uri \\ nil) do
    update_login_in_tx(:bind_provider_in_tx, ref, id, fn
      %LoginTransaction{status: :pending, provider_id: nil} = transaction ->
        Ankole.Ash.update(transaction, :bind_provider_in_tx, %{
          provider_id: provider_id,
          upstream_state: state,
          redirect_uri: redirect_uri
        })

      %LoginTransaction{status: :pending, provider_id: ^provider_id, upstream_state: nil} =
          transaction
      when is_nil(state) ->
        {:ok, transaction}

      _ ->
        {:error, :login_provider_already_selected}
    end)
  end

  @doc """
  Completes a pending login.

  `before_commit` runs in the transaction of the login, so it calls only
  `_in_tx` functions.
  """
  def complete_login(ref, id, auth, before_commit \\ fn -> :ok end) do
    Repo.transact_top_level(fn -> complete_login_in_tx(ref, id, auth, before_commit) end)
  end

  @doc false
  def complete_login_in_tx(ref, id, auth, before_commit) do
    Identity.in_transaction!(:complete_login_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, %LoginTransaction{status: :pending, purpose: purpose} = transaction} <-
           fetch_login(browser, id),
         true <- purpose != :site and transaction.tenant_id == Repo.tenant_id!(),
         false <- Ankole.IdentityProviders.SiteSources.registered?(auth["provider_id"]),
         {:ok, principal} <- Identity.lock_human(auth),
         :ok <- can_complete(transaction, principal, auth),
         :ok <- before_commit.() do
      persist_login(
        browser,
        transaction,
        auth["provider_id"],
        principal.uid,
        auth["auth_time"],
        auth["external_id"],
        [principal],
        %{challenge_started_at: transaction.inserted_at, amr: auth["amr"] || ["oidc"]}
      )
    else
      true -> {:error, :invalid_authentication}
      false -> {:error, :invalid_authentication}
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  def complete_site_login(ref, id, provider_id, proof) do
    Repo.transact_top_level(fn -> complete_site_login_in_tx(ref, id, provider_id, proof) end)
  end

  @doc "Completes a site login in the caller's transaction."
  def complete_site_login_in_tx(ref, id, provider_id, proof) do
    Identity.in_transaction!(:complete_site_login_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, %LoginTransaction{status: :pending, purpose: purpose} = transaction} <-
           fetch_login(browser, id),
         true <-
           purpose in [:site, :oauth, :pod, :console] and transaction.provider_id == provider_id,
         {:ok, %{subject_id: subject_id, auth_time: auth_time} = verified} <-
           Ankole.IdentityProviders.SiteSources.authenticate(provider_id, proof),
         :ok <- site_flow_policy(transaction, provider_id, verified),
         {:ok, principals} <- site_principals(transaction, provider_id, verified) do
      if transaction.purpose != :console or
           Repo.with_tenant(transaction.tenant_id, fn ->
             Enum.any?(
               principals,
               &(&1.tenant_id == transaction.tenant_id and Ankole.AuthZ.site_admin?(&1.uid))
             )
           end) do
        persist_login(
          browser,
          transaction,
          provider_id,
          subject_id,
          auth_time,
          subject_id,
          principals,
          verified
        )
      else
        {:error, :not_an_admin}
      end
    else
      false -> {:error, :login_provider_mismatch}
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  defp site_flow_policy(%{purpose: :site}, _provider_id, _proof), do: :ok

  defp site_flow_policy(transaction, provider_id, proof) do
    Repo.with_tenant(transaction.tenant_id, fn ->
      with :ok <- Ankole.OIDC.LoginPolicy.authorize_login(transaction, provider_id),
           do:
             Ankole.OIDC.LoginPolicy.completed_authentication_allowed?(
               %{"auth_time" => proof.auth_time},
               transaction.request
             )
    end)
  end

  def select_authorization(ref, id, authentication_ref) do
    Repo.transact_top_level(fn ->
      select_authorization_in_tx(ref, id, authentication_ref)
    end)
  end

  @doc "Selects the authentication of a login in the caller's transaction."
  def select_authorization_in_tx(ref, id, authentication_ref) do
    Identity.in_transaction!(:select_authorization_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, %LoginTransaction{purpose: purpose} = transaction} when purpose in [:oauth, :pod] <-
           fetch_login(browser, id),
         {:ok, authentication} <- Identity.fetch_authentication(authentication_ref),
         true <- authentication.browser_id == browser.id,
         %{} = auth <- Identity.identity(authentication_ref, transaction.tenant_id),
         {:ok, request, action} <-
           Repo.with_tenant(transaction.tenant_id, fn ->
             select_request(transaction, auth)
           end) do
      {action, attrs} =
        if action == :reuse,
          do:
            {if(purpose == :pod, do: :consume_in_tx, else: :authenticate_in_tx),
             %{
               authentication_id: authentication.id,
               authentication_revision: authentication.revision
             }},
          else: {:reauthenticate_in_tx, %{expected_authentication_id: authentication.id}}

      with {:ok, _} <-
             Ankole.Ash.update(browser, :activate_in_tx, %{
               active_authentication_id: authentication.id,
               active_tenant_id: transaction.tenant_id
             }),
           do:
             Ankole.Ash.update(
               transaction,
               action,
               Map.merge(attrs, %{request: request, started_revision: browser.revision})
             )
    else
      false -> {:error, :invalid_authentication}
      nil -> {:error, :invalid_authentication}
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  @doc """
  Consumes an authenticated OAuth login and issues its grant.

  `issue` runs in the transaction of the consumption, so it calls only
  `_in_tx` functions.
  """
  def consume_authorization(ref, id, authentication_ref, issue) when is_function(issue, 2) do
    with {:ok, transaction} <- login(ref, id) do
      Repo.with_tenant(transaction.tenant_id, fn ->
        Repo.transact_top_level(fn ->
          consume_authorization_in_tx(ref, id, authentication_ref, issue)
        end)
      end)
    end
  end

  @doc false
  def consume_authorization_in_tx(ref, id, authentication_ref, issue) do
    Identity.in_transaction!(:consume_authorization_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, %LoginTransaction{purpose: :oauth} = transaction} <- fetch_login(browser, id),
         true <- Ankole.OIDC.LoginPolicy.authorization_ready?(transaction),
         true <-
           authentication_ref == %{
             "id" => transaction.authentication_id,
             "revision" => transaction.authentication_revision
           },
         %{} = auth <- Identity.identity(authentication_ref, transaction.tenant_id),
         {:ok, _} <- Identity.lock_human(auth),
         {:ok, _} <- Ankole.Ash.update(transaction, :consume_in_tx, %{}) do
      issue.(transaction.request, auth)
    else
      {:ok, _} -> {:error, :login_expired}
      nil -> {:error, :login_expired}
      false -> {:error, :login_expired}
      error -> error
    end
  end

  @doc """
  Consumes one pending transaction in its fixed tenant, without minting an authentication.

  `complete` runs in the transaction of the consumption, so it calls only
  `_in_tx` functions.
  """
  def consume_login(ref, id, purpose, complete)
      when purpose in @purposes and is_function(complete, 1) do
    with {:ok, transaction} <- login(ref, id) do
      in_context = fn ->
        Repo.transact_top_level(fn -> consume_login_in_tx(ref, id, purpose, complete) end)
      end

      if transaction.tenant_id,
        do: Repo.with_tenant(transaction.tenant_id, in_context),
        else: Repo.without_tenant(in_context)
    end
  end

  @doc false
  def consume_login_in_tx(ref, id, purpose, complete) do
    Identity.in_transaction!(:consume_login_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, %LoginTransaction{status: :pending, purpose: ^purpose} = transaction} <-
           fetch_login(browser, id),
         {:ok, result} <- complete.(transaction),
         {:ok, _} <- Ankole.Ash.update(transaction, :consume_in_tx, %{}) do
      {:ok, result}
    else
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  defp login_authentication(browser, purpose, opts) do
    case Keyword.fetch(opts, :authentication_ref) do
      :error ->
        {:ok, nil}

      {:ok, ref} ->
        with true <- purpose == :pod and Keyword.get(opts, :mode, :replace) == :add,
             {:ok, authentication} <- Identity.fetch_authentication(ref),
             true <- authentication.browser_id == browser.id,
             %{} = auth <- Identity.identity(ref, Repo.tenant_id!()),
             {:ok, _principal} <- Identity.lock_human(auth) do
          {:ok, authentication}
        else
          false -> {:error, :invalid_authentication}
          nil -> {:error, :invalid_authentication}
          error -> error
        end
    end
  end

  defp bind_login_proof(transaction, nil, _opts), do: {:ok, transaction}

  defp bind_login_proof(transaction, authentication, opts) do
    Ankole.Ash.update(transaction, :bind_proof_in_tx, %{
      authentication_id: authentication.id,
      authentication_revision: authentication.revision,
      upstream_state: Keyword.get(opts, :upstream_state)
    })
  end

  defp site_principal(tenant_id, uid, candidate, provider_id, proof) do
    Repo.with_tenant(tenant_id, fn ->
      case Identity.lock_principal(uid) do
        %{type: :human, status: :active} = principal ->
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

            candidate && candidate.uid == uid ->
              bind_claimed_principal(principal, proof)

            true ->
              {:ok, principal}
          end

        _ ->
          {:error, :human_access_revoked}
      end
    end)
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

  defp site_principals(transaction, provider_id, proof) do
    bindings =
      provider_id
      |> Ankole.Principals.list_site_credentials(proof.subject_id)
      |> Enum.map(&{&1.tenant_id, &1.principal_uid})

    candidate =
      if transaction.tenant_id && not List.keymember?(bindings, transaction.tenant_id, 0) do
        proof
        |> Ankole.Principals.pending_site_memberships()
        |> Enum.find(&(&1.tenant_id == transaction.tenant_id))
      end

    targets = if candidate, do: [{candidate.tenant_id, candidate.uid} | bindings], else: bindings

    targets
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.reduce_while({:ok, []}, fn {tenant_id, uid}, {:ok, principals} ->
      result = site_principal(tenant_id, uid, candidate, provider_id, proof)

      case result do
        {:ok, principal} -> {:cont, {:ok, [principal | principals]}}
        {:error, _} = error when tenant_id == transaction.tenant_id -> {:halt, error}
        {:error, _} -> {:cont, {:ok, principals}}
      end
    end)
    |> case do
      {:ok, principals} ->
        if transaction.tenant_id &&
             not Enum.any?(principals, &(&1.tenant_id == transaction.tenant_id)),
           do: {:error, :not_a_member},
           else: {:ok, principals}

      error ->
        error
    end
  end

  defp persist_login(
         browser,
         transaction,
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
      purpose: if(site?, do: :site, else: transaction.purpose),
      tenant_id: if(site?, do: nil, else: transaction.tenant_id)
    ]

    old = find_subject(attributes)
    renew_site? = site? and live?(old)

    with :ok <- unchanged_target(transaction, old),
         :ok <- expected_subject(transaction, provider_id, subject_id, principals),
         :ok <- replace_context(browser, transaction, old, subject_id),
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
               transaction.purpose == :console or (renew_site? and old.console_authenticated),
             csrf_token: if(renew_site?, do: old.csrf_token, else: Identity.csrf_state()),
             expires_at: DateTime.add(DateTime.utc_now(), Identity.session_ttl())
           }),
         :ok <- PodAccess.save_pod_authentications(authentication, principals),
         {:ok, browser} <-
           Ankole.Ash.update(browser, :record_login_in_tx, %{
             revision: max(browser.revision, authentication.revision),
             active_authentication_id: authentication.id,
             active_tenant_id: transaction.tenant_id,
             expires_at:
               if(DateTime.compare(browser.expires_at, authentication.expires_at) == :gt,
                 do: browser.expires_at,
                 else: authentication.expires_at
               )
           }),
         {:ok, transaction} <-
           Ankole.Ash.update(
             transaction,
             if(transaction.purpose == :oauth, do: :authenticate_in_tx, else: :consume_in_tx),
             %{
               authentication_id: authentication.id,
               authentication_revision: authentication.revision
             }
           ) do
      {:ok, %{browser: browser, transaction: transaction, authentication: authentication}}
    end
  end

  defp live?(%Authentication{revoked_at: nil, expires_at: expires_at}),
    do: DateTime.compare(expires_at, DateTime.utc_now()) == :gt

  defp live?(_), do: false

  def replace_site_credential_in_tx(ref, %Ankole.AuthZ.Actor{} = actor, proof) do
    Identity.in_transaction!(:replace_site_credential_in_tx)

    with true <- Ankole.AuthZ.Actor.tenant_id(actor) == Repo.tenant_id!(),
         {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, transaction} <- begin_login_in_tx(ref, :pod, %{}, mode: :add),
         {:ok, principals} <- site_principals(transaction, proof.provider_id, proof) do
      persist_login(
        browser,
        transaction,
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

  defp persist_authentication(nil, subject, proof),
    do: Ankole.Ash.create(Authentication, :create_in_tx, Map.merge(Map.new(subject), proof))

  defp persist_authentication(authentication, _subject, proof),
    do: Ankole.Ash.update(authentication, :renew_in_tx, proof)

  defp unchanged_target(_transaction, nil), do: :ok

  defp unchanged_target(transaction, authentication) do
    if authentication.revision <= transaction.started_revision,
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
         %{purpose: :pod, request: %{"reauthentication_principal_uid" => uid}} = transaction,
         _provider_id,
         _subject_id,
         principals
       ) do
    with %Authentication{revoked_at: nil, revision: revision} <-
           Identity.read_authentication(transaction.expected_authentication_id),
         true <- revision <= transaction.started_revision,
         true <-
           Enum.any?(principals, &(&1.uid == uid and &1.tenant_id == transaction.tenant_id)),
         do: :ok,
         else: (_ -> {:error, :login_subject_mismatch})
  end

  defp expected_subject(%{expected_authentication_id: nil}, _, _, _), do: :ok

  defp expected_subject(transaction, provider_id, subject_id, _principals) do
    case Identity.read_authentication(transaction.expected_authentication_id) do
      %Authentication{
        provider_id: ^provider_id,
        subject_id: ^subject_id,
        revoked_at: nil,
        revision: revision
      }
      when revision <= transaction.started_revision ->
        :ok

      _ ->
        {:error, :login_subject_mismatch}
    end
  end

  defp replace_context(_browser, %{mode: :add}, _old, _subject_id), do: :ok

  defp replace_context(browser, transaction, old, subject_id) do
    replaced =
      browser.id
      |> Revocation.live_authentications()
      |> Enum.filter(fn authentication ->
        authentication.id != (old && old.id) and
          (authentication.purpose == transaction.purpose or
             (transaction.purpose in [:console, :oauth] and
                authentication.purpose in [:console, :oauth] and
                authentication.subject_id != subject_id))
      end)

    with :ok <- Revocation.revoke_records(replaced, browser.revision + 1) do
      purposes =
        if transaction.purpose in [:console, :oauth],
          do: [:console, :oauth],
          else: [transaction.purpose]

      LoginTransaction
      |> Ash.Query.filter(
        browser_id == ^browser.id and id != ^transaction.id and purpose in ^purposes and
          status in [:pending, :authenticated]
      )
      |> Revocation.cancel_logins()
    end
  end

  defp select_request(
         %LoginTransaction{purpose: :pod, request: %{"reauthentication_principal_uid" => _}},
         _auth
       ),
       do: {:error, :reauthentication_required}

  defp select_request(%LoginTransaction{purpose: :pod} = transaction, auth),
    do:
      {:ok, transaction.request,
       if(Ankole.OIDC.LoginPolicy.can_reuse?(auth, transaction.request),
         do: :reuse,
         else: :reauthenticate
       )}

  defp select_request(transaction, auth),
    do: Ankole.OIDC.LoginPolicy.select_authentication(transaction, auth)

  defp fetch_login(browser, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %LoginTransaction{} = transaction <-
           LoginTransaction |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         true <-
           transaction.browser_id == browser.id and
             transaction.started_revision >= browser.logout_revision and
             transaction.status in [:pending, :authenticated] and
             DateTime.compare(transaction.expires_at, DateTime.utc_now()) == :gt do
      {:ok, transaction}
    else
      _ -> {:error, :login_expired}
    end
  end

  defp update_login_in_tx(operation, ref, id, change) do
    Identity.in_transaction!(operation)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         {:ok, transaction} <- fetch_login(browser, id),
         do: change.(transaction)
  end

  defp can_complete(transaction, principal, auth) do
    cond do
      transaction.provider_id != auth["provider_id"] ->
        {:error, :login_provider_mismatch}

      not Ankole.Tenants.accepting_work?(principal.tenant_id) ->
        {:error, :tenant_suspended}

      not fresh_for_human?(transaction, principal) ->
        {:error, :human_access_revoked}

      not Ankole.Principals.PodLoginPolicy.authentication_allowed?(
        principal,
        auth["provider_id"],
        auth
      ) ->
        {:error, :login_policy_rejected}

      transaction.purpose == :console and not Ankole.AuthZ.site_admin?(principal.uid) ->
        {:error, :not_an_admin}

      true ->
        :ok
    end
  end

  defp fresh_for_human?(transaction, principal),
    do: fresh_for_human_at?(transaction.inserted_at, principal)

  defp fresh_for_human_at?(started_at, principal),
    do:
      is_nil(principal.access_revoked_at) or
        DateTime.compare(started_at, principal.access_revoked_at) == :gt
end
