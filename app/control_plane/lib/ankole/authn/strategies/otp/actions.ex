defmodule Ankole.Authn.Strategies.Otp.Actions do
  @moduledoc "One-time codes delivered outside the database transaction."
  require Ash.Query
  alias Ankole.Authn.{Challenge, Config, Mailer, RateLimiter, SecretDigest}
  alias Ankole.{BrowserSessions, Repo}

  def request(browser, target, source, opts \\ []) do
    with {:ok, target} <- email(target),
         {:ok, reserved} <-
           Repo.transact_top_level(fn -> reserve(browser, target, source, opts) end),
         :ok <- deliver(target, reserved, opts),
         {:ok, challenge} <- activate(reserved) do
      {:ok, %{challenge_id: challenge.id, expires_at: challenge.expires_at}}
    end
  end

  defp reserve(browser, target, source, opts) do
    with {:ok, session} <- BrowserSessions.lock_browser_in_tx(browser),
         {:ok, context} <- challenge_context(browser, opts),
         :ok <- site_resend_cooldown(context, target),
         deliver? = deliverable?(context, target),
         :ok <- RateLimiter.take(limits("send", target, source, deliver?)) do
      id = Ash.UUIDv7.generate()
      now = DateTime.utc_now()

      if deliver? do
        code = SecretDigest.code()
        digest = SecretDigest.digest(id, code)

        with {:ok, challenge} <-
               Ankole.Ash.create(Challenge, :reserve_in_tx, %{
                 id: id,
                 strategy: "email_otp",
                 purpose: context.purpose,
                 browser_session_id: session.id,
                 tenant_id: context.tenant_id,
                 principal_uid: context.principal_uid,
                 target: target,
                 secret_digest: digest,
                 challenge_started_at: now,
                 ceremony_context: context.ceremony_context
               }) do
          {:ok, %{deliver?: true, challenge: challenge, code: code, digest: digest}}
        end
      else
        {:ok, ttl} = Config.get("code_ttl_seconds")
        expiry = DateTime.add(now, ttl)

        with {:ok, challenge} <-
               Ankole.Ash.create(Challenge, :reserve_in_tx, %{
                 id: id,
                 strategy: "email_otp",
                 purpose: context.purpose,
                 browser_session_id: session.id,
                 tenant_id: context.tenant_id,
                 principal_uid: context.principal_uid,
                 target: target,
                 secret_digest: nil,
                 challenge_started_at: now,
                 expires_at: expiry,
                 ceremony_context: context.ceremony_context
               }),
             {:ok, _} <- invalidate_previous(challenge) do
          {:ok, %{deliver?: false, challenge: challenge}}
        end
      end
    end
  end

  defp deliver(_target, %{deliver?: false}, _opts), do: :ok

  defp deliver(target, reserved, opts) do
    case Keyword.get(opts, :sender, Mailer).send(:email, target, reserved.code, opts) do
      :ok ->
        :ok

      {:error, _} = error ->
        # A delivery failure must not make the recipient wait for a code that was never sent.
        _ = Ankole.Ash.destroy(reserved.challenge, :expire_in_tx)
        error
    end
  end

  defp deliverable?(%{purpose: purpose}, _target)
       when purpose in ["setup", "bind_credential", "step_up"],
       do: true

  defp deliverable?(%{purpose: "login", login_purpose: login_purpose} = context, target) do
    ceremony = context.ceremony_context
    reauth_uid = ceremony["reauthentication_principal_uid"]
    invitation_id = ceremony["invitation_id"]
    target_tenant_id = context.tenant_id || ceremony["target_tenant_id"]

    cond do
      is_binary(reauth_uid) and is_binary(target_tenant_id) ->
        match?(
          %{uid: ^reauth_uid},
          Ankole.Principals.resolve_email_otp_principal(target_tenant_id, target)
        )

      login_purpose == :console ->
        case Ankole.Principals.resolve_email_otp_principal(context.tenant_id, target) do
          %{uid: uid} -> Ankole.AuthZ.site_admin_member?(uid)
          nil -> false
        end

      is_binary(invitation_id) and is_binary(target_tenant_id) ->
        invitation_deliverable?(target_tenant_id, invitation_id, target)

      login_purpose in [:pod, :oauth] ->
        not is_nil(Ankole.Principals.resolve_email_otp_principal(context.tenant_id, target))

      login_purpose == :site ->
        true
    end
  end

  defp invitation_deliverable?(tenant_id, invitation_id, target) do
    Repo.with_tenant(tenant_id, fn ->
      case Ankole.Principals.invitation_for_login(invitation_id) do
        {:ok, %{invited_email: invited}} when is_binary(invited) ->
          invited == target

        {:ok, %{invited_email: nil, membership: membership}} ->
          not is_nil(Ankole.Principals.resolve_email_otp_principal(tenant_id, target)) or
            Ankole.Principals.PodLoginPolicy.authentication_allowed?(
              %{status: :active, membership: membership},
              "email_otp",
              %{verified_email: target}
            )

        _ ->
          false
      end
    end)
  end

  defp site_resend_cooldown(%{purpose: "login", login_purpose: :site}, target) do
    seconds = Application.get_env(:ankole, :site_otp_resend_cooldown_seconds, 0)

    if seconds > 0 do
      Ankole.AdvisoryLock.lock!(Repo, "site-email-otp:" <> target)
      now = DateTime.utc_now()
      cutoff = DateTime.add(now, -seconds)

      latest =
        Challenge
        |> Ash.Query.filter(
          target == ^target and purpose == "login" and is_nil(tenant_id) and
            is_nil(verified_at) and challenge_started_at > ^cutoff
        )
        |> Ash.Query.sort(challenge_started_at: :desc)
        |> Ash.Query.limit(1)
        |> Ankole.Ash.read_one!()

      if latest do
        elapsed = DateTime.diff(now, latest.challenge_started_at, :microsecond)
        {:error, {:rate_limited, max(1, div(seconds * 1_000_000 - elapsed + 999_999, 1_000_000))}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp site_resend_cooldown(_, _), do: :ok

  defp challenge_context(browser, opts) do
    case Keyword.get(opts, :purpose, "login") do
      purpose when purpose in ["setup", "bind_credential", "step_up"] ->
        {:ok,
         %{
           purpose: purpose,
           login_purpose: nil,
           tenant_id: Keyword.get(opts, :tenant_id),
           principal_uid: Keyword.get(opts, :principal_uid),
           ceremony_context: Keyword.get(opts, :ceremony_context, %{})
         }}

      purpose when purpose in [:site, :pod, :console, :oauth] ->
        login_challenge_context(browser, Keyword.put_new(opts, :login_purpose, purpose))

      "login" ->
        login_challenge_context(browser, opts)

      _ ->
        {:error, :login_expired}
    end
  end

  defp login_challenge_context(browser, opts) do
    login_purpose = Keyword.get_lazy(opts, :login_purpose, fn -> default_login_purpose(opts) end)

    with {:ok, tenant_id, defaults} <- authorize_login_purpose(browser, login_purpose, opts) do
      merged = Keyword.merge(defaults, opts)
      mode = Keyword.get(merged, :mode) || default_mode(login_purpose)

      ceremony_context =
        %{
          "login_purpose" => Atom.to_string(login_purpose),
          "mode" => Atom.to_string(mode),
          "started_revision" => Keyword.get(merged, :started_revision),
          "return_to" => Keyword.get(merged, :return_to) || "/",
          "target_tenant_id" => Keyword.get(merged, :target_tenant_id),
          "oauth_request_id" => Keyword.get(merged, :oauth_request_id),
          "invitation_id" => Keyword.get(merged, :invitation_id),
          "expected_authentication_id" => Keyword.get(merged, :expected_authentication_id),
          "reauthentication_principal_uid" => Keyword.get(merged, :reauthentication_principal_uid)
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.merge(Keyword.get(opts, :ceremony_context, %{}))

      {:ok,
       %{
         purpose: "login",
         login_purpose: login_purpose,
         tenant_id: tenant_id,
         principal_uid: Keyword.get(opts, :principal_uid),
         ceremony_context: ceremony_context
       }}
    end
  end

  defp default_login_purpose(opts) do
    cond do
      Keyword.has_key?(opts, :oauth_request_id) and not is_nil(opts[:oauth_request_id]) -> :oauth
      is_binary(Keyword.get(opts, :tenant_id)) -> :pod
      true -> :site
    end
  end

  defp default_mode(:pod), do: :add
  defp default_mode(:site), do: :add
  defp default_mode(_), do: :replace

  defp authorize_login_purpose(_browser, :site, _opts), do: {:ok, nil, []}

  defp authorize_login_purpose(_browser, purpose, opts) when purpose in [:pod, :console] do
    tenant_id = Keyword.get_lazy(opts, :tenant_id, &Repo.tenant_id!/0)

    with :ok <-
           Repo.with_tenant(tenant_id, fn ->
             Ankole.OIDC.LoginPolicy.authorize_login(purpose, "email_otp")
           end),
         do: {:ok, tenant_id, []}
  end

  defp authorize_login_purpose(browser, :oauth, opts) do
    with {:ok, %{status: :pending} = request} <-
           Ankole.OIDC.AuthorizationRequests.get(browser, Keyword.get(opts, :oauth_request_id)),
         :ok <-
           Repo.with_tenant(request.tenant_id, fn ->
             Ankole.OIDC.LoginPolicy.authorize_login(request, "email_otp")
           end) do
      {:ok, request.tenant_id,
       [
         started_revision: request.started_revision,
         expected_authentication_id: request.expected_authentication_id
       ]}
    else
      {:ok, _} -> {:error, :login_expired}
      error -> error
    end
  end

  defp authorize_login_purpose(_browser, _purpose, _opts), do: {:error, :login_expired}

  defp invalidate_previous(challenge) do
    browser_id = challenge.browser_session_id
    purpose = challenge.purpose
    current_id = challenge.id
    tenant_id = challenge.tenant_id
    target = challenge.target

    query =
      Challenge
      |> Ash.Query.filter(
        browser_session_id == ^browser_id and purpose == ^purpose and target == ^target and
          is_nil(verified_at) and id != ^current_id
      )

    query =
      if is_nil(tenant_id),
        do: Ash.Query.filter(query, is_nil(tenant_id)),
        else: Ash.Query.filter(query, tenant_id == ^tenant_id)

    Ankole.Ash.update_where(query, :invalidate_in_tx, %{})
  end

  defp activate(%{deliver?: false, challenge: challenge}), do: {:ok, challenge}

  defp activate(%{challenge: challenge, digest: digest}) do
    {:ok, ttl} = Config.get("code_ttl_seconds")
    expiry = DateTime.add(challenge.challenge_started_at, ttl)

    Repo.transact_top_level(fn ->
      with {:ok, _} <- BrowserSessions.lock_browser_in_tx(%{"id" => challenge.browser_session_id}),
           {:ok, _} <- invalidate_previous(challenge),
           {:ok, activated} <-
             Challenge
             |> Ash.Query.filter(id == ^challenge.id)
             |> Ankole.Ash.update_atomic(:activate_in_tx, %{
               expected_digest: digest,
               expires_at: expiry
             }) do
        {:ok, activated}
      end
    end)
  end

  def verify(browser, id, code, source, opts \\ []) do
    verify_with(
      browser,
      id,
      code,
      source,
      fn challenge -> complete_login_challenge(browser, challenge) end,
      opts
    )
  end

  defp complete_login_challenge(browser, %{purpose: "login"} = challenge) do
    context = challenge.ceremony_context

    with {:ok, login_purpose} <- parse_login_purpose(context["login_purpose"]),
         {:ok, mode} <- parse_mode(context["mode"], login_purpose) do
      started_revision =
        if context["oauth_request_id"] || context["expected_authentication_id"],
          do: context["started_revision"]

      target_tenant_id = context["target_tenant_id"]
      reauth_uid = context["reauthentication_principal_uid"]

      login_opts =
        [
          mode: mode,
          started_revision: started_revision,
          oauth_request_id: context["oauth_request_id"],
          expected_authentication_id: context["expected_authentication_id"],
          reauthentication_principal_uid: reauth_uid,
          target_tenant_id: target_tenant_id
        ]
        |> Keyword.reject(fn {_key, value} -> is_nil(value) end)

      with_challenge_tenant(challenge.tenant_id, fn ->
        with :ok <- accept_invitation(challenge),
             {:ok, completed} <-
               BrowserSessions.authenticate_site_in_tx(
                 browser,
                 login_purpose,
                 "email_otp",
                 %{challenge_id: challenge.id, browser_id: browser["id"]},
                 login_opts
               ) do
          {:ok,
           Map.merge(completed, %{
             purpose: login_purpose,
             tenant_id: completed.browser.active_tenant_id,
             ceremony_context: challenge.ceremony_context
           })}
        end
      end)
    end
  end

  defp complete_login_challenge(_browser, _challenge), do: {:error, :invalid_code}

  defp parse_login_purpose("site"), do: {:ok, :site}
  defp parse_login_purpose("pod"), do: {:ok, :pod}
  defp parse_login_purpose("console"), do: {:ok, :console}
  defp parse_login_purpose("oauth"), do: {:ok, :oauth}
  defp parse_login_purpose(_), do: {:error, :invalid_code}

  defp parse_mode("add", _purpose), do: {:ok, :add}
  defp parse_mode("replace", _purpose), do: {:ok, :replace}
  defp parse_mode(nil, purpose), do: {:ok, default_mode(purpose)}
  defp parse_mode(_, _), do: {:error, :invalid_code}

  defp with_challenge_tenant(nil, fun), do: Repo.without_tenant(fun)
  defp with_challenge_tenant(tenant_id, fun), do: Repo.with_tenant(tenant_id, fun)

  defp accept_invitation(challenge) do
    context = challenge.ceremony_context
    tenant_id = challenge.tenant_id || context["target_tenant_id"]
    invitation_id = context["invitation_id"] || pending_target_invitation(challenge, tenant_id)

    if is_binary(tenant_id) and is_binary(invitation_id) do
      Repo.with_tenant(tenant_id, fn ->
        case Ankole.Principals.accept_site_invitation_in_tx(invitation_id, proof(challenge)) do
          {:ok, _} -> :ok
          error -> error
        end
      end)
    else
      :ok
    end
  end

  defp pending_target_invitation(
         %{ceremony_context: %{"login_purpose" => "site"} = context} = challenge,
         tenant_id
       )
       when is_binary(tenant_id) do
    if is_nil(context["reauthentication_principal_uid"]) and
         is_nil(Ankole.Principals.resolve_email_otp_principal(tenant_id, challenge.target)) do
      case Enum.find(
             Ankole.Principals.pending_invitations(challenge.target),
             &(&1.tenant_id == tenant_id)
           ) do
        nil -> nil
        invitation -> invitation.id
      end
    end
  end

  defp pending_target_invitation(_challenge, _tenant_id), do: nil

  def verify_with(browser, id, code, source, complete, opts \\ []) do
    host_tenant_id = Keyword.get(opts, :host_tenant_id)

    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, _} <- BrowserSessions.get(browser) do
      Repo.transact_top_level(fn ->
        with {:ok, _} <- BrowserSessions.lock_browser_in_tx(browser) do
          case lock_challenge(id, browser["id"], host_tenant_id) do
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

  defp lock_challenge(id, browser_id, host_tenant_id) do
    query = Challenge |> Ash.Query.filter(id == ^id and browser_session_id == ^browser_id)

    query =
      if is_binary(host_tenant_id),
        do: Ash.Query.filter(query, tenant_id == ^host_tenant_id),
        else: query

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

  def verified_proof(%{challenge_id: id, browser_id: browser_id}) do
    case Challenge
         |> Ash.Query.filter(
           id == ^id and browser_session_id == ^browser_id and
             strategy == "email_otp" and not is_nil(verified_at)
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

  defp limits(kind, target, source, deliver? \\ true) do
    {:ok, policy} = Config.get(kind <> "_limits")
    seconds = policy["window_seconds"]
    scopes = [{"email", target}, {"source", source}]
    scopes = if kind == "send" and deliver?, do: scopes ++ [{"channel", "smtp"}], else: scopes

    Enum.map(scopes, fn {scope, value} ->
      maximum = policy["per_" <> scope]
      {kind <> ":" <> scope, value, maximum, seconds}
    end)
  end
end
