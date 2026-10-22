defmodule Ankole.BrowserSessions do
  @moduledoc "Durable browser authentication, identity selection, and one-use login transactions."

  import Ecto.Query
  require Ash.Query
  alias Ankole.BrowserSessions.{Authentication, LoginTransaction, PodAuthentication, Session}
  alias Ankole.Principals.{ExternalIdentity, HumanAccess, Principal}
  alias Ankole.Repo

  @session_ttl 24 * 60 * 60
  @login_ttl 10 * 60
  @purposes [:console, :oauth, :pod, :site]

  def create do
    Repo.transact(fn _repo ->
      Ankole.Ash.create(Session, :create_in_tx, %{
        expires_at: DateTime.add(DateTime.utc_now(), @session_ttl)
      })
    end)
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

  def get(ref), do: fetch_browser(Repo, ref, false)
  def get_authentication(ref), do: fetch_authentication(Repo, ref)

  def current_reference(ref) do
    with {:ok, browser} <- get(ref),
         id when is_binary(id) <- browser.active_authentication_id,
         %Authentication{} = authentication <- Repo.get(Authentication, id),
         {:ok, _} <- get_authentication(reference(authentication)) do
      reference(authentication)
    else
      _ -> nil
    end
  end

  def authentication(ref, :console) do
    case get_authentication(ref) do
      {:ok, %Authentication{purpose: :console, tenant_id: tenant_id} = authentication} ->
        identity_for_authentication(authentication, tenant_id)

      {:ok, %Authentication{purpose: :site, console_authenticated: true} = authentication} ->
        with {:ok, tenant} <- Ankole.Tenants.privileged(),
             do: identity_for_authentication(authentication, tenant.id),
             else: (_ -> nil)

      _ ->
        nil
    end
  end

  def authentication(ref, purpose) when purpose in [:oauth, :pod] do
    with {:ok, authentication} <- get_authentication(ref),
         tenant_id when is_binary(tenant_id) <- Repo.tenant_id() || authentication.tenant_id,
         do: identity_for_authentication(authentication, tenant_id),
         else: (_ -> nil)
  end

  def identity(ref, tenant_id) when is_binary(tenant_id) do
    with {:ok, authentication} <- get_authentication(ref) do
      identity_for_authentication(authentication, tenant_id)
    else
      _ -> nil
    end
  end

  def identity(_, _), do: nil

  defp identity_for_authentication(authentication, tenant_id),
    do: Repo.with_tenant(tenant_id, fn -> identity_in_tenant(authentication) end)

  defp identity_in_tenant(authentication) do
    with %PodAuthentication{} = proof <-
           Repo.get_by(PodAuthentication, authentication_id: authentication.id),
         :ok <- HumanAccess.check(proof.principal_uid, proof.access_version),
         true <- Ankole.Tenants.accepting_work?(proof.tenant_id),
         true <- current_binding?(authentication, proof) do
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
        "expires_at" => DateTime.to_unix(authentication.expires_at),
        "purpose" => Atom.to_string(authentication.purpose)
      }
    else
      _ -> nil
    end
  end

  defp current_binding?(%Authentication{purpose: :site} = authentication, proof) do
    Ankole.IdentityProviders.SiteSources.registered?(authentication.provider_id) and
      Repo.exists?(
        from(e in ExternalIdentity,
          where:
            e.provider == ^authentication.provider_id and
              e.external_id == ^authentication.subject_id and
              e.principal_uid == ^proof.principal_uid
        )
      )
  end

  defp current_binding?(authentication, proof),
    do:
      authentication.tenant_id == proof.tenant_id and
        authentication.subject_id == proof.principal_uid

  def activate(browser_ref, authentication_ref, tenant_id \\ nil) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, browser_ref, true),
           {:ok, authentication} <- fetch_authentication(repo, authentication_ref),
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
    end)
  end

  def begin_login(ref, purpose, request, opts \\ [])
      when purpose in @purposes and is_map(request) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           {:ok, authentication} <- login_authentication(repo, browser, purpose, opts),
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
               csrf_token: csrf_state(),
               expires_at: DateTime.add(DateTime.utc_now(), @login_ttl)
             }) do
        bind_login_proof(transaction, authentication, opts)
      end
    end)
  end

  defp login_authentication(repo, browser, purpose, opts) do
    case Keyword.fetch(opts, :authentication_ref) do
      :error ->
        {:ok, nil}

      {:ok, ref} ->
        with true <- purpose == :pod and Keyword.get(opts, :mode, :replace) == :add,
             {:ok, authentication} <- fetch_authentication(repo, ref),
             true <- authentication.browser_id == browser.id,
             %{} = auth <- identity(ref, Repo.tenant_id!()),
             {:ok, _principal} <- lock_human(repo, auth) do
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

  def login(ref, id) do
    with {:ok, browser} <- get(ref), do: fetch_login(Repo, browser, id)
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
           Repo.get_by(LoginTransaction, upstream_state: state, provider_id: provider_id),
         {:ok, %{status: :pending} = transaction} <- login(ref, transaction.id),
         do: {:ok, transaction},
         else: (_ -> {:error, :login_expired})
  end

  def callback(_, _, _), do: {:error, :login_expired}

  def bind_provider(ref, id, provider_id, state \\ nil, redirect_uri \\ nil) do
    update_login(ref, id, fn
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

  def put_password_ticket(ref, id, ticket) do
    update_login(ref, id, fn
      %LoginTransaction{status: :pending} = transaction ->
        Ankole.Ash.update(transaction, :password_ticket_in_tx, %{password_ticket: ticket})

      _ ->
        {:error, :login_expired}
    end)
  end

  def complete_login(ref, id, auth, before_commit \\ fn -> :ok end) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           {:ok, %LoginTransaction{status: :pending, purpose: purpose} = transaction} <-
             fetch_login(repo, browser, id),
           true <- purpose != :site and transaction.tenant_id == Repo.tenant_id!(),
           false <- Ankole.IdentityProviders.SiteSources.registered?(auth["provider_id"]),
           {:ok, principal} <- lock_human(repo, auth),
           :ok <- can_complete(transaction, principal, auth),
           :ok <- before_commit.() do
        persist_login(
          repo,
          browser,
          transaction,
          auth["provider_id"],
          principal.uid,
          auth["auth_time"],
          auth["external_id"],
          [principal]
        )
      else
        true -> {:error, :invalid_authentication}
        false -> {:error, :invalid_authentication}
        {:ok, _} -> {:error, :login_expired}
        error -> error
      end
    end)
  end

  def complete_site_login(ref, id, provider_id, proof) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           {:ok, %LoginTransaction{status: :pending, purpose: purpose} = transaction} <-
             fetch_login(repo, browser, id),
           true <-
             purpose in [:site, :oauth, :pod, :console] and transaction.provider_id == provider_id,
           {:ok, %{subject_id: subject_id, auth_time: auth_time}} <-
             Ankole.IdentityProviders.SiteSources.authenticate(provider_id, proof) do
        principals = site_principals(repo, transaction, provider_id, subject_id)

        if transaction.purpose != :console or
             Repo.with_tenant(transaction.tenant_id, fn ->
               Enum.any?(
                 principals,
                 &(&1.tenant_id == transaction.tenant_id and Ankole.AuthZ.site_admin?(&1.uid))
               )
             end) do
          persist_login(
            repo,
            browser,
            transaction,
            provider_id,
            subject_id,
            auth_time,
            subject_id,
            principals
          )
        else
          {:error, :not_an_admin}
        end
      else
        false -> {:error, :login_provider_mismatch}
        {:ok, _} -> {:error, :login_expired}
        error -> error
      end
    end)
  end

  @doc "Records initial access in the same transaction that creates a Pod and its Human."
  def create_pod_access(authentication_ref, create) when is_function(create, 1) do
    with_site_authentication(authentication_ref, fn repo, authentication ->
      with {:ok, %{principal: principal} = created} <- create.(authentication),
           true <- is_nil(principal.access_revoked_at),
           {:ok, _} <- record_pod_access(repo, authentication, principal) do
        {:ok, created}
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  @doc "Connects a verified Pod identity without refreshing the parent authentication."
  def connect_pod_access(authentication_ref, verified_ref, tenant_id, connect)
      when is_function(connect, 2) do
    with_site_authentication(authentication_ref, fn repo, authentication ->
      Repo.with_tenant(tenant_id, fn ->
        with {:ok, verified} <- fetch_authentication(repo, verified_ref),
             true <- verified.browser_id == authentication.browser_id,
             %{} = proof <- identity(verified_ref, tenant_id),
             {:ok, principal} <- lock_human(repo, proof),
             {:ok, result} <- connect.(authentication, principal),
             {:ok, _} <- record_pod_access(repo, authentication, principal) do
          {:ok, result}
        else
          false -> {:error, :invalid_authentication}
          nil -> {:error, :invalid_authentication}
          error -> error
        end
      end)
    end)
  end

  defp with_site_authentication(ref, action) do
    Repo.transact(fn repo ->
      with {:ok, authentication} <- fetch_authentication(repo, ref),
           {:ok, _} <- fetch_browser(repo, %{"id" => authentication.browser_id}, true),
           {:ok, %Authentication{purpose: :site} = authentication} <-
             fetch_authentication(repo, ref),
           true <- Ankole.IdentityProviders.SiteSources.registered?(authentication.provider_id) do
        action.(repo, authentication)
      else
        false -> {:error, :invalid_authentication}
        {:ok, _} -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  defp record_pod_access(repo, authentication, principal) do
    Repo.with_tenant(principal.tenant_id, fn ->
      with {:ok, principal} <-
             lock_human(repo, %{
               "principal_uid" => principal.uid,
               "access_version" => principal.access_version
             }),
           true <- Ankole.Tenants.accepting_work?(principal.tenant_id),
           true <- current_binding?(authentication, %{principal_uid: principal.uid}) do
        Ankole.Ash.create(PodAuthentication, :record_in_tx, %{
          authentication_id: authentication.id,
          principal_uid: principal.uid,
          access_version: principal.access_version
        })
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  defp site_principals(repo, transaction, provider_id, subject_id) do
    bindings =
      Repo.across_tenants(fn ->
        repo.all(
          from(e in ExternalIdentity,
            where: e.provider == ^provider_id and e.external_id == ^subject_id,
            order_by: e.principal_uid,
            select: {e.tenant_id, e.principal_uid}
          )
        )
      end)

    Enum.flat_map(bindings, fn {tenant_id, uid} ->
      Repo.with_tenant(tenant_id, fn ->
        case repo.one(from(p in Principal, where: p.uid == ^uid, lock: "FOR SHARE"),
               lock_identity: {"principals", uid}
             ) do
          %Principal{type: :human, status: :active} = principal ->
            if fresh_for_human?(transaction, principal) and
                 Ankole.Tenants.accepting_work?(tenant_id), do: [principal], else: []

          _ ->
            []
        end
      end)
    end)
  end

  defp persist_login(
         repo,
         browser,
         transaction,
         provider_id,
         subject_id,
         auth_time,
         external_id,
         principals
       ) do
    site? = Ankole.IdentityProviders.SiteSources.registered?(provider_id)

    attributes = [
      browser_id: browser.id,
      provider_id: provider_id,
      subject_id: subject_id,
      purpose: if(site?, do: :site, else: transaction.purpose),
      tenant_id: if(site?, do: nil, else: transaction.tenant_id)
    ]

    old = find_subject(repo, attributes)

    with :ok <- unchanged_target(transaction, old),
         :ok <- expected_subject(repo, transaction, provider_id, subject_id),
         :ok <- replace_context(repo, browser, transaction, old, subject_id),
         :ok <- end_authentication(repo, old),
         {:ok, authentication} <-
           persist_authentication(old, attributes, %{
             revision: browser.revision + 1,
             auth_time: auth_time,
             external_id: external_id,
             console_authenticated: transaction.purpose == :console,
             csrf_token: csrf_state(),
             expires_at: DateTime.add(DateTime.utc_now(), @session_ttl)
           }),
         :ok <- save_pod_authentications(repo, authentication, principals),
         {:ok, browser} <-
           Ankole.Ash.update(browser, :record_login_in_tx, %{
             revision: authentication.revision,
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

  defp find_subject(repo, attributes) do
    tenant_id = attributes[:tenant_id]

    query =
      from(a in Authentication,
        where:
          a.browser_id == ^attributes[:browser_id] and a.provider_id == ^attributes[:provider_id] and
            a.subject_id == ^attributes[:subject_id] and a.purpose == ^attributes[:purpose]
      )

    query =
      if is_nil(tenant_id),
        do: where(query, [a], is_nil(a.tenant_id)),
        else: where(query, [a], a.tenant_id == ^tenant_id)

    repo.one(query)
  end

  defp expected_subject(_repo, %{expected_authentication_id: nil}, _, _), do: :ok

  defp expected_subject(repo, transaction, provider_id, subject_id) do
    case repo.get(Authentication, transaction.expected_authentication_id) do
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

  defp replace_context(_repo, _browser, %{mode: :add}, _old, _subject_id), do: :ok

  defp replace_context(repo, browser, transaction, old, subject_id) do
    candidates =
      repo.all(
        from(a in Authentication,
          where: a.browser_id == ^browser.id and is_nil(a.revoked_at)
        )
      )

    replaced =
      Enum.filter(candidates, fn authentication ->
        authentication.id != (old && old.id) and
          (authentication.purpose == transaction.purpose or
             (transaction.purpose in [:console, :oauth] and
                authentication.purpose in [:console, :oauth] and
                authentication.subject_id != subject_id))
      end)

    with :ok <- revoke_records(repo, replaced, browser.revision + 1) do
      purposes =
        if transaction.purpose in [:console, :oauth],
          do: [:console, :oauth],
          else: [transaction.purpose]

      LoginTransaction
      |> Ash.Query.filter(
        browser_id == ^browser.id and id != ^transaction.id and purpose in ^purposes and
          status in [:pending, :authenticated]
      )
      |> cancel_logins()
    end
  end

  defp save_pod_authentications(repo, authentication, principals) do
    tenant_ids =
      Repo.across_tenants(fn ->
        repo.all(
          from(p in PodAuthentication,
            where: p.authentication_id == ^authentication.id,
            distinct: p.tenant_id,
            select: p.tenant_id
          )
        )
      end)

    Enum.each(tenant_ids, fn tenant_id ->
      Repo.with_tenant(tenant_id, fn ->
        PodAuthentication
        |> Ash.Query.filter(authentication_id == ^authentication.id)
        |> destroy_records(:remove_in_tx)
      end)
    end)

    Enum.reduce_while(principals, :ok, fn principal, :ok ->
      result =
        Repo.with_tenant(principal.tenant_id, fn ->
          Ankole.Ash.create(PodAuthentication, :record_in_tx, %{
            authentication_id: authentication.id,
            principal_uid: principal.uid,
            access_version: principal.access_version
          })
        end)

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def select_authorization(ref, id, authentication_ref) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           {:ok, %LoginTransaction{purpose: purpose} = transaction} when purpose in [:oauth, :pod] <-
             fetch_login(repo, browser, id),
           {:ok, authentication} <- fetch_authentication(repo, authentication_ref),
           true <- authentication.browser_id == browser.id,
           %{} = auth <- identity(authentication_ref, transaction.tenant_id),
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
    end)
  end

  defp select_request(%LoginTransaction{purpose: :pod} = transaction, _auth),
    do: {:ok, transaction.request, :reuse}

  defp select_request(transaction, auth),
    do: Ankole.OIDC.LoginPolicy.select_authentication(transaction, auth)

  def consume_authorization(ref, id, authentication_ref, issue) when is_function(issue, 2) do
    with {:ok, transaction} <- login(ref, id) do
      Repo.with_tenant(transaction.tenant_id, fn ->
        Repo.transact(fn repo ->
          with {:ok, browser} <- fetch_browser(repo, ref, true),
               {:ok, %LoginTransaction{purpose: :oauth} = transaction} <-
                 fetch_login(repo, browser, id),
               true <- Ankole.OIDC.LoginPolicy.authorization_ready?(transaction),
               true <-
                 authentication_ref == %{
                   "id" => transaction.authentication_id,
                   "revision" => transaction.authentication_revision
                 },
               %{} = auth <- identity(authentication_ref, transaction.tenant_id),
               {:ok, _} <- lock_human(repo, auth),
               {:ok, _} <-
                 Ankole.Ash.update(transaction, :consume_in_tx, %{}) do
            issue.(transaction.request, auth)
          else
            {:ok, _} -> {:error, :login_expired}
            nil -> {:error, :login_expired}
            false -> {:error, :login_expired}
            error -> error
          end
        end)
      end)
    end
  end

  @doc "Consumes one pending transaction in its fixed tenant, without minting an authentication."
  def consume_login(ref, id, purpose, complete)
      when purpose in @purposes and is_function(complete, 1) do
    with {:ok, transaction} <- login(ref, id) do
      in_context = fn ->
        Repo.transact(fn repo ->
          with {:ok, browser} <- fetch_browser(repo, ref, true),
               {:ok, %LoginTransaction{status: :pending, purpose: ^purpose} = transaction} <-
                 fetch_login(repo, browser, id),
               {:ok, result} <- complete.(transaction),
               {:ok, _} <-
                 Ankole.Ash.update(transaction, :consume_in_tx, %{}) do
            {:ok, result}
          else
            {:ok, _} -> {:error, :login_expired}
            error -> error
          end
        end)
      end

      if transaction.tenant_id,
        do: Repo.with_tenant(transaction.tenant_id, in_context),
        else: Repo.without_tenant(in_context)
    end
  end

  def authorize(authentication_ref, auth, issue) do
    Repo.transact(fn repo ->
      with {:ok, authentication} <- fetch_authentication(repo, authentication_ref),
           {:ok, _browser} <- fetch_browser(repo, %{"id" => authentication.browser_id}, true),
           %{} = current <- identity(authentication_ref, Repo.tenant_id!()),
           true <-
             Map.take(current, ~w(principal_uid access_version provider_id)) ==
               Map.take(auth, ~w(principal_uid access_version provider_id)),
           {:ok, _} <- lock_human(repo, current) do
        issue.(repo)
      else
        false -> {:error, :browser_session_expired}
        nil -> {:error, :browser_session_expired}
        error -> error
      end
    end)
  end

  def revoke(browser_ref, authentication_ref) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, browser_ref, true),
           {:ok, authentication} <- fetch_authentication(repo, authentication_ref),
           true <- authentication.browser_id == browser.id,
           :ok <- revoke_records(repo, [authentication], browser.revision + 1),
           :ok <-
             LoginTransaction
             |> Ash.Query.filter(
               browser_id == ^browser.id and status in [:pending, :authenticated] and
                 (expected_authentication_id == ^authentication.id or
                    authentication_id == ^authentication.id)
             )
             |> cancel_logins() do
        attrs = [revision: browser.revision + 1]

        attrs =
          if browser.active_authentication_id == authentication.id,
            do: attrs ++ [active_authentication_id: nil, active_tenant_id: nil],
            else: attrs

        Ankole.Ash.update(browser, :revoke_in_tx, Map.new(attrs))
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  def logout(ref, expected_revision \\ nil) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           true <- is_nil(expected_revision) or browser.revision == expected_revision,
           authentications <-
             repo.all(
               from(a in Authentication,
                 where: a.browser_id == ^browser.id and is_nil(a.revoked_at)
               )
             ),
           :ok <- revoke_records(repo, authentications, browser.revision + 1),
           :ok <- Ankole.OIDC.Sessions.end_browser_in_tx(repo, browser.id),
           :ok <-
             LoginTransaction
             |> Ash.Query.filter(
               browser_id == ^browser.id and status in [:pending, :authenticated]
             )
             |> cancel_logins() do
        Ankole.Ash.update(browser, :logout_in_tx, %{
          revision: browser.revision + 1,
          logout_revision: browser.revision + 1
        })
      else
        false -> {:error, :logout_request_expired}
        error -> error
      end
    end)
  end

  defp revoke_records(repo, authentications, revision) do
    Enum.reduce_while(authentications, :ok, fn authentication, :ok ->
      with :ok <- end_authentication(repo, authentication),
           {:ok, _} <-
             Ankole.Ash.update(authentication, :revoke_in_tx, %{revision: revision}) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp end_authentication(_repo, nil), do: :ok

  defp end_authentication(repo, authentication),
    do:
      Ankole.OIDC.Sessions.end_authentication_in_tx(
        repo,
        authentication.id,
        authentication.revision
      )

  def cleanup_expired(now) do
    transactions = LoginTransaction |> Ash.Query.filter(expires_at <= ^now) |> expire_records()

    browsers =
      Session
      |> Ash.Query.filter(
        expires_at <= ^now and
          fragment("NOT EXISTS (SELECT 1 FROM oidc_sessions AS s WHERE s.browser_id = ?)", id)
      )
      |> expire_records()

    %{login_transactions: transactions, browser_sessions: browsers}
  end

  defp expire_records(query) do
    case Repo.transact(fn _repo -> {:ok, destroy_records(query, :expire_in_tx)} end) do
      {:ok, count} -> count
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  defp destroy_records(query, action) do
    query = Ash.Query.select(query, Ash.Resource.Info.primary_key(query.resource))

    case Ankole.Ash.bulk_destroy(query, action, %{},
           strategy: [:atomic],
           return_records?: true,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success, records: records} -> length(records)
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end

  defp cancel_logins(query) do
    case Ankole.Ash.bulk_update(query, :cancel_in_tx, %{},
           strategy: [:atomic],
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end

  defp fetch_browser(repo, %{"id" => id}, lock?) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      query = from(b in Session, where: b.id == ^id and b.expires_at > ^DateTime.utc_now())

      case repo.one(if(lock?, do: lock(query, "FOR UPDATE"), else: query)) do
        %Session{} = browser -> {:ok, browser}
        nil -> {:error, :browser_session_expired}
      end
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  defp fetch_browser(_, _, _), do: {:error, :browser_session_expired}

  defp fetch_authentication(repo, %{"id" => id, "revision" => revision})
       when is_integer(revision) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Authentication{revision: ^revision, revoked_at: nil} = authentication <-
           repo.get(Authentication, id),
         true <- DateTime.compare(authentication.expires_at, DateTime.utc_now()) == :gt,
         {:ok, _} <- fetch_browser(repo, %{"id" => authentication.browser_id}, false) do
      {:ok, authentication}
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  defp fetch_authentication(_, _), do: {:error, :browser_session_expired}

  defp fetch_login(repo, browser, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %LoginTransaction{} = transaction <- repo.get(LoginTransaction, id),
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

  defp update_login(ref, id, change) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true),
           {:ok, transaction} <- fetch_login(repo, browser, id),
           do: change.(transaction)
    end)
  end

  defp lock_human(repo, %{"principal_uid" => uid, "access_version" => version}) do
    case repo.one(from(p in Principal, where: p.uid == ^uid, lock: "FOR SHARE"),
           lock_identity: {"principals", uid}
         ) do
      %Principal{type: :human, status: :active, access_version: ^version} = principal ->
        {:ok, principal}

      _ ->
        {:error, :human_access_revoked}
    end
  end

  defp lock_human(_, _), do: {:error, :invalid_authentication}

  defp can_complete(transaction, principal, auth) do
    cond do
      transaction.provider_id != auth["provider_id"] ->
        {:error, :login_provider_mismatch}

      not Ankole.Tenants.accepting_work?(principal.tenant_id) ->
        {:error, :tenant_suspended}

      not fresh_for_human?(transaction, principal) ->
        {:error, :human_access_revoked}

      transaction.purpose == :console and not Ankole.AuthZ.site_admin?(principal.uid) ->
        {:error, :not_an_admin}

      true ->
        :ok
    end
  end

  defp fresh_for_human?(transaction, principal),
    do:
      is_nil(principal.access_revoked_at) or
        DateTime.compare(transaction.inserted_at, principal.access_revoked_at) == :gt

  defp csrf_state, do: Base.url_encode64(:crypto.strong_rand_bytes(18))
end
