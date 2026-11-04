defmodule Ankole.Connectors.TriggerConsentTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  alias Ankole.Connectors.{Accounts, OAuth, Store, Trigger, Triggers}
  alias Ankole.Plugins.LarkAdapter.Config

  defmodule Lark do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      body =
        case conn.request_path do
          "/open-apis/authen/v2/oauth/token" ->
            {:ok, body, _conn} = read_body(conn)
            params = Torque.decode!(body)
            send(owner, {:oauth_exchange, params})

            scope =
              if params["code"] == "calendar",
                do: "calendar:calendar.event:read",
                else: "contact:user.employee_id:readonly"

            %{
              "access_token" => params["code"] <> "-token",
              "refresh_token" => "refresh-token",
              "expires_in" => 3600,
              "scope" => scope
            }

          "/open-apis/authen/v1/user_info" ->
            %{"code" => 0, "data" => %{"user_id" => "member-id"}}

          "/open-apis/calendar/v4/calendars/primary/events/subscription" ->
            send(owner, {:calendar_subscribed, get_req_header(conn, "authorization")})
            %{"code" => 0, "data" => %{}}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(200, Torque.encode!(body))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Lark, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env(:ankole, Config)
    Application.put_env(:ankole, Config, client_opts: [base_url: "http://127.0.0.1:#{port}"])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ankole, Config, value)
        :error -> Application.delete_env(:ankole, Config)
      end
    end)

    %{principal: admin} = human_fixture()
    %{principal: member} = human_fixture()
    {:ok, _} = Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(admin.uid) end)

    {:ok, config} =
      Store.create_auth_config(admin, %{
        "plugin_id" => "lark",
        "slug" => "calendar",
        "auth_scheme" => "lark_app",
        "secret" => %{"appID" => "app-#{admin.uid}", "appSecret" => "secret"}
      })

    %{admin: admin, member: member, config: config}
  end

  test "a member progressively authorizes a calendar subscription and can resume after reduced grants",
       ctx do
    attrs = %{
      "auth_config_id" => ctx.config.id,
      "trigger_type" => "lark_calendar",
      "scope_key" => "primary"
    }

    assert {:error, %{code: "oauth_consent_required", authorization_url: url}} =
             Triggers.create(ctx.member, attrs)

    assert URI.parse(url).host != nil
    assert Ankole.Ash.count!(Trigger) == 0

    %{principal: assistant} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: ctx.member.uid})

    assert {:error, %{authorization_url: ^url, owner_principal_uid: owner}} =
             Triggers.create(assistant, attrs)

    assert owner == ctx.member.uid

    {account, initial} = authorize(ctx, [], "minimal")
    refute initial["scope"] =~ "calendar:"
    attrs = Map.put(attrs, "connected_account_id", account.id)

    assert {:error, %{code: "oauth_consent_required", scopes: required} = consent} =
             Triggers.create(ctx.member, attrs)

    assert required == ["calendar:calendar.event:read"]
    assert consent.owner_principal_uid == ctx.member.uid
    query = consent.authorization_url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["connection"] == ctx.config.slug
    assert query["trigger_type"] == "lark_calendar"
    assert Ankole.Pod.APIError.public_error(consent).details == consent
    refute_received {:calendar_subscribed, _}

    {account, consent_params} = authorize(ctx, required, "calendar")
    assert consent_params["scope"] =~ "calendar:calendar.event:read"
    assert {:ok, trigger} = Triggers.create(ctx.member, attrs)
    assert trigger.connected_account_id == account.id

    %{principal: agent} = agent_fixture()
    Ankole.ConversationsFixtures.grant_chat(ctx.member.uid, agent.uid)

    binding_attrs = %{
      "config_ref" => trigger.config_ref,
      "agent_uid" => agent.uid,
      "target" => %{"conversation_id" => Ankole.Kernel.gen_uuid_v7()}
    }

    assert {:ok, binding} =
             Ankole.Signals.EventBindings.put(Ankole.AuthZ.Actor.new(ctx.member), binding_attrs)

    assert {:ok, %{status: "active"}} = Triggers.reconcile(trigger.id)
    assert_received {:calendar_subscribed, ["Bearer calendar-token"]}

    authorize(ctx, [], "minimal")

    assert {:error, %{code: "oauth_consent_required", authorization_url: _}} =
             Triggers.retry(ctx.member, trigger.id)

    assert {:ok, %{status: "active"}} = Triggers.get(trigger.id)

    assert {:error, admin_consent} = Triggers.retry(ctx.admin, trigger.id)
    assert admin_consent.owner_principal_uid == ctx.member.uid
    refute Map.has_key?(admin_consent, :authorization_url)

    %{principal: other} = human_fixture()
    assert {:error, :forbidden} = Triggers.retry(other, trigger.id)

    assert {:ok, _} =
             Ankole.Signals.EventBindings.put(
               Ankole.AuthZ.Actor.new(ctx.member),
               Map.merge(binding_attrs, %{"id" => binding.id, "enabled" => false})
             )

    assert {:ok, %{status: "deleting"}} = Triggers.delete(ctx.member, trigger.id)
    assert {:ok, %{status: "deleting"}} = Triggers.retry(ctx.member, trigger.id)
  end

  test "broad calendar grants satisfy subscription read access", ctx do
    {:ok, account} =
      Accounts.put_human_tokens(
        ctx.config.id,
        ctx.member.uid,
        %{"access_token" => "existing-token", "expires_in" => 3600},
        %{granted_scopes: ["calendar:calendar"]}
      )

    assert {:ok, _} =
             Triggers.create(ctx.member, %{
               "auth_config_id" => ctx.config.id,
               "trigger_type" => "lark_calendar",
               "scope_key" => "primary",
               "connected_account_id" => account.id
             })
  end

  test "subscription lists batch account authorization and retain subscriptions needing repair",
       ctx do
    other = human_fixture().principal

    %{principal: assistant} =
      agent_fixture(%{type: :personal_assistant, owner_principal_uid: ctx.member.uid})

    triggers =
      for human <- [ctx.member, other], into: %{} do
        {:ok, account} =
          Accounts.put_human_tokens(
            ctx.config.id,
            human.uid,
            %{"access_token" => "calendar-token"},
            %{granted_scopes: ["calendar:calendar.event:read"]}
          )

        rows =
          for index <- 1..12 do
            {:ok, trigger} =
              Triggers.create(human, %{
                auth_config_id: ctx.config.id,
                connected_account_id: account.id,
                trigger_type: "lark_calendar",
                scope_key: "#{human.uid}-#{index}"
              })

            trigger
          end

        {human.uid, %{account: account, rows: rows}}
      end

    {:ok, application_trigger} =
      Triggers.create(ctx.admin, %{
        auth_config_id: ctx.config.id,
        trigger_type: "lark_approval",
        scope_key: "application-approval"
      })

    {:ok, _} = Accounts.disconnect_account(ctx.member, triggers[ctx.member.uid].account.id)
    own_ids = triggers[ctx.member.uid].rows |> Enum.map(& &1.id) |> Enum.sort()

    for actor <- [ctx.member, Ankole.AuthZ.Actor.new(assistant)] do
      {{:ok, listed}, queries} = capture_list_queries(fn -> Triggers.list(actor) end)
      assert Enum.sort(Enum.map(listed, & &1.id)) == own_ids

      assert length(queries) <= 5,
             "listing issued #{length(queries)} queries: #{inspect(queries)}"

      assert Enum.count(queries, &String.contains?(&1, ~s(FROM "connector_connected_accounts"))) ==
               1

      assert Enum.count(queries, &String.contains?(&1, ~s(FROM "connector_triggers"))) == 1
    end

    assert {:ok, admin_rows} = Triggers.list(ctx.admin)

    expected =
      [application_trigger | triggers[ctx.member.uid].rows ++ triggers[other.uid].rows]
      |> Enum.map(& &1.id)
      |> Enum.sort()

    assert Enum.sort(Enum.map(admin_rows, & &1.id)) == expected
    assert {:ok, []} = Triggers.list(human_fixture().principal)

    for trigger <- admin_rows do
      assert Triggers.authorize(ctx.member, trigger) == :ok == trigger.id in own_ids
    end
  end

  defp capture_list_queries(fun) do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "SELECT"),
            do: send(owner, {handler, metadata.query})
        end,
        nil
      )

    try do
      result = fun.()
      {result, collected_queries(handler)}
    after
      :telemetry.detach(handler)
    end
  end

  defp collected_queries(handler) do
    receive do
      {^handler, query} -> [query | collected_queries(handler)]
    after
      0 -> []
    end
  end

  defp authorize(ctx, scopes, code) do
    {:ok, %{authorization_url: url}} =
      OAuth.begin(ctx.member, %{"connection" => ctx.config.slug, "scopes" => scopes})

    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    {:ok, %{completion_code: completion}} =
      OAuth.callback(%{"state" => params["state"], "code" => code})

    {:ok, account} = OAuth.claim(ctx.member, completion)
    {account, params}
  end
end
