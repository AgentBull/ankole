defmodule BullXWeb.SetupLLMControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.ActivationCode

  @crypto BullXAIAgent.LLM.Crypto
  @llm_cache BullXAIAgent.LLM.Catalog.Cache
  @llm_catalog BullXAIAgent.LLM.Catalog
  @llm_writer BullXAIAgent.LLM.Writer

  defmodule LLMStub do
    def generate_text(input, opts) do
      send(self(), {:setup_llm_generate_text, input, opts})
      {:ok, "pong"}
    end
  end

  defmodule ErrorLLMStub do
    def generate_text(_input, _opts), do: {:error, %RuntimeError{message: "boom"}}
  end

  setup do
    allow_llm_cache()
    previous_generator = Application.get_env(:bullx, :setup_llm_generate_text)
    Application.put_env(:bullx, :setup_llm_generate_text, {LLMStub, :generate_text})
    refresh_llm_cache()

    on_exit(fn ->
      case previous_generator do
        nil -> Application.delete_env(:bullx, :setup_llm_generate_text)
        value -> Application.put_env(:bullx, :setup_llm_generate_text, value)
      end

      refresh_llm_cache()
    end)

    :ok
  end

  test "GET /setup/llm renders setup/llm SPA with current providers and aliases", %{conn: conn} do
    BullXAIAgent.LLM.register_custom_providers()
    put_default_llm_provider!()

    conn =
      conn
      |> setup_session()
      |> get(~p"/setup/llm")

    response = html_response(conn, 200)

    assert response =~ "setup/llm/App"
    assert response =~ "primary"
    assert response =~ "provider_id_catalog"
    assert response =~ "volcengine_ark"
    assert response =~ "xiaomi_mimo"
  end

  test "POST /setup/llm/providers/check uses a transient resolved provider", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers/check", %{"provider" => provider_payload()})

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert response["result"] == %{"text" => "pong"}
    assert_received {:setup_llm_generate_text, "ping", opts}
    assert Keyword.fetch!(opts, :max_tokens) == 16
    assert %{__struct__: BullXAIAgent.LLM.ResolvedProvider} = Keyword.fetch!(opts, :model)
  end

  test "POST /setup/llm/providers/check passes OpenRouter provider options as req_llm keyword opts",
       %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers/check", %{
        "provider" =>
          provider_payload(%{
            "provider_id" => "openrouter",
            "model_id" => "openai/gpt-5.5",
            "base_url" => "https://openrouter.ai/api/v1",
            "provider_options" => %{
              "openrouter_usage" => %{"include" => true},
              "openrouter_plugins" => [%{"id" => "web"}],
              "openrouter_reasoning" => %{"max_tokens" => 2_000},
              "openrouter_reasoning_effort" => "high"
            }
          })
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert_received {:setup_llm_generate_text, "ping", opts}
    assert %{opts: resolved_opts} = Keyword.fetch!(opts, :model)
    assert Keyword.keyword?(resolved_opts[:provider_options])
    assert resolved_opts[:provider_options][:openrouter_usage] == %{include: true}
    assert resolved_opts[:provider_options][:openrouter_plugins] == [%{id: "web"}]
    assert resolved_opts[:provider_options][:openrouter_reasoning] == %{max_tokens: 2_000}
    assert resolved_opts[:provider_options][:openrouter_reasoning_effort] == :high
  end

  test "POST /setup/llm/providers/check reuses stored api_key for existing OpenRouter provider",
       %{conn: conn} do
    BullXAIAgent.LLM.register_custom_providers()

    assert {:ok, _provider} =
             apply(@llm_writer, :put_provider, [
               %{
                 name: "primary",
                 provider_id: "openrouter",
                 model_id: "openai/gpt-5.5",
                 api_key: "sk-stored",
                 base_url: "https://openrouter.ai/api/v1",
                 provider_options: %{"openrouter_usage" => %{"include" => true}}
               }
             ])

    payload =
      provider_payload(%{
        "provider_id" => "openrouter",
        "model_id" => "openai/gpt-5.5",
        "base_url" => "https://openrouter.ai/api/v1",
        "provider_options" => %{"openrouter_usage" => %{"include" => true}}
      })
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers/check", %{"provider" => payload})

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert_received {:setup_llm_generate_text, "ping", opts}
    assert %{opts: resolved_opts} = Keyword.fetch!(opts, :model)
    assert resolved_opts[:api_key] == "sk-stored"
    assert resolved_opts[:provider_options][:openrouter_usage] == %{include: true}
  end

  test "POST /setup/llm/providers/check serializes generator struct errors", %{conn: conn} do
    Application.put_env(:bullx, :setup_llm_generate_text, {ErrorLLMStub, :generate_text})

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers/check", %{"provider" => provider_payload()})

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "unknown", "message" => message, "details" => %{}}] = response["errors"]
    assert message =~ "%RuntimeError{message: \"boom\"}"
  end

  test "POST /setup/llm/providers/check rejects invalid attrs before generation", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers/check", %{
        "provider" => Map.delete(provider_payload(), "model_id")
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"} | _] = response["errors"]
    refute_received {:setup_llm_generate_text, _input, _opts}
  end

  test "POST /setup/llm/providers persists providers and default alias", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload()],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert response["redirect_to"] == "/setup/gateway"

    assert {:ok, provider} = apply(@llm_catalog, :find_provider, ["primary"])

    assert {:ok, "sk-test"} =
             apply(@crypto, :decrypt_api_key, [
               Map.fetch!(provider, :encrypted_api_key),
               Map.fetch!(provider, :id)
             ])
  end

  test "POST /setup/llm/providers fills blank endpoint name from provider and model", %{
    conn: conn
  } do
    default_name = "openai/gpt-4o-mini"

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload(%{"name" => ""})],
        "alias_bindings" => default_alias_payload(default_name)
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert {:ok, provider} = apply(@llm_catalog, :find_provider, [default_name])
    assert provider.name == default_name
  end

  test "POST /setup/llm/providers renames existing provider by id instead of duplicating it", %{
    conn: conn
  } do
    put_default_llm_provider!()
    assert {:ok, existing} = apply(@llm_catalog, :find_provider, ["primary"])

    payload =
      provider_payload(%{"id" => existing.id, "name" => "renamed"})
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [payload],
        "alias_bindings" => default_alias_payload("renamed")
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert apply(@llm_catalog, :find_provider, ["primary"]) == {:error, :not_found}
    assert {:ok, provider} = apply(@llm_catalog, :find_provider, ["renamed"])
    assert provider.id == existing.id

    assert {:ok, "sk-test"} =
             apply(@crypto, :decrypt_api_key, [
               Map.fetch!(provider, :encrypted_api_key),
               Map.fetch!(provider, :id)
             ])

    assert apply(@llm_catalog, :list_providers, []) |> length() == 1
    assert apply(@llm_catalog, :list_alias_bindings, [])[:default] == {:provider, "renamed"}
  end

  test "POST /setup/llm/providers deletes providers omitted from submitted setup list", %{
    conn: conn
  } do
    put_default_llm_provider!()

    assert {:ok, _secondary} =
             apply(@llm_writer, :put_provider, [
               provider_attrs(%{name: "secondary", model_id: "gpt-4o"})
             ])

    assert {:ok, primary} = apply(@llm_catalog, :find_provider, ["primary"])

    payload =
      provider_payload(%{"id" => primary.id})
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [payload],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert {:ok, _primary} = apply(@llm_catalog, :find_provider, ["primary"])
    assert apply(@llm_catalog, :find_provider, ["secondary"]) == {:error, :not_found}
    assert apply(@llm_catalog, :list_providers, []) |> length() == 1
  end

  test "POST /setup/llm/providers persists non-default alias targets", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [
          provider_payload(),
          provider_payload(%{"name" => "fast", "model_id" => "gpt-4o"})
        ],
        "alias_bindings" => %{
          "default" => %{"kind" => "provider", "target" => "primary"},
          "fast" => %{"kind" => "provider", "target" => "fast"},
          "heavy" => %{"kind" => "alias", "target" => "default"},
          "compression" => %{"kind" => "alias", "target" => "default"}
        }
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert apply(@llm_catalog, :list_alias_bindings, [])[:heavy] == {:alias, :default}
    assert apply(@llm_catalog, :list_alias_bindings, [])[:compression] == {:alias, :default}

    assert apply(@llm_catalog, :resolve_alias, [:compression]) ==
             apply(@llm_catalog, :resolve_alias, [:default])
  end

  test "POST /setup/llm/providers rejects alias cycles before writes", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload()],
        "alias_bindings" => %{
          "default" => %{"kind" => "provider", "target" => "primary"},
          "fast" => %{"kind" => "alias", "target" => "compression"},
          "heavy" => %{"kind" => "alias", "target" => "default"},
          "compression" => %{"kind" => "alias", "target" => "fast"}
        }
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"message" => message} | _] = response["errors"]
    assert message =~ "model alias cycle"
    assert apply(@llm_catalog, :list_providers, []) == []
  end

  test "POST /setup/llm/providers rejects incomplete providers before writes", %{conn: conn} do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [Map.delete(provider_payload(), "model_id")],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"} | _] = response["errors"]
    assert apply(@llm_catalog, :list_providers, []) == []
  end

  test "POST /setup/llm/providers rejects vendor-specific options outside the provider schema", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [
          provider_payload(%{"provider_options" => %{"unknown_option" => true}})
        ],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config", "details" => %{"field" => field}} | _] = response["errors"]
    assert field == "providers[0].provider_options.unknown_option"
    assert apply(@llm_catalog, :list_providers, []) == []
  end

  test "POST /setup/llm/providers rejects payload without default binding before writes", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload()],
        "alias_bindings" => %{"fast" => %{"kind" => "provider", "target" => "primary"}}
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"} | _] = response["errors"]
    assert apply(@llm_catalog, :list_providers, []) == []
  end

  test "POST /setup/llm/providers rejects default binding to missing provider before writes", %{
    conn: conn
  } do
    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload()],
        "alias_bindings" => default_alias_payload("missing")
      })

    response = json_response(conn, 422)

    assert response["ok"] == false
    assert [%{"kind" => "config"} | _] = response["errors"]
    assert apply(@llm_catalog, :list_providers, []) == []
  end

  test "POST /setup/llm/providers inherits api_key from a previously saved provider", %{
    conn: conn
  } do
    put_default_llm_provider!()
    assert {:ok, source} = apply(@llm_catalog, :find_provider, ["primary"])

    inherited =
      provider_payload(%{
        "name" => "primary-gpt-4o",
        "model_id" => "gpt-4o",
        "api_key_inherits_from" => "primary"
      })
      |> Map.delete("api_key")

    keep_source =
      provider_payload(%{"id" => source.id})
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [keep_source, inherited],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert {:ok, copy} = apply(@llm_catalog, :find_provider, ["primary-gpt-4o"])

    assert {:ok, "sk-test"} =
             apply(@crypto, :decrypt_api_key, [
               Map.fetch!(copy, :encrypted_api_key),
               Map.fetch!(copy, :id)
             ])

    assert copy.id != source.id
  end

  test "POST /setup/llm/providers inherits api_key from a freshly typed in-batch source", %{
    conn: conn
  } do
    inherited =
      provider_payload(%{
        "name" => "primary-gpt-4o",
        "model_id" => "gpt-4o",
        "api_key_inherits_from" => "primary"
      })
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [provider_payload(), inherited],
        "alias_bindings" => default_alias_payload("primary")
      })

    response = json_response(conn, 200)

    assert response["ok"] == true
    assert {:ok, copy} = apply(@llm_catalog, :find_provider, ["primary-gpt-4o"])

    assert {:ok, "sk-test"} =
             apply(@crypto, :decrypt_api_key, [
               Map.fetch!(copy, :encrypted_api_key),
               Map.fetch!(copy, :id)
             ])
  end

  test "POST /setup/llm/providers rejects inherit from an unknown source", %{conn: conn} do
    inherited =
      provider_payload(%{
        "name" => "primary-gpt-4o",
        "model_id" => "gpt-4o",
        "api_key_inherits_from" => "missing"
      })
      |> Map.delete("api_key")

    conn =
      conn
      |> setup_session()
      |> post(~p"/setup/llm/providers", %{
        "providers" => [inherited],
        "alias_bindings" => default_alias_payload("primary-gpt-4o")
      })

    response = json_response(conn, 422)

    assert response["ok"] == false

    assert [%{"kind" => "config", "details" => %{"field" => "api_key_inherits_from"}} | _] =
             response["errors"]

    assert apply(@llm_catalog, :find_provider, ["primary-gpt-4o"]) == {:error, :not_found}
  end

  defp setup_session(conn) do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    {:ok, code_hash} = BullXAccounts.verify_bootstrap_activation_code(plaintext)
    init_test_session(conn, %{bootstrap_activation_code_hash: code_hash})
  end

  defp put_default_llm_provider! do
    {:ok, _provider} = apply(@llm_writer, :put_provider, [provider_attrs()])
    {:ok, _binding} = apply(@llm_writer, :put_alias_binding, [:default, {:provider, "primary"}])
  end

  defp provider_payload(attrs \\ %{}) do
    Map.merge(
      %{
        "name" => "primary",
        "provider_id" => "openai",
        "model_id" => "gpt-4o-mini",
        "api_key" => "sk-test",
        "base_url" => "https://api.openai.com/v1",
        "provider_options" => %{"service_tier" => "default"}
      },
      attrs
    )
  end

  defp provider_attrs(attrs \\ %{}) do
    Map.merge(
      %{
        name: "primary",
        provider_id: "openai",
        model_id: "gpt-4o-mini",
        api_key: "sk-test",
        base_url: "https://api.openai.com/v1",
        provider_options: %{"service_tier" => "default"}
      },
      attrs
    )
  end

  defp default_alias_payload(provider_name) do
    %{
      "default" => %{"kind" => "provider", "target" => provider_name},
      "fast" => nil,
      "heavy" => nil,
      "compression" => nil
    }
  end

  defp allow_llm_cache do
    case Process.whereis(@llm_cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end

  defp refresh_llm_cache do
    case function_exported?(@llm_cache, :refresh_all, 0) do
      true -> apply(@llm_cache, :refresh_all, [])
      false -> :ok
    end
  end
end
