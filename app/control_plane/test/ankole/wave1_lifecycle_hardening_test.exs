defmodule Ankole.Wave1LifecycleHardeningTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.BrowserSessions
  alias Ankole.OIDC
  alias Ankole.Principals
  alias Ankole.Principals.{HumanAccess, ServiceAccounts, WorkAccess, WorkCleanup}
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Sessions.{Admission, Run}
  alias Ankole.Signals

  test "F-06: recycled corporate email after offboarding joins cleanly with an @-free handle" do
    worker_provider_fixture(%{is_default: true})

    assert {:ok, %{principal: predecessor}} =
             Principals.create_human(%{
               display_name: "Alice v1",
               email: "alice@acme.com"
             })

    assert predecessor.uid == "alice@acme.com"

    assert {:ok, _} =
             HumanAccess.disable(
               predecessor.uid,
               "Resigned",
               nil,
               "offboard-alice",
               :offboarded
             )

    assert {:ok, %{principal: successor, human_user: successor_user}} =
             Principals.create_human(%{
               display_name: "Alice v2",
               email: "alice@acme.com"
             })

    assert successor.uid == "alice"
    refute String.contains?(successor.uid, "@")
    assert successor_user.email == "alice@acme.com"

    assert {:ok, %{agent: assistant}} = Principals.ensure_personal_assistant(successor.uid)
    assert assistant.uid == "alice_assistant"

    # Historical departed principal retains its original UID.
    assert {:ok, %{uid: "alice@acme.com", status: :disabled}} =
             Principals.get_principal("alice@acme.com")

    # A second offboarding and third hire increments the @-free local handle.
    assert {:ok, _} =
             HumanAccess.disable(
               successor.uid,
               "Resigned",
               nil,
               "offboard-alice-2",
               :offboarded
             )

    assert {:ok, %{principal: third}} =
             Principals.create_human(%{
               display_name: "Alice v3",
               email: "alice@acme.com"
             })

    assert third.uid == "alice.2"

    # Explicit :uid takes precedence over :email.
    assert {:ok, %{principal: explicit}} =
             Principals.create_human(%{
               uid: "custom.bob",
               display_name: "Bob",
               email: "bob@acme.com"
             })

    assert explicit.uid == "custom.bob"
  end

  test "WorkAccess allows reclassifying a departed member's paused routine/cron to service" do
    %{principal: agent} = agent_fixture()
    %{principal: departed} = human_fixture()
    %{principal: reviewer} = human_fixture()

    original =
      Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid, binding_name: "bot")

    source_id = Ecto.UUID.generate()

    {:ok, source} =
      Repo.transact(fn ->
        Signals.accept_in_tx(%{
          source: "test://wave1-work",
          id: source_id,
          type: "conversation.message.addressed",
          time: DateTime.utc_now(),
          sender: departed.uid,
          target: %{agent_uid: agent.uid, session_id: "work:#{source_id}"},
          data: %{"text" => "Monitor team health"},
          reply_route: %{
            binding_name: original.reply_binding_name,
            conversation_id: original.conversation_id,
            provider_message_id: original.provider_message_id
          }
        })
      end)

    assert {:ok, %{cron_schedule: cron}} =
             Schedule.create_cron_schedule(
               %{
                 "agent_uid" => source.agent_uid,
                 "owner_session_id" => source.session_id,
                 "binding_name" => source.reply_binding_name,
                 "name" => "team-digest",
                 "idempotency_key" => source.id,
                 "payload" => %{"task" => "Daily digest"},
                 "delivery" => %{
                   "targets" => [
                     %{
                       "binding_name" => source.reply_binding_name,
                       "conversation_id" => source.conversation_id
                     }
                   ]
                 },
                 "schedule" => %{
                   "kind" => "every",
                   "every_ms" => 86_400_000,
                   "anchor_at" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
                 }
               },
               created_by: %{"kind" => "turn", "signal_id" => source.id}
             )

    assert {:ok, disabled} = HumanAccess.disable(departed.uid, "Offboarding", nil, "disable")
    assert {:ok, _} = WorkCleanup.cleanup(departed.uid, disabled.access_version)

    assert {:ok, %{authorization_kind: "service", human_uid: nil}} =
             WorkAccess.classify(
               "routine",
               cron.owner_routine_id,
               nil,
               Ankole.ActorRef.from_principal(reviewer),
               "Converted team digest routine to service ownership"
             )

    assert {:ok, %{status: :active}} = Schedule.resume_cron_schedule(cron.id)
  end

  test "S1-05: failed OIDC logout deliveries expire after 14 days and stale browser authentications are pruned" do
    %{principal: human} = human_fixture()
    now = DateTime.utc_now()
    long_ago = DateTime.add(now, -30 * 86_400)

    {:ok, browser} =
      Repo.transact(fn ->
        Ankole.Ash.create(BrowserSessions.Session, :create_in_tx, %{
          expires_at: DateTime.add(now, -2 * 86_400)
        })
      end)

    {:ok, stale_auth} =
      Repo.transact(fn ->
        Ankole.Ash.create(BrowserSessions.Authentication, :create_in_tx, %{
          browser_id: browser.id,
          tenant_id: Repo.tenant_id!(),
          provider_id: "email_otp",
          subject_id: human.uid,
          scope: :tenant,
          revision: 1,
          authenticated_at: long_ago,
          challenge_started_at: long_ago,
          amr: ["otp"],
          csrf_token: "csrf-token",
          expires_at: DateTime.add(now, -20 * 86_400)
        })
      end)

    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "RP With Broken Logout",
        type: "confidential",
        enabled: true,
        redirect_uris: ["https://rp.example.com/callback"],
        backchannel_logout_uri: "https://rp.example.com/logout",
        scopes: ["openid"]
      })

    {:ok, oidc_session} =
      Repo.transact(fn ->
        Ankole.Ash.create(OIDC.Session, :authorize_in_tx, %{
          client_id: client.id,
          principal_uid: human.uid,
          access_version: human.access_version,
          provider_id: "email_otp",
          browser_id: browser.id,
          authentication_id: stale_auth.id,
          authentication_revision: stale_auth.revision,
          auth_time: System.system_time(:second) - 86_400 * 10,
          expires_at: DateTime.add(now, -5 * 86_400)
        })
      end)

    {:ok, ended_session} =
      Repo.transact(fn ->
        Ankole.Ash.update(oidc_session, :end_in_tx, %{at: DateTime.add(now, -5 * 86_400)})
      end)

    {:ok, delivery} =
      Repo.transact(fn ->
        Ankole.Ash.create(OIDC.LogoutDelivery, :enqueue_in_tx, %{
          session_id: ended_session.id,
          endpoint: "https://rp.example.com/logout",
          next_attempt_at: DateTime.add(now, -16 * 86_400),
          deadline: DateTime.add(now, -15 * 86_400)
        })
      end)

    Repo.query!(
      "UPDATE oidc_logout_deliveries SET status = 'failed', last_error = 'HTTP 502' WHERE id = $1",
      [Ecto.UUID.dump!(delivery.id)]
    )

    # Inside 14 days after deadline (evaluated at now - 2 days), the failed session is still retained.
    early =
      Repo.transact(fn ->
        {:ok, OIDC.cleanup_expired_credentials(DateTime.add(now, -2 * 86_400))}
      end)

    assert {:ok, %{oidc_sessions: 0}} = early

    # Past 14 days after deadline, cleanup reclaims the oidc_session, cascades the failed delivery,
    # and allows BrowserSessions.Revocation.cleanup_expired/1 to reclaim both browser_authentications and browser_sessions.
    assert {:ok, %{oidc_sessions: 1}} =
             Repo.transact(fn -> {:ok, OIDC.cleanup_expired_credentials(now)} end)

    assert {:ok, %{browser_authentications: 1, browser_sessions: 1}} =
             Repo.transact(fn -> {:ok, BrowserSessions.Revocation.cleanup_expired(now)} end)
  end

  test "F-12: infrastructure retries do not consume the 5-attempt execution budget up to 12 retries" do
    %{principal: agent} = Ankole.SessionsCase.agent_fixture()
    route = "wave1-infra-#{System.unique_integer([:positive])}"
    {:ok, _} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)
    now = DateTime.utc_now(:microsecond)

    final_signal =
      Enum.reduce(1..7, signal, fn idx, current ->
        t = DateTime.add(now, idx * 600, :second)
        assert {:ok, %Run{} = run} = Admission.admit(current, current, now: t)

        assert {:ok, deferred} =
                 Run.defer_retry(run, %{"error_code" => "socket_closed"}, t)

        deferred
      end)

    assert final_signal.attempt_count == 7
    assert final_signal.infrastructure_attempt_count == 7
    assert final_signal.attempt_count - final_signal.infrastructure_attempt_count == 0
    assert final_signal.status == :queued

    # A subsequent admission still succeeds instead of dead-lettering at 5 execution attempts.
    assert {:ok, %Run{}} =
             Admission.admit(final_signal, final_signal, now: DateTime.add(now, 8 * 600, :second))
  end

  test "F-91 & F-27b: Service Account token quotas bound Brain and Applet LLM spend and expose Console routes",
       %{conn: conn} do
    {:ok, page} =
      Ankole.Pod.Pages.create(
        actor_fixture(human_fixture().principal.uid),
        %{type: "applet", title: "Sales Bot"}
      )

    applet_uid = ServiceAccounts.applet_uid(page.id)

    {:ok, _} =
      Repo.transact(fn ->
        ServiceAccounts.ensure_applet_in_tx(page.id, page.title, page.name)
      end)

    conn = console_conn(conn)

    # Configure ankole_brain quota via /api/v2/system-principals/:uid/token-quota
    put_resp =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put(
        "/api/v2/system-principals/ankole_brain/token-quota",
        Jason.encode!(%{
          data: %{
            period_days: 1,
            period_start_at: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second)),
            limit_tokens: 50
          }
        })
      )
      |> json_response(200)

    assert %{"token_quota" => %{"limit_tokens" => 50}} = put_resp

    {:ok, _} =
      Ankole.Ash.create(UsageRecord, :record_round, %{
        subject_uid: "ankole_brain",
        origin: :brain,
        model: "openai/gpt-5",
        input_tokens: 40,
        output_tokens: 20
      })

    assert {:error, {:service_token_quota_exceeded, %{used_tokens: 60, limit_tokens: 50}}} =
             ResponsesPreparation.ensure_token_quota("ankole_brain",
               caller: "brain.dreaming.patterns"
             )

    # Configure per-Applet Service Account quota
    assert {:ok, _} =
             TokenQuota.put_service(applet_uid, %{
               "period_days" => 1,
               "period_start_at" =>
                 DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second)),
               "limit_tokens" => 30
             })

    {:ok, _} =
      Ankole.Ash.create(UsageRecord, :record_round, %{
        subject_uid: "viewer-user",
        service_uid: applet_uid,
        origin: :applet,
        model: "openai/gpt-5",
        input_tokens: 25,
        output_tokens: 10
      })

    assert {:error, {:service_token_quota_exceeded, %{used_tokens: 35, limit_tokens: 30}}} =
             ResponsesPreparation.ensure_token_quota("viewer-user",
               caller: "pod_applet",
               request_context: %{"service_uid" => applet_uid}
             )

    assert {:ok, _} = TokenQuota.reset_service(applet_uid)

    assert :ok =
             ResponsesPreparation.ensure_token_quota("viewer-user",
               caller: "pod_applet",
               request_context: %{"service_uid" => applet_uid}
             )
  end
end
