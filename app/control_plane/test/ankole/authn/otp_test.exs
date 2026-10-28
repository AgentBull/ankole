defmodule Ankole.Authn.OtpTest do
  use Ankole.DataCase, async: false
  alias Ankole.{AppConfigure, BrowserSessions}
  alias Ankole.Authn.{Challenge, Domain, RateLimiter}
  require Ash.Query

  defmodule FailedSender do
    @behaviour Ankole.Authn.Sender
    def send(:email, _target, _secret, _opts), do: {:error, :mail_unavailable}
  end

  setup do
    previous = Application.get_env(:ankole, Ankole.Authn.Mailer)
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Test)

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
    %{browser: BrowserSessions.reference(browser)}
  end

  test "verified email creates a site proof without inventing a member or Pod", %{
    browser: browser
  } do
    assert {:ok, sent} = Domain.request_otp(browser, " Alice@Example.com ", "test-ip")

    assert_receive {:email,
                    %Swoosh.Email{
                      to: [{_, "alice@example.com"}],
                      text_body: body,
                      html_body: html
                    }}

    assert html =~ "<!doctype html>"
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:ok, %{authentication: auth}} =
             Domain.verify_otp(browser, sent.challenge_id, code, "test-ip")

    assert auth.purpose == :site
    assert auth.subject_id == "alice@example.com"
    assert auth.amr == ["otp"]
    assert [] == Ankole.Principals.list_site_credentials("email_otp", "alice@example.com")
    challenge = Challenge |> Ash.Query.filter(id == ^sent.challenge_id) |> Ankole.Ash.read_one!()
    assert challenge.verified_at
    assert is_nil(challenge.secret_digest)
    assert is_nil(challenge.expires_at)
    assert auth.challenge_started_at == challenge.challenge_started_at
    refute Map.has_key?(challenge.ceremony_context, "started_revision")

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, sent.challenge_id, code, "test-ip")
  end

  test "target Pod admission locks bound and pending members together in UID order", %{
    browser: browser,
    tenant: first
  } do
    second = Ankole.DataCase.create_tenant()
    email = "ordered-members@example.com"

    members =
      for tenant <- [first, second] do
        Ankole.Repo.with_tenant(tenant.id, fn ->
          {:ok, %{principal: principal}} =
            Ankole.Principals.create_human(%{email: email, display_name: tenant.slug})

          {tenant, principal}
        end)
      end

    [{target, pending}, {bound_tenant, bound}] =
      Enum.sort_by(members, fn {_, member} -> member.uid end)

    proof = %{provider_id: "email_otp", subject_id: email, verified_email: email}

    Ankole.Repo.with_tenant(bound_tenant.id, fn ->
      {:ok, _} =
        Ankole.Repo.transact(fn ->
          Ankole.Principals.bind_site_credential_in_tx(bound.uid, proof)
        end)
    end)

    assert {:ok, sent} =
             Domain.request_otp(browser, email, "ordered-source",
               purpose: :site,
               target_tenant_id: target.id
             )

    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    assert {:ok, completed} =
             Domain.verify_otp(browser, sent.challenge_id, code, "ordered-source")

    reference = BrowserSessions.reference(completed.authentication)
    assert completed.browser.active_tenant_id == target.id
    assert BrowserSessions.identity(reference, target.id)["principal_uid"] == pending.uid
    assert BrowserSessions.identity(reference, bound_tenant.id)["principal_uid"] == bound.uid
  end

  test "site login retains its proof when the target Pod has no member", %{
    browser: browser,
    tenant: tenant
  } do
    assert {:ok, sent} =
             Domain.request_otp(browser, "new-site-user@example.com", "new-site-source",
               purpose: :site,
               target_tenant_id: tenant.id
             )

    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/code is (\d{6})/, body)

    assert {:ok, completed} =
             Domain.verify_otp(browser, sent.challenge_id, code, "new-site-source")

    assert completed.authentication.purpose == :site
    assert completed.browser.active_tenant_id == nil
    assert BrowserSessions.identities(BrowserSessions.reference(completed.authentication)) == []
  end

  test "a challenge remains exhausted when the in-memory limiter restarts", %{
    browser: browser
  } do
    assert {:ok, sent} = Domain.request_otp(browser, "attempts@example.com", "test-ip")
    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)
    wrong = if code == "000000", do: "111111", else: "000000"

    for _ <- 1..5 do
      assert {:error, :invalid_code} =
               Domain.verify_otp(browser, sent.challenge_id, wrong, "test-ip")
    end

    RateLimiter.reset_for_test()

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, sent.challenge_id, code, "test-ip")

    challenge = Challenge |> Ash.Query.filter(id == ^sent.challenge_id) |> Ankole.Ash.read_one!()
    assert challenge.attempt_count == challenge.max_attempts
    assert is_nil(challenge.secret_digest)
    assert is_nil(challenge.expires_at)
  end

  test "resending to the same normalized email invalidates the previous code", %{browser: browser} do
    assert {:ok, first} = Domain.request_otp(browser, "resend@example.com", "test-ip")
    assert_receive {:email, %{text_body: first_body}}
    [_, first_code] = Regex.run(~r/verification code is (\d{6})/, first_body)

    Ankole.Repo.query!(
      "UPDATE authn_challenges SET challenge_started_at = challenge_started_at - interval '61 seconds' WHERE id = $1::text::uuid",
      [first.challenge_id]
    )

    assert {:ok, second} = Domain.request_otp(browser, " RESEND@Example.com ", "test-ip")
    assert_receive {:email, %{text_body: second_body}}
    [_, second_code] = Regex.run(~r/verification code is (\d{6})/, second_body)

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, first.challenge_id, first_code, "test-ip")

    assert {:ok, _} =
             Domain.verify_otp(browser, second.challenge_id, second_code, "test-ip")
  end

  test "codes for different email accounts remain independently usable", %{browser: browser} do
    assert {:ok, first} = Domain.request_otp(browser, "account-a@example.com", "test-ip")
    assert_receive {:email, %{text_body: first_body}}
    [_, first_code] = Regex.run(~r/verification code is (\d{6})/, first_body)

    assert {:ok, second} = Domain.request_otp(browser, "account-b@example.com", "test-ip")
    assert_receive {:email, %{text_body: second_body}}
    [_, second_code] = Regex.run(~r/verification code is (\d{6})/, second_body)

    assert {:ok, %{authentication: first_auth}} =
             Domain.verify_otp(browser, first.challenge_id, first_code, "test-ip")

    assert {:ok, %{authentication: second_auth}} =
             Domain.verify_otp(browser, second.challenge_id, second_code, "test-ip")

    assert first_auth.subject_id == "account-a@example.com"
    assert second_auth.subject_id == "account-b@example.com"
  end

  test "an unused ordinary code can establish a new authentication after the same account logs out",
       %{browser: browser} do
    assert {:ok, first} = Domain.request_otp(browser, "returning@example.com", "test-ip")
    assert_receive {:email, %{text_body: first_body}}
    [_, first_code] = Regex.run(~r/verification code is (\d{6})/, first_body)

    assert {:ok, %{authentication: previous}} =
             Domain.verify_otp(browser, first.challenge_id, first_code, "test-ip")

    Ankole.Repo.query!(
      "UPDATE authn_challenges SET challenge_started_at = challenge_started_at - interval '61 seconds' WHERE id = $1::text::uuid",
      [first.challenge_id]
    )

    assert {:ok, second} = Domain.request_otp(browser, "returning@example.com", "test-ip")
    assert_receive {:email, %{text_body: second_body}}
    [_, second_code] = Regex.run(~r/verification code is (\d{6})/, second_body)

    challenge = Repo.get!(Challenge, second.challenge_id)

    Repo.update!(
      Ecto.Changeset.change(challenge,
        ceremony_context:
          Map.put(challenge.ceremony_context, "started_revision", previous.revision)
      )
    )

    previous_ref = BrowserSessions.reference(previous)
    assert {:ok, _} = BrowserSessions.logout(browser)
    assert {:error, _} = BrowserSessions.get_authentication(previous_ref)

    assert {:ok, %{authentication: current}} =
             Domain.verify_otp(browser, second.challenge_id, second_code, "test-ip")

    assert current.subject_id == previous.subject_id
    assert current.revision > previous.revision
    assert {:error, _} = BrowserSessions.get_authentication(previous_ref)
    assert {:ok, _} = BrowserSessions.get_authentication(BrowserSessions.reference(current))
  end

  test "a failed delivery keeps the current code and does not consume the next send", %{
    browser: browser
  } do
    assert {:ok, first} =
             Domain.request_otp(browser, "failed-resend@example.com", "test-ip")

    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    Ankole.Repo.query!(
      "UPDATE authn_challenges SET challenge_started_at = challenge_started_at - interval '61 seconds' WHERE id = $1::text::uuid",
      [first.challenge_id]
    )

    assert {:error, :mail_unavailable} =
             Domain.request_otp(browser, "failed-resend@example.com", "test-ip",
               sender: FailedSender
             )

    assert {:ok, _} = Domain.verify_otp(browser, first.challenge_id, code, "test-ip")

    assert {:error, :mail_unavailable} =
             Domain.request_otp(browser, "delivery-error@example.com", "test-ip",
               sender: FailedSender
             )

    assert {:ok, _} =
             Domain.request_otp(browser, "delivery-error@example.com", "test-ip")
  end

  test "a fabricated browser reference cannot consume the SMTP or recipient quota", %{
    browser: browser
  } do
    for _ <- 1..30 do
      assert {:error, :browser_session_expired} =
               Domain.request_otp(
                 %{"id" => Ash.UUIDv7.generate(), "secret" => "fabricated"},
                 "valid@example.com",
                 "shared-source"
               )
    end

    refute_receive {:email, _}
    assert {:ok, _} = Domain.request_otp(browser, "valid@example.com", "shared-source")
    assert_receive {:email, %Swoosh.Email{}}
  end

  test "Pod OTP silently skips delivery for non-members without consuming SMTP channel quota, while delivering to disabled and SSO-gated members",
       %{browser: browser} do
    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.send_limits", %{
        "window_seconds" => 300,
        "per_email" => 10,
        "per_source" => 10,
        "per_channel" => 2
      })

    {:ok, sent_outsider} =
      Domain.request_otp(browser, "outsider@example.com", "source-outsider-1", purpose: :pod)

    refute_receive {:email, _}

    outsider_challenge =
      Challenge |> Ash.Query.filter(id == ^sent_outsider.challenge_id) |> Ankole.Ash.read_one!()

    assert is_nil(outsider_challenge.secret_digest)
    assert outsider_challenge.expires_at == sent_outsider.expires_at

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, sent_outsider.challenge_id, "000000", "source-outsider-1")

    {:ok, _} =
      Domain.request_otp(browser, "outsider2@example.com", "source-outsider-2", purpose: :pod)

    refute_receive {:email, _}

    # Both silent requests left the global per_channel (limit: 2) quota untouched.
    {:ok, %{principal: disabled_member}} =
      Ankole.Principals.create_human(%{
        email: "disabled-member@example.com",
        display_name: "Disabled"
      })

    {:ok, _} =
      Ankole.Principals.HumanAccess.disable(
        disabled_member.uid,
        "suspended",
        nil,
        "suspend-1",
        :suspended
      )

    {:ok, sent_disabled} =
      Domain.request_otp(browser, "disabled-member@example.com", "source-member-1", purpose: :pod)

    assert_receive {:email,
                    %Swoosh.Email{to: [{_, "disabled-member@example.com"}], text_body: body}}

    [_, disabled_code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:error, :human_access_revoked} =
             Domain.verify_otp(
               browser,
               sent_disabled.challenge_id,
               disabled_code,
               "source-member-1"
             )

    assert {:error, :invalid_code} =
             Domain.verify_otp(
               browser,
               sent_disabled.challenge_id,
               disabled_code,
               "source-member-1"
             )

    consumed =
      Challenge |> Ash.Query.filter(id == ^sent_disabled.challenge_id) |> Ankole.Ash.read_one!()

    assert consumed.verified_at
    assert is_nil(consumed.secret_digest)

    # Existing member under require_sso_for_members still receives email and sees login_policy_rejected on verify.
    {:ok, %{principal: sso_admin}} =
      Ankole.Principals.create_human(%{email: "sso-admin@example.com", display_name: "SSO Admin"})

    {:ok, %{principal: sso_member}} =
      Ankole.Principals.create_human(%{
        email: "sso-member@example.com",
        display_name: "SSO Member"
      })

    {:ok, _} =
      Ankole.IdentityProviders.save_provider(
        "corp-sso",
        "lark",
        %{"appID" => "cli_otp_test", "appSecret" => "secret"},
        true
      )

    {:ok, _} =
      Ankole.PrincipalsFixtures.create_external_identity(%{
        principal_uid: sso_admin.uid,
        provider: "corp-sso",
        external_id: "sso-admin-ext"
      })

    {:ok, settings} = Ankole.Principals.PodAdministration.settings()

    {:ok, _} =
      Ankole.Principals.PodAdministration.update_settings(
        Ankole.AuthZ.Actor.new(sso_admin),
        Map.put(
          settings,
          :loginPolicy,
          Map.put(settings.loginPolicy, "require_sso_for_members", true)
        )
      )

    {:ok, sent_sso} =
      Domain.request_otp(browser, sso_member.uid && "sso-member@example.com", "source-member-2",
        purpose: :pod
      )

    assert_receive {:email,
                    %Swoosh.Email{to: [{_, "sso-member@example.com"}], text_body: sso_body}}

    [_, sso_code] = Regex.run(~r/verification code is (\d{6})/, sso_body)

    assert {:error, :login_policy_rejected} =
             Domain.verify_otp(browser, sent_sso.challenge_id, sso_code, "source-member-2")
  end

  test "Console OTP delivers only to bound or pending siteadmin principals, including disabled siteadmins",
       %{browser: browser, tenant: tenant} do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)

    {:ok, %{principal: ordinary}} =
      Ankole.Principals.create_human(%{
        email: "ordinary@example.com",
        display_name: "Ordinary Member"
      })

    refute Ankole.AuthZ.site_admin_member?(ordinary.uid)

    {:ok, silent} =
      Domain.request_otp(browser, "ordinary@example.com", "console-source", purpose: :console)

    refute_receive {:email, _}

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, silent.challenge_id, "123456", "console-source")

    {:ok, %{principal: admin}} =
      Ankole.Principals.create_human(%{
        email: "root-admin@example.com",
        display_name: "Root Admin"
      })

    {:ok, _} = Ankole.PrincipalsFixtures.first_site_admin_fixture(admin.uid)
    assert Ankole.AuthZ.site_admin_member?(admin.uid)

    {:ok, sent_admin} =
      Domain.request_otp(browser, "root-admin@example.com", "console-source", purpose: :console)

    assert_receive {:email, %Swoosh.Email{to: [{_, "root-admin@example.com"}], text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:ok, %{authentication: %{console_authenticated: true}}} =
             Domain.verify_otp(browser, sent_admin.challenge_id, code, "console-source")

    {:ok, %{principal: disabled_admin}} =
      Ankole.Principals.create_human(%{
        email: "disabled-admin@example.com",
        display_name: "Disabled Admin"
      })

    {:ok, _} = Ankole.AuthZ.add_principal_to_group(disabled_admin.uid, "siteadmin")

    {:ok, _} =
      Ankole.Principals.HumanAccess.disable(
        disabled_admin.uid,
        "suspended",
        nil,
        "suspend-admin",
        :suspended
      )

    refute Ankole.AuthZ.site_admin?(disabled_admin.uid)
    assert Ankole.AuthZ.site_admin_member?(disabled_admin.uid)

    {:ok, sent_disabled_admin} =
      Domain.request_otp(browser, "disabled-admin@example.com", "console-source",
        purpose: :console
      )

    assert_receive {:email,
                    %Swoosh.Email{
                      to: [{_, "disabled-admin@example.com"}],
                      text_body: disabled_body
                    }}

    [_, disabled_code] = Regex.run(~r/verification code is (\d{6})/, disabled_body)

    assert {:error, :human_access_revoked} =
             Domain.verify_otp(
               browser,
               sent_disabled_admin.challenge_id,
               disabled_code,
               "console-source"
             )
  end

  test "the declared site strategy runs without a tenant before Pod selection", %{
    browser: browser
  } do
    assert {:ok, sent} =
             Ankole.Repo.without_tenant(fn ->
               Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :request, %{
                 browser: browser,
                 email: "new@example.com",
                 source: "source"
               })
             end)

    assert_receive {:email, %Swoosh.Email{text_body: body}}
    [_, code] = Regex.run(~r/verification code is (\d{6})/, body)

    assert {:ok, %{authentication: auth}} =
             Ankole.Repo.without_tenant(fn ->
               Ankole.Authn.Info.run(Ankole.Principals.SiteCredential, :email_otp, :verify, %{
                 browser: browser,
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

    refute_receive {:email, _}
  end

  test "negotiate_locale matches weighted Accept-Language ranges and primary language subtags" do
    assert Ankole.I18n.negotiate_locale("zh-CN,zh;q=0.9,en-US;q=0.8") == "zh-Hans-CN"
    assert Ankole.I18n.negotiate_locale("fr-FR;q=0.9, ja;q=0.8, en;q=0.7") == "ja-JP"
    assert Ankole.I18n.negotiate_locale(["ko-KR,ko;q=0.9", "en-US;q=0.5"]) == "ko-KR"
    assert Ankole.I18n.negotiate_locale("en;q=0.4, zh-Hans-CN;q=0.9") == "zh-Hans-CN"
    assert Ankole.I18n.negotiate_locale("de-DE,fr;q=0.8") == nil
    assert Ankole.I18n.negotiate_locale(nil) == nil
  end

  test "verification and invitation emails render localized multipart HTML and plaintext across all catalogs and escape untrusted names" do
    workspace = "R&D <script>alert(1)</script>"
    url = "https://ankole.example.com/join/inv-token-123"

    for {header, expected_locale, expected_code_subject} <- [
          {"en-US", "en-US", "Ankole verification code"},
          {"zh-CN,zh;q=0.9", "zh-Hans-CN", "Ankole 邮箱验证码"},
          {"ja-JP,ja;q=0.9", "ja-JP", "Ankole 確認コード"},
          {"ko-KR,ko;q=0.9", "ko-KR", "Ankole 인증 코드"}
        ] do
      assert :ok =
               Ankole.Authn.Mailer.send_code("member@example.com", "842901", :login,
                 locale: header
               )

      assert_receive {:email,
                      %Swoosh.Email{
                        from: {"Ankole", "login@example.com"},
                        to: [{_, "member@example.com"}],
                        subject: ^expected_code_subject,
                        headers: %{"Auto-Submitted" => "auto-generated"},
                        attachments: [
                          %Swoosh.Attachment{
                            cid: "ankole-logo.png",
                            content_type: "image/png",
                            type: :inline,
                            data: <<0x89, "PNG", _::binary>>
                          }
                        ],
                        html_body: code_html,
                        text_body: code_text
                      }}

      assert code_html =~ "<!doctype html>"
      assert code_html =~ ~s(lang="#{expected_locale}")
      assert code_html =~ ~s(src="cid:ankole-logo.png")
      assert code_html =~ "842901"
      assert code_text =~ "842901"

      assert :ok =
               Ankole.Authn.Mailer.send_invitation("invitee@example.com", url, workspace,
                 locale: header
               )

      assert_receive {:email,
                      %Swoosh.Email{
                        from: {"Ankole", "login@example.com"},
                        to: [{_, "invitee@example.com"}],
                        headers: %{"Auto-Submitted" => "auto-generated"},
                        attachments: [
                          %Swoosh.Attachment{
                            cid: "ankole-logo.png",
                            content_type: "image/png",
                            type: :inline,
                            data: <<0x89, "PNG", _::binary>>
                          }
                        ],
                        html_body: inv_html,
                        text_body: inv_text
                      }}

      assert inv_html =~ "<!doctype html>"
      assert inv_html =~ ~s(lang="#{expected_locale}")
      assert inv_html =~ ~s(src="cid:ankole-logo.png")
      assert inv_html =~ url
      assert inv_html =~ "R&amp;D &lt;script&gt;alert(1)&lt;/script&gt;"
      refute inv_html =~ "<script>alert(1)</script>"
      assert inv_text =~ url
      assert inv_text =~ workspace
    end
  end

  test "Swoosh.Adapters.Local makes email OTP available without SMTP settings and stores messages in memory" do
    Application.put_env(:ankole, Ankole.Authn.Mailer, adapter: Swoosh.Adapters.Local)
    {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", nil)
    Swoosh.Adapters.Local.Storage.Memory.delete_all()
    on_exit(fn -> Swoosh.Adapters.Local.Storage.Memory.delete_all() end)

    assert Ankole.Authn.Mailer.configured?()

    assert :ok =
             Ankole.Authn.Mailer.send_code("local-dev@example.com", "531246", :login,
               locale: "zh-CN"
             )

    assert [%Swoosh.Email{} = stored] = Swoosh.Adapters.Local.Storage.Memory.all()
    assert stored.from == {"Ankole", "noreply@ankole.localhost"}
    assert stored.to == [{"", "local-dev@example.com"}]
    assert stored.subject == "Ankole 邮箱验证码"
    assert stored.html_body =~ "531246"
    assert stored.text_body =~ "531246"
  end
end
