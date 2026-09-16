defmodule Ankole.BrowserSessions do
  @moduledoc """
  Durable browser authentication and one-use login transactions.
  """

  import Ecto.Query
  alias Ankole.BrowserSessions.{LoginTransaction, Session}
  alias Ankole.Principals.{HumanAccess, Principal}
  alias Ankole.Repo

  @session_ttl 24 * 60 * 60
  @login_ttl 10 * 60

  def create do
    %Session{}
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), @session_ttl))
    |> Repo.insert()
  end

  def cleanup_expired(now) do
    {login_transactions, _} =
      Repo.delete_all(from t in LoginTransaction, where: t.expires_at <= ^now)

    {browser_sessions, _} =
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

    %{login_transactions: login_transactions, browser_sessions: browser_sessions}
  end

  def reference(%Session{id: id, generation: generation}),
    do: %{"id" => id, "generation" => generation}

  def get(ref), do: fetch_session(Repo, ref, false)

  def active?(id) do
    Repo.exists?(
      from s in Session,
        where: s.id == ^id and is_nil(s.revoked_at) and s.expires_at > ^DateTime.utc_now()
    )
  end

  def authorize(ref, auth, issue) do
    Repo.transact(fn repo ->
      with {:ok, _} <- lock_human(repo, auth),
           {:ok, browser} <- fetch_session(repo, ref, true),
           true <-
             browser.oauth_auth == Map.drop(auth, ["browser_id", "browser_generation", "sid"]) do
        issue.(repo)
      else
        false -> {:error, :browser_session_expired}
        error -> error
      end
    end)
  end

  def authentication(ref, purpose) when purpose in [:console, :oauth] do
    with {:ok, browser} <- get(ref),
         %{"principal_uid" => uid, "access_version" => version, "expires_at" => expiry} = auth <-
           Map.get(browser, auth_field(purpose)),
         true <- expiry > System.system_time(:second),
         :ok <- HumanAccess.check(uid, version) do
      Map.merge(auth, %{"browser_id" => browser.id, "browser_generation" => browser.generation})
    else
      _ -> nil
    end
  end

  def begin_login(ref, purpose, request) when purpose in [:console, :oauth] and is_map(request) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_session(repo, ref, true) do
        %LoginTransaction{}
        |> Ecto.Changeset.change(
          browser_id: browser.id,
          generation: browser.generation,
          purpose: purpose,
          request: request,
          expires_at: DateTime.add(DateTime.utc_now(), @login_ttl)
        )
        |> repo.insert()
      end
    end)
  end

  def login(ref, id) do
    with {:ok, browser} <- get(ref),
         {:ok, id} <- Ecto.UUID.cast(id),
         %LoginTransaction{} = transaction <- Repo.get(LoginTransaction, id),
         :ok <- valid_transaction(transaction, browser) do
      {:ok, transaction}
    else
      _ -> {:error, :login_expired}
    end
  end

  def callback(ref, provider_id, state) when is_binary(state) and state != "" do
    with %LoginTransaction{} = transaction <-
           Repo.get_by(LoginTransaction, upstream_state: state, provider_id: provider_id),
         {:ok, %{status: :pending} = transaction} <- login(ref, transaction.id) do
      {:ok, transaction}
    else
      _ -> {:error, :login_expired}
    end
  end

  def callback(_ref, _provider_id, _state), do: {:error, :login_expired}

  def bind_provider(ref, id, provider_id, state \\ nil, redirect_uri \\ nil) do
    update_login(ref, id, fn transaction ->
      case transaction do
        %LoginTransaction{status: :pending, provider_id: nil} ->
          {:ok,
           Ecto.Changeset.change(transaction,
             provider_id: provider_id,
             upstream_state: state,
             redirect_uri: redirect_uri
           )}

        %LoginTransaction{status: :pending, provider_id: ^provider_id, upstream_state: nil}
        when is_nil(state) ->
          {:ok, Ecto.Changeset.change(transaction)}

        _ ->
          {:error, :login_provider_already_selected}
      end
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
      with {:ok, principal} <- lock_human(repo, auth),
           {:ok, browser} <- fetch_session(repo, ref, true),
           {:ok, transaction} <- fetch_login(repo, browser, id),
           :ok <- can_complete(transaction, principal, auth),
           :ok <- before_commit.() do
        complete_in_tx(repo, browser, transaction, auth)
      end
    end)
  end

  def reuse_console(ref) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_session(repo, ref, true),
           %{"principal_uid" => uid, "access_version" => version} = auth <- browser.admin_auth,
           true <- Ankole.AdminAuth.active_human_admin?(uid),
           :ok <- HumanAccess.check(uid, version) do
        browser |> Ecto.Changeset.change(oauth_auth: auth) |> repo.update()
      else
        nil -> {:error, :login_required}
        false -> {:error, :login_required}
        error -> error
      end
    end)
  end

  def consume_authorization(ref, id, issue) when is_function(issue, 2) do
    with {:ok, %{authentication: %{} = authentication}} <- login(ref, id) do
      Repo.transact(fn repo ->
        with {:ok, _} <- lock_human(repo, authentication),
             {:ok, browser} <- fetch_session(repo, ref, true),
             {:ok, %LoginTransaction{purpose: :oauth, status: :authenticated} = transaction} <-
               fetch_login(repo, browser, id),
             %{"principal_uid" => uid, "access_version" => version} = auth <-
               transaction.authentication,
             :ok <- HumanAccess.check(uid, version),
             {:ok, _} <- transaction |> Ecto.Changeset.change(status: :consumed) |> repo.update() do
          issue.(
            transaction.request,
            Map.merge(auth, %{
              "browser_id" => browser.id,
              "browser_generation" => browser.generation
            })
          )
        else
          {:ok, %LoginTransaction{}} -> {:error, :login_expired}
          nil -> {:error, :login_expired}
          error -> error
        end
      end)
    else
      _ -> {:error, :login_expired}
    end
  end

  def logout(ref) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_session(repo, ref, true),
           :ok <- Ankole.OIDC.Sessions.end_browser_in_tx(repo, browser.id) do
        cancel_pending(repo, browser.id)

        browser
        |> Ecto.Changeset.change(
          generation: browser.generation + 1,
          revoked_at: DateTime.utc_now(),
          admin_auth: nil,
          oauth_auth: nil
        )
        |> repo.update()
      end
    end)
  end

  defp fetch_session(repo, %{"id" => id, "generation" => generation}, lock?)
       when is_binary(id) and is_integer(generation) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      query = from s in Session, where: s.id == ^id and s.generation == ^generation
      query = if lock?, do: lock(query, "FOR UPDATE"), else: query

      case repo.one(query) do
        %Session{revoked_at: nil, expires_at: expires_at} = browser ->
          if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
            do: {:ok, browser},
            else: {:error, :browser_session_expired}

        _ ->
          {:error, :browser_session_expired}
      end
    else
      _ -> {:error, :browser_session_expired}
    end
  end

  defp fetch_session(_repo, _ref, _lock?), do: {:error, :browser_session_expired}

  defp fetch_login(repo, browser, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %LoginTransaction{} = transaction <- repo.get(LoginTransaction, id),
         :ok <- valid_transaction(transaction, browser) do
      {:ok, transaction}
    else
      _ -> {:error, :login_expired}
    end
  end

  defp valid_transaction(transaction, browser) do
    if transaction.browser_id == browser.id and transaction.generation == browser.generation and
         transaction.status in [:pending, :authenticated] and
         DateTime.compare(transaction.expires_at, DateTime.utc_now()) == :gt,
       do: :ok,
       else: {:error, :login_expired}
  end

  defp update_login(ref, id, change) do
    Repo.transact(fn repo ->
      with {:ok, browser} <- fetch_session(repo, ref, true),
           {:ok, transaction} <- fetch_login(repo, browser, id),
           {:ok, changeset} <- change.(transaction) do
        repo.update(changeset)
      end
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

  defp lock_human(_repo, _auth), do: {:error, :invalid_authentication}

  defp can_complete(%LoginTransaction{status: :pending} = transaction, principal, auth) do
    cond do
      transaction.provider_id != auth["provider_id"] ->
        {:error, :login_provider_mismatch}

      principal.access_revoked_at != nil and
          DateTime.compare(transaction.inserted_at, principal.access_revoked_at) != :gt ->
        {:error, :human_access_revoked}

      transaction.purpose == :console and not Ankole.AdminAuth.active_human_admin?(principal.uid) ->
        {:error, :not_an_admin}

      true ->
        :ok
    end
  end

  defp can_complete(_transaction, _principal, _auth), do: {:error, :login_expired}

  defp complete_in_tx(repo, browser, transaction, auth) do
    now = System.system_time(:second)

    auth =
      Map.take(auth, [
        "principal_uid",
        "access_version",
        "provider_id",
        "external_id",
        "auth_time"
      ])
      |> Map.merge(%{"issued_at" => now, "expires_at" => now + @session_ttl})

    other_field = auth_field(if(transaction.purpose == :console, do: :oauth, else: :console))
    other = Map.get(browser, other_field)
    other = if is_map(other) and other["principal_uid"] == auth["principal_uid"], do: other
    generation = browser.generation + 1

    with :ok <- end_replaced_oauth(repo, browser, transaction, auth),
         {:ok, browser} <-
           browser
           |> Ecto.Changeset.change(%{
             auth_field(transaction.purpose) => auth,
             other_field => other,
             :generation => generation,
             :expires_at => DateTime.add(DateTime.utc_now(), @session_ttl)
           })
           |> repo.update(),
         {:ok, transaction} <-
           transaction
           |> Ecto.Changeset.change(
             generation: generation,
             status: if(transaction.purpose == :oauth, do: :authenticated, else: :consumed),
             authentication: auth,
             password_ticket: nil
           )
           |> repo.update() do
      cancel_pending(repo, browser.id, transaction.id)
      {:ok, %{browser: browser, transaction: transaction}}
    end
  end

  defp cancel_pending(repo, browser_id, except_id \\ nil) do
    query =
      from t in LoginTransaction,
        where: t.browser_id == ^browser_id and t.status in [:pending, :authenticated]

    query = if except_id, do: where(query, [t], t.id != ^except_id), else: query

    repo.update_all(query,
      set: [status: :cancelled, password_ticket: nil, updated_at: DateTime.utc_now()]
    )
  end

  defp end_replaced_oauth(repo, %{oauth_auth: %{} = old} = browser, transaction, auth) do
    if transaction.purpose == :oauth or old["principal_uid"] != auth["principal_uid"],
      do: Ankole.OIDC.Sessions.end_browser_in_tx(repo, browser.id),
      else: :ok
  end

  defp end_replaced_oauth(_repo, _browser, _transaction, _auth), do: :ok

  defp auth_field(:console), do: :admin_auth
  defp auth_field(:oauth), do: :oauth_auth
end
