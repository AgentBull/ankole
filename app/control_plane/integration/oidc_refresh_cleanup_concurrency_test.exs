defmodule Ankole.OIDCRefreshCleanupConcurrencyTest do
  use Ankole.DataCase, async: false
  @moduletag sandbox: false

  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2]
  import Ankole.PrincipalsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Ankole.{OIDC, Repo}
  alias Ankole.OIDC.{Client, RefreshStore, RefreshToken, RefreshTokenFamily, Session}

  setup %{tenant: tenant} do
    human = human_fixture()

    assert {:ok, %{client: client}} =
             OIDC.create_client(%{
               name: "Concurrent refresh cleanup",
               type: "public",
               enabled: true,
               redirect_uris: ["https://cleanup.example.test/callback"],
               scopes: ["openid", "offline_access"]
             })

    assert {:ok, session} =
             Ankole.OIDCFixtures.session(human.principal.uid, client.id, "openid offline_access")

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        cleanup_tenant!(tenant)

        Repo.delete_all(
          from(browser in Ankole.BrowserSessions.Session,
            where: browser.id == ^session.browser_id
          )
        )
      end)
    end)

    %{human: human.principal, client: client, session: session}
  end

  test "expired Session cleanup cannot invert a replay's family revocation locks", context do
    now = System.system_time(:second)
    issued = issue(context, now - 120)

    assert {:ok, _} =
             Attesto.RefreshToken.rotate(RefreshStore, issued.token,
               client_id: context.client.id,
               ttl: 60,
               now: now - 119
             )

    assert :ok =
             RefreshStore.redact_expired_successors(
               DateTime.from_unix!(now * 1_000_000, :microsecond)
             )

    context.session
    |> Ecto.Changeset.change(
      expires_at: DateTime.from_unix!((now - 60) * 1_000_000, :microsecond)
    )
    |> Repo.update!()

    replay =
      pause_at_family_lock(fn ->
        Attesto.RefreshToken.rotate(RefreshStore, issued.token, client_id: context.client.id)
      end)

    cleanup =
      start_operation(fn ->
        OIDC.cleanup_expired_credentials(DateTime.from_unix!(now * 1_000_000, :microsecond))
      end)

    refute replay.backend_pid == cleanup.backend_pid
    assert_blocked_by(cleanup, replay)

    assert %{rows: [[cleanup_query]]} =
             Repo.query!("SELECT query FROM pg_stat_activity WHERE pid = $1", [
               cleanup.backend_pid
             ])

    assert String.contains?(cleanup_query, ~s(DELETE FROM "oidc_sessions"))

    refute Repo.exists?(from(token in RefreshToken, where: token.family_id == ^issued.family_id))

    send(replay.task.pid, :continue_credential_write)
    assert {:error, :reuse_detected} = Task.await(replay.task, 10_000)
    assert %{refresh_tokens: 2, oidc_sessions: 1} = Task.await(cleanup.task, 10_000)
    refute Repo.get(Session, context.session.id)
    refute Repo.get(RefreshTokenFamily, issued.family_id)
  end

  test "Client deletion waits before a rotation's native credential foreign keys", context do
    issued = issue(context, System.system_time(:second))

    rotation =
      pause_at_family_lock(fn ->
        Attesto.RefreshToken.rotate(RefreshStore, issued.token, client_id: context.client.id)
      end)

    deletion = start_operation(fn -> OIDC.delete_client(context.client.id) end)
    refute rotation.backend_pid == deletion.backend_pid
    assert_blocked_by(deletion, rotation)
    send(rotation.task.pid, :continue_credential_write)
    assert {:ok, rotated} = Task.await(rotation.task, 10_000)
    assert rotated.generation == 1
    assert {:ok, %{id: id}} = Task.await(deletion.task, 10_000)
    assert id == context.client.id
    refute Repo.get(Client, id)
    refute Repo.get(Session, context.session.id)
    refute Repo.get(RefreshTokenFamily, issued.family_id)
    refute Repo.get(RefreshToken, Attesto.Secret.hash(rotated.token))
  end

  test "Client deletion cannot invert an existing Session authorization's credential locks",
       context do
    {:ok, challenge} = Attesto.PKCE.challenge(Attesto.Secret.generate())

    authentication =
      Ankole.BrowserSessions.authentication(
        %{
          "id" => context.session.authentication_id,
          "revision" => context.session.authentication_revision
        },
        :oauth
      )

    authorization =
      pause_database_operation(
        fn ->
          Ankole.OIDC.Grants.authorize(
            %{
              "client_id" => context.client.id,
              "redirect_uri" => hd(context.client.redirect_uris),
              "scope" => "openid offline_access",
              "code_challenge" => challenge
            },
            authentication
          )
        end,
        fn query ->
          String.contains?(query, ~s("oidc_sessions")) and
            (String.starts_with?(query, "INSERT") or String.starts_with?(query, "UPDATE"))
        end
      )

    deletion = start_operation(fn -> OIDC.delete_client(context.client.id) end)
    refute authorization.backend_pid == deletion.backend_pid
    assert_blocked_by(deletion, authorization)
    send(authorization.task.pid, :continue_credential_write)
    assert {:ok, code} = Task.await(authorization.task, 10_000)
    assert is_binary(code)
    assert {:ok, %{id: id}} = Task.await(deletion.task, 10_000)
    assert id == context.client.id
    refute Repo.get(Client, id)
    refute Repo.get(Session, context.session.id)
    refute Repo.get(Ankole.OIDC.AuthorizationCode, Attesto.Secret.hash(code))
  end

  test "Human revocation waits before a rotation's subject foreign key", context do
    issued = issue(context, System.system_time(:second))

    rotation =
      pause_at_family_lock(fn ->
        Attesto.RefreshToken.rotate(RefreshStore, issued.token, client_id: context.client.id)
      end)

    revocation =
      start_operation(fn ->
        Ankole.Principals.HumanAccess.restrict_from_provider(
          context.human.uid,
          "oidc-fixture",
          "directory_disabled",
          Ankole.Ecto.UUIDv7.autogenerate()
        )
      end)

    refute rotation.backend_pid == revocation.backend_pid
    assert_blocked_by(revocation, rotation)
    send(rotation.task.pid, :continue_credential_write)
    assert {:ok, rotated} = Task.await(rotation.task, 10_000)
    assert {:ok, %{status: :disabled}} = Task.await(revocation.task, 10_000)
    assert %DateTime{} = Repo.reload!(context.session).revoked_at

    assert {:error, "invalid_grant", _} =
             OIDC.Grants.exchange(context.client, %{
               "grant_type" => "refresh_token",
               "refresh_token" => rotated.token
             })

    assert %DateTime{} = Repo.get!(RefreshTokenFamily, issued.family_id).revoked_at
    assert :error = RefreshStore.get(Attesto.Secret.hash(rotated.token))
  end

  for unavailable <- [:suspended_at, :deleting_at] do
    @unavailable unavailable
    test "a tenant with #{unavailable} rejects renewal and revokes the rotated family", context do
      issued = issue(context, System.system_time(:second))

      Repo.get!(Ankole.Tenants.Tenant, context.tenant.id)
      |> Ecto.Changeset.change(%{@unavailable => DateTime.utc_now(:microsecond)})
      |> Repo.update!()

      assert {:error, "invalid_grant", _} =
               OIDC.Grants.exchange(context.client, %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => issued.token
               })

      assert %DateTime{} = Repo.get!(RefreshTokenFamily, issued.family_id).revoked_at
      assert %DateTime{} = Repo.reload!(context.session).revoked_at
      refute Repo.exists?(RefreshToken)
    end
  end

  defp issue(context, now) do
    assert {:ok, issued} =
             Attesto.RefreshToken.issue(
               RefreshStore,
               %{
                 subject: context.human.uid,
                 client_id: context.client.id,
                 scope: ["openid", "offline_access"],
                 claims: %{"session_id" => context.session.id}
               },
               now: now,
               ttl: 60,
               family_ttl: 60
             )

    issued
  end

  defp pause_at_family_lock(fun) do
    pause_database_operation(fun, fn query ->
      String.contains?(query, ~s(FROM "oidc_refresh_token_families")) and
        String.contains?(query, "FOR UPDATE")
    end)
  end

  defp pause_database_operation(fun, matches_query?) do
    parent = self()
    handler = {__MODULE__, make_ref()}
    on_exit(fn -> :telemetry.detach(handler) end)

    operation =
      start_operation(fn ->
        owner = self()

        :ok =
          :telemetry.attach(
            handler,
            [:ankole, :repo, :query],
            fn _event, _measurements, metadata, _config ->
              if self() == owner and matches_query?.(metadata.query) do
                :ok = :telemetry.detach(handler)
                send(parent, {:credential_locked, self()})

                receive do
                  :continue_credential_write -> :ok
                after
                  10_000 -> raise "test did not release its credential write"
                end
              end
            end,
            nil
          )

        fun.()
      end)

    pid = operation.task.pid
    assert_receive {:credential_locked, ^pid}, 5_000
    operation
  end

  defp start_operation(fun) do
    parent = self()
    tenant_id = Repo.tenant_id!()

    task =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.checkout(fn ->
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:database_task, self(), backend_pid})
              fun.()
            end)
          end)
        end)
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    pid = task.pid
    assert_receive {:database_task, ^pid, backend_pid}, 5_000
    %{task: task, backend_pid: backend_pid}
  end

  defp assert_blocked_by(waiter, holder) do
    assert {:ok, true} =
             wait_until(deadline(5_000), fn ->
               %{rows: [[blocked]]} =
                 Repo.query!("SELECT $1 = ANY(pg_blocking_pids($2))", [
                   holder.backend_pid,
                   waiter.backend_pid
                 ])

               blocked
             end)
  end
end
