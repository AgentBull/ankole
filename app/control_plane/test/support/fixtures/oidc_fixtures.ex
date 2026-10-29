defmodule Ankole.OIDCFixtures do
  @moduledoc false
  alias Ankole.{AppConfigure, BrowserSessions, OIDC, Principals, Repo}

  def access_token(principal_uid, client_id, scope) do
    with {:ok, session} <- session(principal_uid, client_id, scope),
         do: OIDC.Tokens.mint_access(principal_uid, client_id, scope, session.id)
  end

  def session(principal_uid, client_id, scope, opts \\ []) do
    smtp = Ankole.Authn.SMTPFixture.start(self())
    ExUnit.Callbacks.on_exit(fn -> Ankole.Authn.SMTPFixture.stop(smtp) end)

    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "login@ankole.test",
        "cacertfile" => smtp.ca_path
      })

    # OIDC state tests issue many credentials for one Human. OTP abuse limits
    # have dedicated tests; this factory still sends and verifies each code.
    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.send_limits", %{
        "window_seconds" => 60,
        "per_email" => 10_000,
        "per_source" => 10_000,
        "per_channel" => 10_000
      })

    email = String.downcase(principal_uid) <> "@oidc-fixture.test"

    {:ok, _} =
      Repo.transact(fn ->
        Principals.bind_site_credential_in_tx(principal_uid, %{
          provider_id: "email_otp",
          subject_id: email,
          verified_email: email
        })
      end)

    browser =
      Keyword.get_lazy(opts, :browser, fn ->
        {:ok, browser} = BrowserSessions.create()
        browser
      end)

    ref = BrowserSessions.reference(browser)

    {:ok, request} =
      OIDC.AuthorizationRequests.begin(ref, client_id, %{
        "client_id" => client_id,
        "scope" => scope
      })

    {:ok, sent} =
      Ankole.Authn.Domain.request_otp(ref, email, "oidc-fixture",
        purpose: :oauth,
        mode: :add,
        oauth_request_id: request.id,
        request: request.request,
        return_to: "/oauth/authorize/resume?oauth_request=" <> request.id
      )

    code =
      receive do
        {:smtp_message, _, _, message} ->
          [_, code] = Regex.run(~r/code is (\d{6})/, Ankole.Authn.SMTPFixture.text(message))
          code
      after
        5_000 -> raise "SMTP verification email was not delivered"
      end

    {:ok, %{authentication: authentication}} =
      Ankole.Authn.Domain.verify_otp(ref, sent.challenge_id, code, "oidc-fixture")

    proof = BrowserSessions.authentication(BrowserSessions.reference(authentication), :oauth)
    OIDC.Sessions.ensure(client_id, proof, scope)
  end
end
