defmodule Ankole.Authn.Strategies.Otp.Actions do
  @moduledoc "One-time codes delivered outside the database transaction."
  require Ash.Query
  alias Ankole.Authn.{Challenge, Config, Mailer, RateLimiter, SecretDigest}
  alias Ankole.{BrowserSessions, Repo}

  def request(browser, flow, target, source, opts \\ []) do
    with {:ok, target} <- email(target),
         {:ok, reserved} <-
           Repo.transact_top_level(fn -> reserve(browser, flow, target, source, opts) end),
         :ok <- Keyword.get(opts, :sender, Mailer).send(:email, target, reserved.code, opts),
         {:ok, challenge} <- activate(reserved) do
      {:ok, %{challenge_id: challenge.id, expires_at: challenge.expires_at}}
    end
  end

  defp reserve(browser, flow, target, source, opts) do
    with {:ok, session} <- BrowserSessions.lock_browser_in_tx(browser),
         {:ok, transaction} <- login_transaction(browser, flow),
         :ok <- allow_transaction(transaction, opts),
         :ok <- RateLimiter.take(limits("send", target, source)) do
      id = Ash.UUIDv7.generate()
      code = SecretDigest.code()
      digest = SecretDigest.digest(id, code)
      purpose = Keyword.get(opts, :purpose, "login")
      now = DateTime.utc_now()

      with {:ok, _} <- invalidate_previous(session.id, flow, purpose),
           {:ok, challenge} <-
             Ankole.Ash.create(Challenge, :reserve_in_tx, %{
               id: id,
               strategy: "email_otp",
               purpose: purpose,
               login_transaction_id: flow,
               browser_session_id: session.id,
               tenant_id:
                 if(transaction, do: transaction.tenant_id, else: Keyword.get(opts, :tenant_id)),
               principal_uid: Keyword.get(opts, :principal_uid),
               target: target,
               secret_digest: digest,
               challenge_started_at: now,
               ceremony_context: Keyword.get(opts, :ceremony_context, %{})
             }) do
        {:ok, %{challenge: challenge, code: code, digest: digest}}
      end
    end
  end

  defp login_transaction(_browser, nil), do: {:ok, nil}

  defp login_transaction(browser, flow) do
    with {:ok, transaction} <- BrowserSessions.login(browser, flow),
         {:ok, _} <- BrowserSessions.bind_provider_in_tx(browser, flow, "email_otp"),
         do: {:ok, transaction}
  end

  defp allow_transaction(transaction, opts) do
    cond do
      Keyword.get(opts, :purpose) == "setup" ->
        :ok

      is_nil(transaction) ->
        if Keyword.get(opts, :purpose) in ["bind_credential", "step_up"],
          do: :ok,
          else: {:error, :login_expired}

      transaction.purpose == :site ->
        :ok

      true ->
        Repo.with_tenant(transaction.tenant_id, fn ->
          Ankole.OIDC.LoginPolicy.authorize_login(transaction, "email_otp")
        end)
    end
  end

  defp invalidate_previous(browser_id, flow, purpose) do
    query =
      Challenge
      |> Ash.Query.filter(
        browser_session_id == ^browser_id and purpose == ^purpose and is_nil(verified_at)
      )

    query = if flow, do: Ash.Query.filter(query, login_transaction_id == ^flow), else: query
    Ankole.Ash.update_where(query, :invalidate_in_tx, %{})
  end

  defp activate(%{challenge: challenge, digest: digest}) do
    {:ok, ttl} = Config.get("code_ttl_seconds")
    expiry = DateTime.add(challenge.challenge_started_at, ttl)

    Challenge
    |> Ash.Query.filter(id == ^challenge.id)
    |> Ankole.Ash.update_atomic(:activate_in_tx, %{expected_digest: digest, expires_at: expiry})
  end

  def verify(browser, flow, id, code, source) do
    verify_with(browser, flow, id, code, source, fn challenge ->
      with {:ok, transaction} <- BrowserSessions.login(browser, flow),
           :ok <- accept_invitation(transaction, challenge) do
        BrowserSessions.complete_site_login_in_tx(browser, flow, "email_otp", %{
          challenge_id: challenge.id,
          browser_id: browser["id"],
          flow: flow
        })
      end
    end)
  end

  defp accept_invitation(%{request: %{"invitation_id" => id}} = transaction, challenge) do
    Repo.with_tenant(transaction.tenant_id, fn ->
      case Ankole.Principals.accept_site_invitation_in_tx(id, proof(challenge)) do
        {:ok, _} -> :ok
        error -> error
      end
    end)
  end

  defp accept_invitation(_transaction, _challenge), do: :ok

  def verify_with(browser, flow, id, code, source, complete) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, _} <- BrowserSessions.get(browser) do
      Repo.transact_top_level(fn ->
        with {:ok, _} <- BrowserSessions.lock_browser_in_tx(browser) do
          case lock_challenge(id, browser["id"], flow) do
            nil -> {:ok, {:error, :invalid_code}}
            challenge -> verify_locked(challenge, code, source)
          end
        end
      end)
      |> case do
        {:ok, {:ok, verified}} ->
          Repo.transact_top_level(fn ->
            with {:ok, _} <- BrowserSessions.lock_browser_in_tx(browser),
                 do: complete.(verified)
          end)

        {:ok, result} ->
          result

        error ->
          Ankole.Errors.reason(error)
      end
    else
      _ -> {:error, :invalid_code}
    end
  end

  defp lock_challenge(id, browser_id, flow) do
    query = Challenge |> Ash.Query.filter(id == ^id and browser_session_id == ^browser_id)

    query =
      if flow,
        do: Ash.Query.filter(query, login_transaction_id == ^flow),
        else: Ash.Query.filter(query, is_nil(login_transaction_id))

    query |> Ash.Query.lock(:for_update) |> Ankole.Ash.read_one!()
  end

  defp verify_locked(challenge, code, source) do
    windows = limits("failure", challenge.target, source)
    now = DateTime.utc_now()

    with :ok <- RateLimiter.check(windows) do
      cond do
        not live?(challenge, now) ->
          {:ok, {:error, :invalid_code}}

        SecretDigest.matches?(challenge.secret_digest, challenge.id, code) ->
          with {:ok, verified} <-
                 Ankole.Ash.update(challenge, :attempt_in_tx, %{
                   verified_at: now,
                   secret_digest: nil,
                   expires_at: nil
                 }),
               do: {:ok, {:ok, verified}}

        true ->
          attempts = challenge.attempt_count + 1
          attrs = %{attempt_count: attempts}

          attrs =
            if attempts >= challenge.max_attempts,
              do: Map.merge(attrs, %{secret_digest: nil, expires_at: nil}),
              else: attrs

          with {:ok, _} <- Ankole.Ash.update(challenge, :attempt_in_tx, attrs) do
            RateLimiter.take(windows)
            {:ok, {:error, :invalid_code}}
          end
      end
    else
      error -> {:ok, error}
    end
  end

  defp live?(challenge, now) do
    is_nil(challenge.verified_at) and challenge.attempt_count < challenge.max_attempts and
      not is_nil(challenge.expires_at) and DateTime.compare(challenge.expires_at, now) == :gt
  end

  def verified_proof(%{challenge_id: id, browser_id: browser_id, flow: flow}) do
    case Challenge
         |> Ash.Query.filter(
           id == ^id and browser_session_id == ^browser_id and
             login_transaction_id == ^flow and strategy == "email_otp" and not is_nil(verified_at)
         )
         |> Ankole.Ash.read_one!() do
      %Challenge{} = challenge -> {:ok, proof(challenge)}
      nil -> {:error, :invalid_authentication}
    end
  end

  def verified_proof(_), do: {:error, :invalid_authentication}

  def proof(challenge) do
    %{
      provider_id: "email_otp",
      subject_id: challenge.target,
      verified_email: challenge.target,
      challenge_started_at: challenge.challenge_started_at,
      auth_time: DateTime.to_unix(challenge.verified_at),
      amr: ["otp"],
      kind: :otp
    }
  end

  defp email(value) do
    value = Ankole.Principals.normalize_email(value)

    if is_binary(value) and byte_size(value) <= 254 and
         Regex.match?(Ankole.Principals.HumanUser.email_format(), value),
       do: {:ok, value},
       else: {:error, :invalid_email}
  end

  defp limits(kind, target, source) do
    {:ok, seconds} = Config.get(kind <> "_window_seconds")
    scopes = [{"email", target}, {"source", source}]
    scopes = if kind == "send", do: scopes ++ [{"channel", "smtp"}], else: scopes

    Enum.map(scopes, fn {scope, value} ->
      {:ok, maximum} = Config.get(kind <> "_" <> scope <> "_limit")
      {kind <> ":" <> scope, value, maximum, seconds}
    end)
  end
end
