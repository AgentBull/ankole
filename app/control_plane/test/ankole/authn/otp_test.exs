defmodule Ankole.Authn.OtpTest do
  use Ankole.DataCase, async: false
  alias Ankole.{AppConfigure, BrowserSessions}
  alias Ankole.Authn.{Challenge, Domain, RateLimiter}
  require Ash.Query

  setup do
    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: :test)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ankole, Ankole.Authn.Mailer, previous),
        else: Application.delete_env(:ankole, Ankole.Authn.Mailer)
    end)

    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "smtp.example.com",
        "from" => "login@example.com"
      })

    RateLimiter.reset_for_test()
    {:ok, browser} = BrowserSessions.create()
    browser = BrowserSessions.reference(browser)
    {:ok, flow} = BrowserSessions.begin_login(browser, :site, %{})
    %{browser: browser, flow: flow}
  end

  test "verified email creates a site proof without inventing a member or Pod", %{
    browser: browser,
    flow: flow
  } do
    assert {:ok, sent} = Domain.request_otp(browser, flow.id, " Alice@Example.com ", "test-ip")
    assert_receive {:delivered_email, %{to: "alice@example.com", text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:ok, %{authentication: auth}} =
             Domain.verify_otp(browser, flow.id, sent.challenge_id, code, "test-ip")

    assert auth.purpose == :site
    assert auth.subject_id == "alice@example.com"
    assert auth.amr == ["otp"]
    assert [] == Ankole.Principals.list_site_credentials("email_otp", "alice@example.com")
    challenge = Challenge |> Ash.Query.filter(id == ^sent.challenge_id) |> Ankole.Ash.read_one!()
    assert challenge.verified_at
    assert is_nil(challenge.secret_digest)
    assert is_nil(challenge.expires_at)
    assert auth.challenge_started_at == challenge.challenge_started_at

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, flow.id, sent.challenge_id, code, "test-ip")
  end

  test "a challenge remains exhausted when the in-memory limiter restarts", %{
    browser: browser,
    flow: flow
  } do
    assert {:ok, sent} = Domain.request_otp(browser, flow.id, "attempts@example.com", "test-ip")
    assert_receive {:delivered_email, %{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)
    wrong = if code == "000000", do: "111111", else: "000000"

    for _ <- 1..5 do
      assert {:error, :invalid_code} =
               Domain.verify_otp(browser, flow.id, sent.challenge_id, wrong, "test-ip")
    end

    RateLimiter.reset_for_test()

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, flow.id, sent.challenge_id, code, "test-ip")

    challenge = Challenge |> Ash.Query.filter(id == ^sent.challenge_id) |> Ankole.Ash.read_one!()
    assert challenge.attempt_count == challenge.max_attempts
    assert is_nil(challenge.secret_digest)
    assert is_nil(challenge.expires_at)
  end

  test "resending invalidates the previous code", %{browser: browser, flow: flow} do
    assert {:ok, first} = Domain.request_otp(browser, flow.id, "resend@example.com", "test-ip")
    assert_receive {:delivered_email, %{text_body: first_body}}
    [_, first_code] = Regex.run(~r/verification code is (\d{6})/, first_body)
    assert {:ok, second} = Domain.request_otp(browser, flow.id, "resend@example.com", "test-ip")
    assert_receive {:delivered_email, %{text_body: second_body}}
    [_, second_code] = Regex.run(~r/verification code is (\d{6})/, second_body)

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, flow.id, first.challenge_id, first_code, "test-ip")

    assert {:ok, _} =
             Domain.verify_otp(browser, flow.id, second.challenge_id, second_code, "test-ip")
  end

  test "a fabricated flow cannot consume the SMTP or recipient quota", %{
    browser: browser,
    flow: flow
  } do
    for _ <- 1..30 do
      assert {:error, :login_expired} =
               Domain.request_otp(
                 browser,
                 Ash.UUIDv7.generate(),
                 "valid@example.com",
                 "shared-source"
               )
    end

    refute_receive {:delivered_email, _}
    assert {:ok, _} = Domain.request_otp(browser, flow.id, "valid@example.com", "shared-source")
    assert_receive {:delivered_email, _}
  end

  test "a correct code is consumed even when the Pod rejects a non-member", %{browser: browser} do
    {:ok, flow} = BrowserSessions.begin_login(browser, :pod, %{})
    {:ok, sent} = Domain.request_otp(browser, flow.id, "outsider@example.com", "source")
    assert_receive {:delivered_email, %{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:error, :not_a_member} =
             Domain.verify_otp(browser, flow.id, sent.challenge_id, code, "source")

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, flow.id, sent.challenge_id, code, "source")

    challenge = Challenge |> Ash.Query.filter(id == ^sent.challenge_id) |> Ankole.Ash.read_one!()
    assert challenge.verified_at
    assert is_nil(challenge.secret_digest)
  end

  test "the declared site strategy runs without a tenant before Pod selection", %{
    browser: browser,
    flow: flow
  } do
    assert {:ok, sent} =
             Ankole.Repo.without_tenant(fn ->
               Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :request, %{
                 browser: browser,
                 flow: flow.id,
                 email: "new@example.com",
                 source: "source"
               })
             end)

    assert_receive {:delivered_email, %{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:ok, %{authentication: auth}} =
             Ankole.Repo.without_tenant(fn ->
               Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :verify, %{
                 browser: browser,
                 flow: flow.id,
                 challenge_id: sent.challenge_id,
                 code: code,
                 source: "source"
               })
             end)

    assert auth.subject_id == "new@example.com"
    assert auth.authenticated_at
  end

  test "mail configuration rejects invalid transport fields before delivery" do
    for settings <- [
          %{},
          %{"server" => "smtp.test", "from" => "login@example.com", "port" => "587"},
          %{"server" => " ", "from" => "login@example.com"},
          %{"server" => "smtp.test", "from" => "bad\r\naddress"}
        ] do
      assert {:error, _} = Ankole.Authn.Config.put_mail(settings)

      assert {:error, :mail_unavailable} =
               Ankole.Authn.Mailer.send_code("to@example.com", "123456", :login, mail: settings)
    end

    refute_receive {:delivered_email, _}
  end
end
