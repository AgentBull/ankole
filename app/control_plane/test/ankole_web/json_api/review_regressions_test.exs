defmodule AnkoleWeb.JSONAPI.ReviewRegressionsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider, as: AIGatewayProvider
  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Brain.Schemas.Source
  alias Ankole.IdentityProviders
  alias Ankole.Principals
  alias Ankole.Principals.Humans
  alias Ankole.Repo

  defp percent_encode_first_byte(<<byte, rest::binary>>) do
    "%" <> Base.encode16(<<byte>>, case: :upper) <> rest
  end

  test "group aliases and percent-encoded selectors cannot bypass a denied membership write", %{
    conn: conn
  } do
    {conn, operator} = console_conn_with_principal(conn)
    %{principal: member} = human_fixture()
    {:ok, administrators} = AuthZ.get_principal_group("siteadmin")
    {:ok, writers} = AuthZ.create_principal_group(%{name: "writers", display_name: "Writers"})

    Repo.delete_all(Grant)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: operator,
        resource_pattern: "principal_group:*:members",
        action: "update",
        condition: ~s(resource != "principal_group:siteadmin:members")
      })

    for selector <- [
          "siteadmin",
          "SITEADMIN",
          "%73iteadmin",
          "%53ITEADMIN",
          "%20siteadmin%20",
          administrators.id,
          String.upcase(administrators.id),
          percent_encode_first_byte(administrators.id)
        ] do
      conn
      |> api(:put, "/api/v2/principal-groups/#{selector}/members/#{member.uid}", %{})
      |> json_response(403)

      refute AuthZ.site_admin?(member.uid)
    end

    # Double-encoded "%2573iteadmin" decodes once to literal "%73iteadmin" and never reaches "siteadmin".
    conn
    |> api(:put, "/api/v2/principal-groups/%2573iteadmin/members/#{member.uid}", %{})
    |> json_response(404)

    refute AuthZ.site_admin?(member.uid)

    # Equivalent selectors still select an allowed group for both adding and removing members.
    for selector <- [
          "writers",
          "WRITERS",
          "%77riters",
          "%57RITERS",
          writers.id,
          percent_encode_first_byte(writers.id)
        ] do
      conn
      |> api(:put, "/api/v2/principal-groups/#{selector}/members/#{member.uid}", %{})
      |> json_response(200)

      assert {:ok, members} = AuthZ.effective_group_members(writers.id)
      assert Enum.any?(members, &(&1.uid == member.uid))

      conn
      |> api(:delete, "/api/v2/principal-groups/#{selector}/members/#{member.uid}", %{})
      |> json_response(200)

      assert {:ok, []} = AuthZ.effective_group_members(writers.id)
    end
  end

  defp human_with_uid_fixture(uid, display_name) do
    {:ok, principal} =
      Repo.transact(fn ->
        with {:ok, principal} <-
               Humans.insert_principal(%{
                 uid: uid,
                 type: :human,
                 display_name: display_name
               }),
             {:ok, _human_user} <-
               Humans.insert_human_user(principal.uid, %{
                 email: "#{unique_uid("human")}@example.com"
               }) do
          {:ok, principal}
        end
      end)

    principal
  end

  test "opaque identifiers containing literal percent signs decode once end to end", %{conn: conn} do
    {:ok, _provider} = IdentityProviders.save_provider("local-main", "local", %{}, true)
    {conn, operator} = console_conn_with_principal(conn)
    literal_percent = human_with_uid_fixture("ops%41", "Literal")
    plain_a = human_with_uid_fixture("opsa", "Plain A")
    assert literal_percent.uid == "ops%41"
    assert plain_a.uid == "opsa"

    Repo.delete_all(Grant)

    {:ok, deny_literal_grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: operator,
        resource_pattern: "principal:*",
        action: "update",
        condition: ~s(resource != "principal:ops%41")
      })

    conn
    |> api(:patch, "/api/v2/principals/ops%2541", %{
      type: "principal",
      attributes: %{display_name: "Blocked"}
    })
    |> json_response(403)

    assert {:ok, %{display_name: "Literal"}} = Principals.get_principal(literal_percent.uid)

    Repo.delete!(deny_literal_grant)

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: operator,
        resource_pattern: "principal:*",
        action: "update",
        condition: ~s(resource != "principal:opsa")
      })

    # Wire "ops%41" decodes once to "opsA" -> canonical "opsa", which is denied.
    conn
    |> api(:patch, "/api/v2/principals/ops%41", %{
      type: "principal",
      attributes: %{display_name: "Bypass"}
    })
    |> json_response(403)

    assert {:ok, %{display_name: "Plain A"}} = Principals.get_principal(plain_a.uid)

    # Wire "ops%2541" decodes once to literal "ops%41", which is allowed and updates "ops%41" only.
    conn
    |> api(:patch, "/api/v2/principals/ops%2541", %{
      type: "principal",
      attributes: %{display_name: "Updated Literal"}
    })
    |> json_response(200)

    assert {:ok, %{display_name: "Updated Literal"}} = Principals.get_principal("ops%41")
    assert {:ok, %{display_name: "Plain A"}} = Principals.get_principal("opsa")
  end

  test "UUID, provider, model profile, and body target canonicalization matches execution", %{
    conn: conn
  } do
    {conn, operator} = console_conn_with_principal(conn)
    %{principal: source_agent} = agent_fixture()
    %{principal: denied_agent} = agent_fixture()
    %{principal: allowed_agent} = agent_fixture()

    {:ok, provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "openrouter-denied",
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Key", "api_key" => "sk-test"}]}
      })

    {:ok, _} =
      ModelProfiles.put_model_profile(source_agent.uid, "primary", %{
        provider_id: provider.provider_id,
        model: "openai/gpt-5.4"
      })

    {:ok, denied_grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: allowed_agent.uid,
        resource_pattern: "conversations",
        action: "read"
      })

    {:ok, allowed_grant} =
      AuthZ.create_permission_grant(%{
        principal_uid: allowed_agent.uid,
        resource_pattern: "webhooks",
        action: "read"
      })

    Repo.delete_all(from_grants_except([denied_grant.id, allowed_grant.id]))

    for {pattern, action, condition} <- [
          {"permission_grant:*", "delete", ~s(resource != "permission_grant:#{denied_grant.id}")},
          {"ai_gateway_provider:*", "delete",
           ~s(resource != "ai_gateway_provider:openrouter-denied")},
          {"identity_provider:*", "update", ~s(resource != "identity_provider:lark-denied")},
          {"agent:#{source_agent.uid}:model_profile:*", "update",
           ~s(resource != "agent:#{source_agent.uid}:model_profile:primary")},
          {"agent:#{source_agent.uid}:signal_bindings", "delete", "true"},
          {"agent:*:signal_bindings", "update",
           ~s(resource != "agent:#{denied_agent.uid}:signal_bindings")}
        ] do
      {:ok, _} =
        AuthZ.create_permission_grant(%{
          principal_uid: operator,
          resource_pattern: pattern,
          action: action,
          condition: condition
        })
    end

    for selector <- [
          String.upcase(denied_grant.id),
          percent_encode_first_byte(denied_grant.id),
          "%20#{String.upcase(denied_grant.id)}%20"
        ] do
      conn
      |> api(:delete, "/api/v2/permission-grants/#{selector}")
      |> json_response(403)

      assert Repo.get(Grant, denied_grant.id)
    end

    conn
    |> api(:delete, "/api/v2/permission-grants/#{String.upcase(allowed_grant.id)}")
    |> json_response(200)

    refute Repo.get(Grant, allowed_grant.id)

    for selector <- ["OPENROUTER-DENIED", "%6Fpenrouter-denied", "%20OPENROUTER-DENIED%20"] do
      conn
      |> api(:delete, "/api/v2/site/ai-gateway/providers/#{selector}")
      |> json_response(403)

      assert %{disabled_at: nil} =
               Repo.get_by!(AIGatewayProvider, provider_id: "openrouter-denied")
    end

    for selector <- ["LARK-DENIED", "%6Cark-denied", "%20lark-denied%20"] do
      conn
      |> api(:put, "/api/v2/identity-providers/#{selector}", %{
        adapter_id: "lark",
        enabled: true,
        config: %{"appID" => "cli_denied", "appSecret" => "secret"}
      })
      |> json_response(403)

      assert :error =
               AppConfigure.get_by_key("principals.identity_providers.lark.lark-denied")
    end

    for profile <- ["PRIMARY", "%70rimary", "%20PRIMARY%20"] do
      conn
      |> api(:put, "/api/v2/agents/#{source_agent.uid}/model-profiles/#{profile}", %{
        provider_id: provider.provider_id,
        model: "anthropic/claude-opus-4.6"
      })
      |> json_response(403)

      assert {:ok, %{"model" => "openai/gpt-5.4"}} =
               ModelProfiles.get_model_profile(source_agent.uid, "primary")
    end

    for target_uid <- [String.upcase(denied_agent.uid), "  #{String.upcase(denied_agent.uid)}  "] do
      conn
      |> api(:patch, "/api/v2/agents/#{source_agent.uid}/signal-bindings/slack-main", %{
        target_agent_uid: target_uid,
        config: %{}
      })
      |> json_response(403)
    end
  end

  defp from_grants_except(keep_ids) do
    import Ecto.Query, only: [from: 2]
    from(g in Grant, where: g.id not in ^keep_ids)
  end

  test "an operator can reach and archive Sources beyond the first page", %{conn: conn} do
    conn = console_conn(conn)

    ids =
      for index <- 1..101 do
        {:ok, source} =
          Ankole.Ash.create(Source, :register, %{
            upstream_id: "pagination-source-#{index}",
            kind: "oidc_client",
            name: "Source #{index}"
          })

        source.id
      end

    # Equal sort timestamps must not omit or repeat a Source between pages.
    Repo.update_all(Source, set: [updated_at: DateTime.utc_now()])

    first = conn |> api(:get, "/api/v2/brain/sources") |> json_response(200)
    assert length(first["data"]) == 100
    next = URI.parse(first["links"]["next"])
    second = conn |> api(:get, next.path <> "?" <> next.query) |> json_response(200)
    assert [%{"id" => last_id}] = second["data"]
    assert second["links"]["next"] in [nil, ""]
    assert Enum.sort(Enum.map(first["data"] ++ second["data"], & &1["id"])) == Enum.sort(ids)

    conn
    |> api(:post, "/api/v2/brain/sources/#{last_id}/archive", %{})
    |> json_response(201)

    assert Repo.get!(Source, last_id).archived_at
  end

  defp api(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> dispatch(@endpoint, method, path, data && Jason.encode!(%{data: data}))
  end
end
