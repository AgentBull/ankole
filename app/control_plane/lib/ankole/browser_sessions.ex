defmodule Ankole.BrowserSessions do
  @moduledoc "Durable browser authentication, identity selection, and one-use login transactions."

  import Ecto.Query
  alias Ankole.BrowserSessions.{Authentication, LoginTransaction, PodAuthentication, Session}
  alias Ankole.Principals.{ExternalIdentity, HumanAccess, Principal}
  alias Ankole.Repo

  @session_ttl 24 * 60 * 60
  @login_ttl 10 * 60
  @purposes [:console, :oauth, :pod, :site]

  def create do
    %Session{}
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), @session_ttl))
    |> Repo.insert()
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
      {:ok, %Authentication{purpose: :console, tenant_id: tenant_id}} ->
        identity(ref, tenant_id)

      {:ok, %Authentication{purpose: :site}} ->
        with {:ok, tenant} <- Ankole.Tenants.privileged(),
             do: identity(ref, tenant.id),
             else: (_ -> nil)

      _ ->
        nil
    end
  end

  def authentication(ref, purpose) when purpose in [:oauth, :pod] do
    with {:ok, authentication} <- get_authentication(ref),
         tenant_id when is_binary(tenant_id) <- Repo.tenant_id() || authentication.tenant_id,
         do: identity(ref, tenant_id),
         else: (_ -> nil)
  end

  def identity(ref, tenant_id) when is_binary(tenant_id) do
    with {:ok, authentication} <- get_authentication(ref) do
      Repo.with_tenant(tenant_id, fn -> identity_in_tenant(authentication) end)
    else
      _ -> nil
    end
  end

  def identity(_, _), do: nil

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
        from e in ExternalIdentity,
          where:
            e.provider == ^authentication.provider_id and
              e.external_id == ^authentication.subject_id and
              e.principal_uid == ^proof.principal_uid
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
        browser
        |> Ecto.Changeset.change(
          active_authentication_id: authentication.id,
          active_tenant_id: target_tenant
        )
        |> repo.update()
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  def begin_login(ref, purpose, request, opts \\ [])
      when purpose in @purposes and is_map(request) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_browser(repo, ref, true) do
        %LoginTransaction{}
        |> Ecto.Changeset.change(
          browser_id: browser.id,
          tenant_id: if(purpose == :site, do: nil, else: Repo.tenant_id!()),
          started_revision: browser.revision,
          purpose: purpose,
          mode: Keyword.get(opts, :mode, :replace),
          expected_authentication_id: Keyword.get(opts, :expected_authentication_id),
          request: request,
          csrf_token: csrf_state(),
          expires_at: DateTime.add(DateTime.utc_now(), @login_ttl)
        )
        |> repo.insert()
      end
    end)
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
        {:ok,
         Ecto.Changeset.change(transaction,
           provider_id: provider_id,
           upstream_state: state,
           redirect_uri: redirect_uri
         )}

      %LoginTransaction{status: :pending, provider_id: ^provider_id, upstream_state: nil} =
          transaction
      when is_nil(state) ->
        {:ok, Ecto.Changeset.change(transaction)}

      _ ->
        {:error, :login_provider_already_selected}
    end)
  end

  def put_password_ticket(ref, id, ticket) do
    update_login(ref, id, fn
      %LoginTransaction{status: :pending} = transaction ->
        {:ok, Ecto.Changeset.change(transaction, password_ticket: ticket)}

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
        %PodAuthentication{}
        |> Ecto.Changeset.change(
          authentication_id: authentication.id,
          principal_uid: principal.uid,
          access_version: principal.access_version
        )
        |> repo.insert(
          on_conflict: {:replace, [:principal_uid, :access_version, :updated_at]},
          conflict_target: [:tenant_id, :authentication_id]
        )
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
          from e in ExternalIdentity,
            where: e.provider == ^provider_id and e.external_id == ^subject_id,
            order_by: e.principal_uid,
            select: {e.tenant_id, e.principal_uid}
        )
      end)

    Enum.flat_map(bindings, fn {tenant_id, uid} ->
      Repo.with_tenant(tenant_id, fn ->
        case repo.one(from p in Principal, where: p.uid == ^uid, lock: "FOR SHARE") do
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
           (old || struct(Authentication, attributes))
           |> Ecto.Changeset.change(
             revision: browser.revision + 1,
             auth_time: auth_time,
             external_id: external_id,
             csrf_token: csrf_state(),
             revoked_at: nil,
             expires_at: DateTime.add(DateTime.utc_now(), @session_ttl)
           )
           |> repo.insert_or_update(),
         :ok <- save_pod_authentications(repo, authentication, principals),
         {:ok, browser} <-
           browser
           |> Ecto.Changeset.change(
             revision: authentication.revision,
             active_authentication_id: authentication.id,
             active_tenant_id: transaction.tenant_id,
             expires_at:
               if(DateTime.compare(browser.expires_at, authentication.expires_at) == :gt,
                 do: browser.expires_at,
                 else: authentication.expires_at
               )
           )
           |> repo.update(),
         {:ok, transaction} <-
           transaction
           |> Ecto.Changeset.change(
             status: if(transaction.purpose == :oauth, do: :authenticated, else: :consumed),
             authentication_id: authentication.id,
             authentication_revision: authentication.revision,
             password_ticket: nil
           )
           |> repo.update() do
      {:ok, %{browser: browser, transaction: transaction, authentication: authentication}}
    end
  end

  defp unchanged_target(_transaction, nil), do: :ok

  defp unchanged_target(transaction, authentication) do
    if authentication.revision <= transaction.started_revision,
      do: :ok,
      else: {:error, :login_expired}
  end

  defp find_subject(repo, attributes) do
    tenant_id = attributes[:tenant_id]

    query =
      from a in Authentication,
        where:
          a.browser_id == ^attributes[:browser_id] and a.provider_id == ^attributes[:provider_id] and
            a.subject_id == ^attributes[:subject_id] and a.purpose == ^attributes[:purpose]

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
        from a in Authentication,
          where: a.browser_id == ^browser.id and is_nil(a.revoked_at)
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

      repo.update_all(
        from(t in LoginTransaction,
          where:
            t.browser_id == ^browser.id and t.id != ^transaction.id and t.purpose in ^purposes and
              t.status in [:pending, :authenticated]
        ),
        set: [status: :cancelled, password_ticket: nil, updated_at: DateTime.utc_now()]
      )

      :ok
    end
  end

  defp save_pod_authentications(repo, authentication, principals) do
    Repo.across_tenants(fn ->
      repo.delete_all(
        from p in PodAuthentication, where: p.authentication_id == ^authentication.id
      )
    end)

    Enum.reduce_while(principals, :ok, fn principal, :ok ->
      result =
        Repo.with_tenant(principal.tenant_id, fn ->
          %PodAuthentication{}
          |> Ecto.Changeset.change(
            authentication_id: authentication.id,
            principal_uid: principal.uid,
            access_version: principal.access_version
          )
          |> repo.insert()
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
           {:ok, %LoginTransaction{purpose: :oauth} = transaction} <-
             fetch_login(repo, browser, id),
           {:ok, authentication} <- fetch_authentication(repo, authentication_ref),
           true <- authentication.browser_id == browser.id,
           %{} = auth <- identity(authentication_ref, transaction.tenant_id),
           {:ok, request, action} <-
             Repo.with_tenant(transaction.tenant_id, fn ->
               Ankole.OIDC.LoginPolicy.select_authentication(transaction, auth)
             end) do
        attrs =
          if action == :reuse,
            do: [
              status: :authenticated,
              authentication_id: authentication.id,
              authentication_revision: authentication.revision
            ],
            else: [
              status: :pending,
              expected_authentication_id: authentication.id,
              authentication_id: nil,
              authentication_revision: nil
            ]

        with {:ok, _} <-
               browser
               |> Ecto.Changeset.change(
                 active_authentication_id: authentication.id,
                 active_tenant_id: transaction.tenant_id
               )
               |> repo.update(),
             do:
               transaction
               |> Ecto.Changeset.change(
                 [request: request, started_revision: browser.revision] ++ attrs
               )
               |> repo.update()
      else
        false -> {:error, :invalid_authentication}
        nil -> {:error, :invalid_authentication}
        {:ok, _} -> {:error, :login_expired}
        error -> error
      end
    end)
  end

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
                 transaction |> Ecto.Changeset.change(status: :consumed) |> repo.update() do
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
                 transaction
                 |> Ecto.Changeset.change(status: :consumed, password_ticket: nil)
                 |> repo.update() do
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
           :ok <- revoke_records(repo, [authentication], browser.revision + 1) do
        repo.update_all(
          from(t in LoginTransaction,
            where:
              t.browser_id == ^browser.id and t.status in [:pending, :authenticated] and
                (t.expected_authentication_id == ^authentication.id or
                   t.authentication_id == ^authentication.id)
          ),
          set: [status: :cancelled, password_ticket: nil, updated_at: DateTime.utc_now()]
        )

        attrs = [revision: browser.revision + 1]

        attrs =
          if browser.active_authentication_id == authentication.id,
            do: attrs ++ [active_authentication_id: nil, active_tenant_id: nil],
            else: attrs

        browser |> Ecto.Changeset.change(attrs) |> repo.update()
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
               from a in Authentication,
                 where: a.browser_id == ^browser.id and is_nil(a.revoked_at)
             ),
           :ok <- revoke_records(repo, authentications, browser.revision + 1),
           :ok <- Ankole.OIDC.Sessions.end_browser_in_tx(repo, browser.id) do
        repo.update_all(
          from(t in LoginTransaction,
            where: t.browser_id == ^browser.id and t.status in [:pending, :authenticated]
          ),
          set: [status: :cancelled, password_ticket: nil, updated_at: DateTime.utc_now()]
        )

        browser
        |> Ecto.Changeset.change(
          revision: browser.revision + 1,
          logout_revision: browser.revision + 1,
          active_authentication_id: nil,
          active_tenant_id: nil
        )
        |> repo.update()
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
             authentication
             |> Ecto.Changeset.change(revision: revision, revoked_at: DateTime.utc_now())
             |> repo.update() do
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
    Repo.across_tenants(fn ->
      {transactions, _} = Repo.delete_all(from t in LoginTransaction, where: t.expires_at <= ^now)

      {browsers, _} =
        Repo.delete_all(
          from b in Session,
            as: :browser,
            where: b.expires_at <= ^now,
            where:
              not exists(
                from s in Ankole.OIDC.Session,
                  where: s.browser_id == parent_as(:browser).id,
                  select: 1
              )
        )

      %{login_transactions: transactions, browser_sessions: browsers}
    end)
  end

  defp fetch_browser(repo, %{"id" => id}, lock?) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      query = from b in Session, where: b.id == ^id and b.expires_at > ^DateTime.utc_now()

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
           {:ok, changeset} <- change.(transaction),
           do: repo.update(changeset)
    end)
  end

  defp lock_human(repo, %{"principal_uid" => uid, "access_version" => version}) do
    case repo.one(from p in Principal, where: p.uid == ^uid, lock: "FOR SHARE") do
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
