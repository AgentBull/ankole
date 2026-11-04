defmodule Ankole.Plugins.CloudConnectorsAdapter.ProtocolTest do
  use Ankole.DataCase, async: false
  alias Ankole.Connectors.ToolSpec

  alias Ankole.Plugins.CloudConnectorsAdapter.{
    Adapter,
    Catalog,
    Definitions,
    Protocol,
    Signatures,
    Subscriptions,
    Webhooks
  }

  defmodule Provider do
    import Plug.Conn
    def init(owner), do: owner

    def call(conn, owner) do
      {:ok, raw, conn} = read_body(conn)
      send(owner, {:request, conn.method, conn.request_path, conn.req_headers, raw})

      body =
        case {conn.method, conn.request_path} do
          {"POST", "/oauth/token"} ->
            %{
              "access_token" => "new-access",
              "refresh_token" => "rotated-refresh",
              "expires_in" => 7200
            }

          {"GET", "/api/v4/user"} ->
            %{"id" => 42, "name" => "Pat"}

          {"GET", "/api/v4/projects/org%2Frepo/hooks"} ->
            []

          {"POST", "/api/v4/projects/org%2Frepo/hooks"} ->
            %{"id" => 72}

          {"GET", "/api/v4/projects/org%2Frepo/hooks/72"} ->
            %{"id" => 72, "url" => "https://console.example/hooks/1"}

          {"DELETE", "/api/v4/projects/org%2Frepo/hooks/72"} ->
            %{}

          {"GET", "/api/0/organizations/"} ->
            [%{"id" => "9", "name" => "Example"}]

          {"GET", "/webhook_endpoints"} ->
            %{
              "data" => [
                %{"id" => "we_unrelated", "url" => "https://other.example/hooks/1"},
                %{"id" => "we_existing", "url" => "https://console.example/hooks/1"}
              ]
            }

          {"POST", "/webhook_endpoints"} ->
            %{"id" => "we_recreated", "secret" => "recovered-signing-secret"}

          {"POST", "/webhook_endpoints/we_existing"} ->
            %{"id" => "we_existing"}

          {"GET", "/webhook_endpoints/we_existing"} ->
            %{"id" => "we_existing", "url" => "https://console.example/hooks/1"}

          {"DELETE", "/webhook_endpoints/we_existing"} ->
            %{"deleted" => true}

          {"GET", "/1/webhooks/deleted"} ->
            %{"error" => "not found"}

          {"GET", "/1/webhooks/disabled"} ->
            %{"id" => "disabled", "active" => false}

          {"PUT", "/1/webhooks/disabled"} ->
            raw |> Torque.decode!() |> Map.put("id", "disabled")

          {"POST", "/1/webhooks"} ->
            raw |> Torque.decode!() |> Map.put("id", "recreated")

          {"GET", "/webhook_subscriptions/known"} ->
            %{"resource" => %{"uri" => "https://api.calendly.com/webhook_subscriptions/known"}}

          {"GET", "/webhook_subscriptions"} ->
            %{"collection" => []}

          {"POST", "/webhook_subscriptions"} ->
            %{"resource" => %{"uri" => "https://api.calendly.com/webhook_subscriptions/known"}}

          {"DELETE", "/webhook_subscriptions/known"} ->
            %{}
        end

      status = if conn.request_path == "/1/webhooks/deleted", do: 404, else: 200
      conn |> put_resp_content_type("application/json") |> send_resp(status, Torque.encode!(body))
    end
  end

  setup do
    server = start_supervised!({Bandit, plug: {Provider, self()}, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    %{config: %{public_metadata: %{"base_url" => "http://127.0.0.1:#{port}"}}}
  end

  test "every selected operation has a frozen recursive contract and execution version" do
    for {id, _, _, _, _} <- Definitions.platforms() do
      tools = Catalog.tools(id)
      assert length(tools) >= 25

      for tool <- tools do
        assert tool.operation["version"] =~ ~r/^\d{8}_\d{2}$/
        assert %ToolSpec{} = ToolSpec.compile(tool)
        assert tool.output_schema["required"] == ["result"]
        assert is_list(tool.scopes)
        assert Enum.all?(tool.scopes, &is_binary/1)
        refute Torque.encode!(tool.input_schema) =~ "$undefined"
        refute Torque.encode!(tool.output_schema) =~ "$undefined"
      end
    end

    tool = Enum.find(Catalog.tools("figma"), &(&1.name == "add_a_comment_to_a_file"))
    assert {:error, _} = ToolSpec.validate_input(tool, %{"file_key" => "file"})

    assert {:ok, _} =
             ToolSpec.validate_input(tool, %{"file_key" => "file", "message" => "Review this"})
  end

  test "public results omit only invalid optional nulls and retain required and nullable data" do
    schema = %{
      "type" => "object",
      "required" => ["required_value"],
      "$defs" => %{
        "Child" => %{
          "type" => "object",
          "properties" => %{"optional_value" => %{"type" => "string"}}
        }
      },
      "properties" => %{
        "required_value" => %{"type" => "string"},
        "optional_value" => %{"type" => "string"},
        "nullable_value" => %{"type" => ["string", "null"]},
        "children" => %{
          "type" => "array",
          "items" => %{
            "anyOf" => [
              %{"$ref" => "#/$defs/Child"},
              %{"type" => "null"}
            ]
          }
        }
      }
    }

    value = %{
      "required_value" => nil,
      "optional_value" => nil,
      "nullable_value" => nil,
      "children" => [%{"optional_value" => nil}, nil],
      "composio_execution_message" => "internal"
    }

    assert Adapter.public_result(value, schema) == %{
             "required_value" => nil,
             "nullable_value" => nil,
             "children" => [%{}, nil]
           }

    assert {:error, _} =
             Ankole.Sessions.ToolArguments.validate(schema, Adapter.public_result(value, schema))
  end

  test "the current time contract preserves its real fields and accepts the successful live response" do
    tool = Enum.find(Catalog.tools("googlecalendar"), &(&1.name == "get_current_date_time"))
    schema = tool.output_schema["$defs"]["GetCurrentDateTimeResponse"]
    assert schema["properties"]["current_datetime"]["type"] == "string"
    assert schema["required"] == ["current_datetime", "yyyymmdd_datetime"]

    result =
      Adapter.public_result(
        %{
          "result" => %{
            "current_datetime" => "2026-11-04T17:45:00+08:00",
            "yyyymmdd_datetime" => "2026,11,4,17,45,0",
            "display_url" => nil
          }
        },
        tool.output_schema
      )["result"]

    refute Map.has_key?(result, "display_url")
    assert {:ok, _} = ToolSpec.validate_output(tool, %{"result" => result})
  end

  test "Zendesk recursive attachment schemas retain nested thumbnails" do
    tool = Enum.find(Catalog.tools("zendesk"), &(&1.name == "get_organization_users"))

    schema = %{
      "$defs" => tool.output_schema["$defs"],
      "$ref" => "#/$defs/UserPhotoAttachment"
    }

    result =
      Adapter.public_result(
        %{
          "id" => 1,
          "thumbnails" => [%{"id" => 2, "content_url" => nil, "thumbnails" => [%{"id" => 3}]}]
        },
        schema
      )

    assert result == %{
             "id" => 1,
             "thumbnails" => [%{"id" => 2, "thumbnails" => [%{"id" => 3}]}]
           }

    assert {:ok, _} = Ankole.Sessions.ToolArguments.validate(schema, result)
  end

  test "tool grants use required scopes instead of upstream alternatives and legacy names" do
    assert Enum.all?(Catalog.tools("salesforce"), &(&1.scopes == ["api"]))

    report = Enum.find(Catalog.tools("google_analytics"), &(&1.name == "run_report"))
    assert report.scopes == ["https://www.googleapis.com/auth/analytics.readonly"]

    share = Enum.find(Catalog.tools("calendly"), &(&1.name == "create_share"))
    assert share.scopes == ["shares:write"]

    assert Enum.all?(Catalog.tools("trello"), fn tool ->
             Enum.all?(tool.scopes, &String.ends_with?(&1, ":trello"))
           end)
  end

  test "OAuth grants preserve PKCE, offline access, and the Ankole callback" do
    for id <- ~w(gitlab typeform salesforce trello calendly googlecalendar google_analytics) do
      assert {:ok, url} =
               Protocol.authorize(id, %{}, %{"clientID" => "official"}, %{
                 "state" => "state",
                 "code_challenge" => "challenge",
                 "code_challenge_method" => "S256",
                 "redirect_uri" => "https://console.example/oauth/cloud/connectors/callback"
               })

      query = URI.decode_query(URI.parse(url).query)
      assert query["redirect_uri"] == "https://console.example/oauth/cloud/connectors/callback"
      assert query["code_challenge"] == "challenge"
      refute String.contains?(url, "composio")
      if id in ~w(googlecalendar google_analytics), do: assert(query["access_type"] == "offline")
    end
  end

  test "GitLab exchanges and rotates tokens through the real HTTP protocol", %{config: config} do
    secret = %{"clientID" => "app", "clientSecret" => "client-secret"}

    assert {:ok, tokens} =
             Protocol.exchange("gitlab", config, secret, %{
               "code" => "code",
               "code_verifier" => "proof",
               "scope" => "api"
             })

    assert tokens["external_subject_id"] == "42"
    assert tokens["scope"] == "api"
    assert_receive {:request, "POST", "/oauth/token", _, raw}
    assert URI.decode_query(raw)["code_verifier"] == "proof"
    refute Map.has_key?(URI.decode_query(raw), "scope")
    assert_receive {:request, "GET", "/api/v4/user", headers, ""}
    assert {"authorization", "Bearer new-access"} in headers

    assert {:ok, rotated} =
             Protocol.refresh("gitlab", config, secret, %{
               "refresh_token" => "previous",
               "public_metadata" => %{"name" => "Pat"}
             })

    assert rotated["refresh_token"] == "rotated-refresh"
    assert rotated["public_metadata"] == %{"name" => "Pat"}
  end

  test "Sentry validates the account before binding and retains the credential", %{config: config} do
    assert {:ok, account} = Protocol.validate("sentry", config, %{"access_token" => "pat"})
    assert account["access_token"] == "pat"
    assert account["external_subject_id"] == "9"
    assert account["public_metadata"]["name"] == "Example"
  end

  test "a cloud Sentry binding preserves the regional platform URL", %{config: config} do
    base = config.public_metadata["base_url"]

    assert {:ok, account} =
             Protocol.validate("sentry", %{}, %{"access_token" => "pat", "base_url" => base})

    assert account["public_metadata"]["base_url"] == base
    assert {:ok, %{"base_url" => ^base}} = Protocol.auth_params("sentry", %{}, account)
    assert_receive {:request, "GET", "/api/0/organizations/", _, ""}
  end

  test "PAT connections have no globally shared OAuth application identity" do
    for id <- ~w(figma stripe sentry zendesk),
        do: assert({:ok, nil} == Protocol.platform_application(id, %{}))

    assert {:error, :oauth_client_id_required} = Protocol.platform_application("gitlab", %{})
  end

  test "credentials map to each platform's actual authentication protocol" do
    assert {:ok, %{"parameters" => [%{"name" => "X-Figma-Token", "value" => "figd_pat"}]}} =
             Protocol.auth_params("figma", %{}, %{"access_token" => "figd_pat"})

    assert {:ok, auth} =
             Protocol.auth_params("zendesk", %{}, %{
               "email" => "admin@example.com",
               "subdomain" => "support",
               "api_token" => "pat"
             })

    assert auth["base_url"] == "https://support.zendesk.com"
    assert [%{"value" => "Basic " <> encoded}] = auth["parameters"]
    assert Base.decode64!(encoded) == "admin@example.com/token:pat"

    assert {:ok, %{"base_url" => "https://customer.salesforce.com"}} =
             Protocol.auth_params("salesforce", %{}, %{
               "access_token" => "token",
               "public_metadata" => %{"instance_url" => "https://customer.salesforce.com"}
             })
  end

  test "broader Google and GitLab scopes satisfy narrower requests" do
    assert Protocol.scopes_satisfied?("gitlab", ~w(read_api read_user), ["api"])
    assert Protocol.scopes_satisfied?("salesforce", ["api"], ["full"])

    assert Protocol.scopes_satisfied?("calendly", ["scheduled_events:read"], [
             "scheduled_events:write"
           ])

    assert Protocol.scopes_satisfied?(
             "googlecalendar",
             ["https://www.googleapis.com/auth/calendar.events.readonly"],
             ["https://www.googleapis.com/auth/calendar"]
           )

    refute Protocol.scopes_satisfied?(
             "googlecalendar",
             ["https://www.googleapis.com/auth/calendar"],
             ["https://www.googleapis.com/auth/calendar.readonly"]
           )
  end

  test "GitLab registers the requested project events and shared signing secret", %{
    config: config
  } do
    endpoint =
      endpoint(%{"scope_key" => "org/repo"})
      |> Map.put("event_types", ["gitlab.push", "gitlab.issue.updated"])

    assert {:ok, %{"external_subscription_id" => "72"}} =
             Subscriptions.reconcile(
               "gitlab",
               config,
               %{"access_token" => "token"},
               endpoint,
               true
             )

    assert_receive {:request, "POST", "/api/v4/projects/org%2Frepo/hooks", _, raw}
    body = Torque.decode!(raw)
    assert body["issues_events"]
    assert body["push_events"]
    refute body["merge_requests_events"]
    assert body["token"] == "secret"
  end

  test "Stripe updates one shared endpoint and deletes it when the final subscription leaves", %{
    config: config
  } do
    endpoint =
      endpoint(%{})
      |> Map.merge(%{
        "event_types" => ["stripe.invoice.paid", "stripe.payment_intent.succeeded"],
        "external_subscription_id" => "we_existing"
      })

    assert {:ok, %{"external_subscription_id" => "we_existing"}} =
             Subscriptions.reconcile("stripe", config, %{"access_token" => "key"}, endpoint, true)

    assert_receive {:request, "POST", "/webhook_endpoints/we_existing", headers, raw}
    assert {"content-type", "application/x-www-form-urlencoded"} in headers
    assert raw =~ "enabled_events%5B%5D=invoice.paid"
    refute_receive {:request, "DELETE", _, _, _}
    refute_receive {:request, "POST", "/webhook_endpoints", _, _}

    assert {:ok, %{"external_subscription_id" => nil}} =
             Subscriptions.reconcile(
               "stripe",
               config,
               %{"access_token" => "key"},
               endpoint,
               false
             )

    assert_receive {:request, "DELETE", "/webhook_endpoints/we_existing", _, _}
  end

  test "Stripe recreates only its unclaimed callback to recover the signing secret", %{
    config: config
  } do
    endpoint = endpoint(%{}) |> Map.put("event_types", ["stripe.invoice.paid"])

    assert {:ok,
            %{
              "external_subscription_id" => "we_recreated",
              "signing_secret" => "recovered-signing-secret"
            }} =
             Subscriptions.reconcile("stripe", config, %{"access_token" => "key"}, endpoint, true)

    assert_receive {:request, "GET", "/webhook_endpoints", _, ""}
    assert_receive {:request, "DELETE", "/webhook_endpoints/we_existing", _, ""}
    assert_receive {:request, "POST", "/webhook_endpoints", _, raw}
    assert raw =~ "enabled_events%5B%5D=invoice.paid"
    refute_receive {:request, "DELETE", "/webhook_endpoints/we_unrelated", _, _}
  end

  test "Stripe leaves other callbacks alone when creating a new endpoint", %{config: config} do
    endpoint =
      endpoint(%{})
      |> Map.put("callback_url", "https://console.example/hooks/new")
      |> Map.put("event_types", ["stripe.invoice.paid"])

    assert {:ok, %{"external_subscription_id" => "we_recreated"}} =
             Subscriptions.reconcile("stripe", config, %{"access_token" => "key"}, endpoint, true)

    assert_receive {:request, "POST", "/webhook_endpoints", _, _}
    refute_receive {:request, "DELETE", _, _, _}
  end

  test "Trello recreates the webhook removed with a revoked grant", %{config: config} do
    endpoint =
      endpoint(%{"scope_key" => "board"}) |> Map.put("external_subscription_id", "deleted")

    credentials = %{"access_token" => "new-grant", "application_secret" => "client-secret"}

    assert {:ok,
            %{"external_subscription_id" => "recreated", "signing_secret" => "client-secret"}} =
             Subscriptions.reconcile("trello", config, credentials, endpoint, true)

    assert_receive {:request, "GET", "/1/webhooks/deleted", _, ""}
    assert_receive {:request, "POST", "/1/webhooks", _, raw}
    body = Torque.decode!(raw)
    assert body["idModel"] == "board"
    assert body["active"] == true
    refute_receive {:request, "PUT", "/1/webhooks/deleted", _, _}
  end

  test "Trello reactivates a disabled webhook without replacing its ID", %{config: config} do
    endpoint =
      endpoint(%{"scope_key" => "board"}) |> Map.put("external_subscription_id", "disabled")

    credentials = %{"access_token" => "token", "application_secret" => "client-secret"}

    assert {:ok, %{"external_subscription_id" => "disabled"}} =
             Subscriptions.reconcile("trello", config, credentials, endpoint, true)

    assert_receive {:request, "GET", "/1/webhooks/disabled", _, ""}
    assert_receive {:request, "PUT", "/1/webhooks/disabled", _, raw}
    assert Torque.decode!(raw)["active"] == true
    refute_receive {:request, "POST", "/1/webhooks", _, _}
  end

  test "webhook cleanup addresses the durable upstream ID independently of list pagination", %{
    config: config
  } do
    for {platform, id, scope, path} <- [
          {"gitlab", "72", "org/repo", "/api/v4/projects/org%2Frepo/hooks/72"},
          {"calendly", "https://api.calendly.com/webhook_subscriptions/known", "org",
           "/webhook_subscriptions/known"}
        ] do
      endpoint = endpoint(%{"scope_key" => scope}) |> Map.put("external_subscription_id", id)

      assert {:ok, %{"external_subscription_id" => nil}} =
               Subscriptions.reconcile(
                 platform,
                 config,
                 %{"access_token" => "token"},
                 endpoint,
                 false
               )

      assert_receive {:request, "GET", ^path, _, ""}
      assert_receive {:request, "DELETE", ^path, _, ""}
    end
  end

  test "Calendly's personal subscription registers the connected user and organization is explicit",
       %{config: config} do
    organization = "https://api.calendly.com/organizations/org"
    user = "https://api.calendly.com/users/person"
    credentials = %{"access_token" => "token", "external_subject_id" => user}

    for scope <- [nil, "user", "organization"] do
      resource = %{"scope_key" => organization}
      resource = if scope, do: Map.put(resource, "scope", scope), else: resource

      assert {:ok, _} =
               Subscriptions.reconcile("calendly", config, credentials, endpoint(resource), true)

      assert_receive {:request, "POST", "/webhook_subscriptions", _, raw}
      body = Torque.decode!(raw)
      assert body["organization"] == organization
      assert body["scope"] == (scope || "user")
      assert body["events"] == ~w(invitee.created invitee.canceled)
      assert body["signing_key"] == "secret"

      if scope == "organization",
        do: refute(Map.has_key?(body, "user")),
        else: assert(body["user"] == user)
    end
  end

  test "resource subscription fields expose the platform choices with personal defaults" do
    declarations = Definitions.declarations()
    calendly = Enum.find(declarations, &(&1.id == "calendly"))
    figma = Enum.find(declarations, &(&1.id == "figma"))

    for type <- calendly.trigger_types do
      assert [%{path: "scope", default: "user", type: :select, options: choices}] =
               type.config_fields

      assert Enum.map(choices, & &1.value) == ~w(user organization)
    end

    for type <- figma.trigger_types do
      assert [%{path: "context", default: "file", type: :select, options: choices}] =
               type.config_fields

      assert Enum.map(choices, & &1.value) == ~w(file project team)
    end

    for declaration <- declarations,
        declaration.id in ~w(stripe zendesk),
        type <- declaration.trigger_types do
      assert type.fixed_scope_key == "account"
    end
  end

  test "verified webhooks normalize event names and discard Figma passcodes" do
    body =
      Torque.encode!(%{
        "event_type" => "FILE_UPDATE",
        "passcode" => "secret",
        "file_key" => "file"
      })

    assert {:ok, event} =
             Webhooks.receive("figma", %{}, %{"webhook_secret" => "secret"}, body, [])

    assert event["type"] == "figma.file.updated"
    assert event["data"]["resource"]["id"] == "file"
    refute Map.has_key?(event["data"]["resource"]["attributes"], "passcode")

    assert {:error, :invalid_webhook_signature} =
             Webhooks.receive("figma", %{}, %{"webhook_secret" => "wrong"}, body, [])
  end

  test "Stripe accepts a matching timestamped signature and rejects modified bytes" do
    body = "{}"
    timestamp = to_string(System.system_time(:second))

    signature =
      Base.encode16(:crypto.mac(:hmac, :sha256, "secret", timestamp <> "." <> body), case: :lower)

    headers = [{"stripe-signature", "t=#{timestamp},v1=#{signature}"}]
    assert {:ok, %{}} = Signatures.verify("stripe", "secret", body, headers, %{})

    assert {:error, :invalid_webhook_signature} =
             Signatures.verify("stripe", "secret", "{ }", headers, %{})
  end

  test "Sentry's external integration setup produces actionable instructions" do
    assert {:error,
            %{
              code: "sentry_webhook_configuration_required",
              callback_url: "https://console.example/hooks/1"
            }} =
             Subscriptions.reconcile(
               "sentry",
               %{},
               %{"access_token" => "key"},
               endpoint(%{}),
               true
             )
  end

  test "Sentry delivers only events from the subscribed project" do
    payloads = [
      %{
        "action" => "created",
        "data" => %{
          "issue" => %{"id" => "issue-1", "project" => %{"id" => "1", "slug" => "frontend"}}
        }
      },
      %{
        "action" => "triggered",
        "data" => %{
          "event" => %{
            "event_id" => "event-1",
            "project" => 1,
            "url" => "https://sentry.io/api/0/projects/acme/frontend/events/event-1/"
          }
        }
      }
    ]

    for payload <- payloads do
      raw = Torque.encode!(payload)
      headers = [{"sentry-hook-signature", hmac(raw, :sha256, :hex)}]

      for project <- ["1", "frontend"] do
        assert {:ok, _} =
                 Webhooks.receive(
                   "sentry",
                   %{resource_scope: %{"scope_key" => project}},
                   %{"webhook_secret" => "secret"},
                   raw,
                   headers
                 )
      end

      assert :ignore =
               Webhooks.receive(
                 "sentry",
                 %{resource_scope: %{"scope_key" => "other"}},
                 %{"webhook_secret" => "secret"},
                 raw,
                 headers
               )
    end
  end

  test "native platform signatures and polling deliveries share the declared event data contract" do
    timestamp = to_string(System.system_time(:second))

    samples = [
      {"gitlab", %{"object_kind" => "issue", "object_attributes" => %{"id" => 7}},
       fn _ -> [{"x-gitlab-token", "secret"}] end, "gitlab.issue.updated", "7"},
      {"typeform",
       %{
         "event_id" => "delivery",
         "event_type" => "form_response",
         "form_response" => %{"token" => "response-1"}
       }, fn raw -> [{"typeform-signature", "sha256=" <> hmac(raw, :sha256, :base64)}] end,
       "typeform.form_response.submitted", "response-1"},
      {"trello",
       %{
         "action" => %{
           "id" => "delivery",
           "type" => "updateCard",
           "data" => %{
             "card" => %{"id" => "card-1"},
             "listBefore" => %{"id" => "a"},
             "listAfter" => %{"id" => "b"}
           }
         }
       },
       fn raw ->
         [{"x-trello-webhook", hmac(raw <> "https://console.example/hook", :sha, :base64)}]
       end, "trello.card.moved", "card-1"},
      {"calendly", %{"event" => "invitee.created", "payload" => %{"uri" => "invitee-1"}},
       fn raw ->
         [
           {"calendly-webhook-signature",
            "t=#{timestamp},v1=" <> hmac(timestamp <> "." <> raw, :sha256, :hex)}
         ]
       end, "calendly.invitee.created", "invitee-1"},
      {"sentry",
       %{
         "action" => "created",
         "data" => %{"issue" => %{"id" => "issue-1", "project" => %{"id" => "1"}}}
       }, fn raw -> [{"sentry-hook-signature", hmac(raw, :sha256, :hex)}] end,
       "sentry.issue.created", "issue-1"},
      {"zendesk", %{"event_type" => "zendesk.ticket.created", "ticket" => %{"id" => "ticket-1"}},
       fn raw ->
         [
           {"x-zendesk-webhook-signature-timestamp", timestamp},
           {"x-zendesk-webhook-signature", hmac(timestamp <> raw, :sha256, :base64)}
         ]
       end, "zendesk.ticket.created", "ticket-1"}
    ]

    for {platform, payload, sign, type, id} <- samples do
      raw = Torque.encode!(payload)

      assert {:ok, event} =
               Webhooks.receive(
                 platform,
                 %{
                   :resource_scope => %{"scope_key" => "1"},
                   "callback_url" => "https://console.example/hook"
                 },
                 %{"webhook_secret" => "secret"},
                 raw,
                 sign.(raw)
               )

      assert event["type"] == type
      assert event["data"]["resource"]["id"] == id

      assert {:ok, _} =
               Ankole.Sessions.ToolArguments.validate(
                 Ankole.Plugins.CloudConnectorsAdapter.Events.schema(),
                 event["data"]
               )

      assert {:error, :invalid_webhook_signature} =
               Webhooks.receive(
                 platform,
                 %{"callback_url" => "https://console.example/hook"},
                 %{"webhook_secret" => "wrong"},
                 raw,
                 sign.(raw)
               )
    end

    assert {:ok, data} =
             Webhooks.cloud_event("googlecalendar.event.updated", %{
               "event_id" => "event-1",
               "updated_fields" => ["summary"]
             })

    assert data["resource"]["id"] == "event-1"
    assert data["changes"] == %{"fields" => ["summary"]}

    assert {:ok, _} =
             Ankole.Sessions.ToolArguments.validate(
               Ankole.Plugins.CloudConnectorsAdapter.Events.schema(),
               data
             )

    assert {:ok, data} =
             Webhooks.cloud_event("salesforce.record.created", %{"lead" => %{"id" => "lead-1"}})

    assert data["resource"]["id"] == "lead-1"

    assert {:error, :invalid_trigger_payload} =
             Webhooks.cloud_event("salesforce.record.created", %{
               "opportunity" => %{"id" => "opportunity-1"}
             })

    definition =
      Definitions.declarations()
      |> Enum.find(&(&1.id == "salesforce"))
      |> Map.fetch!(:trigger_types)
      |> Enum.find(&(&1.id == "salesforce.record.created"))

    assert definition.scope_options == ["Lead", "Contact"]
  end

  defp hmac(raw, hash, :base64), do: Base.encode64(:crypto.mac(:hmac, hash, "secret", raw))

  defp hmac(raw, hash, :hex),
    do: Base.encode16(:crypto.mac(:hmac, hash, "secret", raw), case: :lower)

  defp endpoint(scope),
    do: %{
      "callback_url" => "https://console.example/hooks/1",
      "signing_secret" => "secret",
      "external_subscription_id" => nil,
      "resource_scope" => scope,
      "event_types" => []
    }
end
