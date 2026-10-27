defmodule Ankole.Authn.OtpConcurrencyTest do
  use Ankole.DataCase, async: false
  alias Ankole.{AppConfigure, BrowserSessions}
  alias Ankole.Authn.{Challenge, Domain, RateLimiter, SMTPFixture}
  alias Ecto.Adapters.SQL.Sandbox

  @moduletag sandbox: false

  test "concurrent guesses exhaust one durable challenge after real SMTP delivery", %{
    tenant: tenant
  } do
    {:ok, previous_mail} = Ankole.Authn.Config.get("mail")
    smtp = SMTPFixture.start(self())

    {:ok, _} =
      AppConfigure.put_global_by_key("authn.email.mail", %{
        "server" => "127.0.0.1",
        "port" => smtp.port,
        "ssl" => true,
        "from" => "login@ankole.test",
        "cacertfile" => smtp.ca_path
      })

    RateLimiter.reset_for_test()
    {:ok, session} = BrowserSessions.create()
    browser = BrowserSessions.reference(session)

    on_exit(fn ->
      SMTPFixture.stop(smtp)

      Sandbox.unboxed_run(Repo, fn ->
        {:ok, _} = AppConfigure.put_global_by_key("authn.email.mail", previous_mail)
        Repo.delete_all(from s in BrowserSessions.Session, where: s.id == ^session.id)
        cleanup_tenant!(tenant)
      end)
    end)

    source = "concurrent-#{session.id}"
    email = "#{session.id}@example.test"
    assert {:ok, sent} = Domain.request_otp(browser, email, source, login_purpose: :site)
    assert_receive {:smtp_message, _, [^email], message}, 5_000
    [_, code] = Regex.run(~r/code is (\d{6})/, SMTPFixture.text(message))
    wrong = if code == "000000", do: "111111", else: "000000"
    parent = self()

    tasks =
      for _ <- 1..8 do
        Task.async(fn ->
          send(parent, {:ready, self()})
          receive do: (:guess -> :ok)

          Sandbox.unboxed_run(Repo, fn ->
            Repo.without_tenant(fn ->
              Domain.verify_otp(browser, sent.challenge_id, wrong, source)
            end)
          end)
        end)
      end

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    for task <- tasks, do: send(task.pid, :guess)
    for task <- tasks, do: assert(Task.await(task, 15_000) == {:error, :invalid_code})
    challenge = Repo.get!(Challenge, sent.challenge_id)
    assert challenge.attempt_count == 5
    assert challenge.max_attempts == 5
    assert challenge.secret_digest == nil
    assert challenge.expires_at == nil
    RateLimiter.reset_for_test()

    assert {:error, :invalid_code} =
             Domain.verify_otp(browser, sent.challenge_id, code, source)

    assert Repo.aggregate(BrowserSessions.Authentication, :count, :id) == 0
  end
end
