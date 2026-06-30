if Mix.env() == :test do
  # `mix run` does not go through DataCase, so the SQL sandbox would otherwise
  # reject Repo calls made by this standalone runner in MIX_ENV=test.
  Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :auto)
end

defmodule Ankole.Tools.AIGatewayRealProviderE2E do
  @moduledoc """
  Runs manual AIGateway smoke checks against real upstream providers.

  The normal ExUnit suite uses fake HTTP clients so it can stay deterministic
  and cheap. This runner is for the edge that fake clients cannot prove: real
  provider authentication, wire-format compatibility, SSE conversion, and vector
  response normalization.

  Usage:

      MIX_ENV=test OPEN_ROUTER_API_KEY=... mix e2e.ai_gateway_real_provider
      MIX_ENV=test OPEN_ROUTER_API_KEY=... mix e2e.ai_gateway_real_provider -- --providers=openrouter
      MIX_ENV=test mix run tools/e2e/ai_gateway_real_provider_e2e.exs -- --list

  Provider names are `openrouter`, `jina`, `google`, `claude_openrouter`, and
  `claude_direct`.
  Use `--providers=available` to run the groups whose required API keys are
  present in the environment.
  """

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint AnkoleWeb.Endpoint
  @provider_names [:openrouter, :jina, :google, :claude_openrouter, :claude_direct]
  @results_path Path.expand("../../tmp/ai_gateway_real_provider_e2e_results.jsonl", __DIR__)
  @concurrency_timeout_ms 90_000

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Principals
  alias AnkoleWeb.AIGatewayTokens

  def run(argv \\ System.argv()) do
    argv = normalize_argv(argv)

    cond do
      "--help" in argv ->
        print_help()

      "--list" in argv ->
        list_cases()

      true ->
        providers = selected_providers!(argv)
        credentials = credentials_for!(providers)

        File.mkdir_p!(Path.dirname(@results_path))
        File.rm(@results_path)

        setup = setup_runtime(providers, credentials)
        image = deterministic_image_data_url()
        cases = cases(setup, image)

        require!(cases != [], "no real-provider cases selected")

        results = Enum.map(cases, fn {name, fun} -> run_case(name, fun, credentials) end)
        summarize(results)
    end
  end

  defp print_help do
    IO.puts("""
    Runs AIGateway real-provider smoke checks.

    Options:
      --list                       Prints case names without reading credentials.
      --providers=a,b              Runs selected provider groups.
      --providers=available        Runs provider groups whose API keys are present.

    Environment:
      OPENROUTER_API_KEY or OPEN_ROUTER_API_KEY   OpenRouter and Claude-through-OpenRouter
      AI_GATEWAY_E2E_OPENROUTER_MODEL             OpenRouter LLM model override
      AI_GATEWAY_E2E_OPENROUTER_EMBEDDING_MODEL   OpenRouter embedding model override
      AI_GATEWAY_E2E_OPENROUTER_RERANK_MODEL      OpenRouter rerank model override
      AI_GATEWAY_E2E_OPENROUTER_CLAUDE_MODEL      OpenRouter Claude Messages model override
      JINA_API_KEY                                Jina embeddings and rerank
      GOOGLE_AI_STUDIO_API_KEY                    Google AI Studio OpenAI-compatible API
      ANTHROPIC_AUTH_TOKEN                        Claude-compatible direct auth token
      ANTHROPIC_BASE_URL                          Claude-compatible direct base URL
      AI_GATEWAY_E2E_CLAUDE_MODEL                 Claude-compatible direct model override
      AI_GATEWAY_E2E_CONCURRENCY                  Concurrent case max concurrency, default 6
    """)
  end

  defp list_cases do
    fake_setup =
      @provider_names
      |> Enum.reduce(%{}, fn provider, setup -> Map.merge(setup, fake_setup(provider)) end)

    fake_setup
    |> cases(%{data_url: "data:image/png;base64,", source: "list-only", bytes: 0})
    |> Enum.each(fn {name, _fun} -> IO.puts(name) end)
  end

  defp selected_providers!(argv) do
    case Enum.find(argv, &String.starts_with?(&1, "--providers=")) do
      nil ->
        @provider_names

      "--providers=available" ->
        available_providers()

      "--providers=" <> csv ->
        csv
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&provider_name!/1)
    end
  end

  defp provider_name!("openrouter"), do: :openrouter
  defp provider_name!("jina"), do: :jina
  defp provider_name!("google"), do: :google
  defp provider_name!("claude_openrouter"), do: :claude_openrouter
  defp provider_name!("claude_direct"), do: :claude_direct

  defp provider_name!(name) do
    raise "unknown provider group #{inspect(name)}; expected #{Enum.join(@provider_names, ", ")}"
  end

  defp available_providers do
    Enum.filter(@provider_names, fn provider ->
      provider
      |> credential_env_names()
      |> Enum.any?(&(System.get_env(&1) not in [nil, ""]))
    end)
  end

  defp credentials_for!(providers) do
    Map.new(providers, fn provider ->
      {provider, required_env(credential_env_names(provider), provider)}
    end)
  end

  defp credential_env_names(:openrouter), do: ["OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"]
  defp credential_env_names(:claude_openrouter), do: ["OPENROUTER_API_KEY", "OPEN_ROUTER_API_KEY"]
  defp credential_env_names(:claude_direct), do: ["ANTHROPIC_AUTH_TOKEN"]
  defp credential_env_names(:jina), do: ["JINA_API_KEY"]
  defp credential_env_names(:google), do: ["GOOGLE_AI_STUDIO_API_KEY"]

  defp setup_runtime(providers, credentials) do
    suffix = unique_suffix()

    providers
    |> Enum.reduce(%{suffix: suffix}, fn
      :openrouter, setup -> setup_openrouter(setup, credentials.openrouter)
      :jina, setup -> setup_jina(setup, credentials.jina)
      :google, setup -> setup_google(setup, credentials.google)
      :claude_openrouter, setup -> setup_claude_openrouter(setup, credentials.claude_openrouter)
      :claude_direct, setup -> setup_claude_direct(setup, credentials.claude_direct)
    end)
  end

  defp setup_openrouter(%{suffix: suffix} = setup, credential) do
    provider_id = "e2e-openrouter-#{suffix}"
    llm_model = System.get_env("AI_GATEWAY_E2E_OPENROUTER_MODEL") || "openai/gpt-5.4-nano"

    embedding_model =
      System.get_env("AI_GATEWAY_E2E_OPENROUTER_EMBEDDING_MODEL") ||
        "perplexity/pplx-embed-v1-0.6b"

    rerank_model =
      System.get_env("AI_GATEWAY_E2E_OPENROUTER_RERANK_MODEL") ||
        "nvidia/llama-nemotron-rerank-vl-1b-v2:free"

    create_provider!(%{
      provider_id: provider_id,
      provider_kind: "openrouter",
      base_url: "https://openrouter.ai/api/v1",
      connection_options: %{"api_key" => credential}
    })

    agent =
      create_agent!(
        "e2e-openrouter-agent-#{suffix}",
        %{
          "ai_agent" => %{
            "models" => %{
              "embedding" => %{
                "provider_id" => provider_id,
                "model" => embedding_model
              },
              "rerank" => %{
                "provider_id" => provider_id,
                "model" => rerank_model
              }
            }
          }
        }
      )

    put_profile!(agent.uid, "primary", %{
      provider_id: provider_id,
      model: llm_model
    })

    setup
    |> Map.put(:openrouter_provider, provider_id)
    |> Map.put(:openrouter_agent, agent)
    |> Map.put(:openrouter_llm_model, llm_model)
    |> Map.put(:openrouter_embedding_model, embedding_model)
    |> Map.put(:openrouter_rerank_model, rerank_model)
  end

  defp setup_jina(%{suffix: suffix} = setup, credential) do
    provider_id = "e2e-jina-#{suffix}"

    create_provider!(%{
      provider_id: provider_id,
      provider_kind: "jina",
      base_url: "https://api.jina.ai/v1",
      # Product defaults still prefer native HTTP/2 transport for first-class
      # providers. This live smoke row pins Jina to HTTP/1 because Jina's edge
      # has historically been more predictable over HTTP/1.1 for this probe.
      connection_options: %{
        "api_key" => credential,
        "transport" => %{"http_versions" => ["h1"], "compression" => ["zstd", "br", "gzip"]}
      }
    })

    agent =
      create_agent!(
        "e2e-jina-agent-#{suffix}",
        %{
          "ai_agent" => %{
            "models" => %{
              "embedding" => %{
                "provider_id" => provider_id,
                "model" => "jina-embeddings-v5-text-nano"
              },
              "rerank" => %{
                "provider_id" => provider_id,
                "model" => "jina-reranker-v3"
              }
            }
          }
        }
      )

    Map.put(setup, :jina_agent, agent)
  end

  defp setup_google(%{suffix: suffix} = setup, credential) do
    provider_id = "e2e-google-ai-studio-#{suffix}"

    create_provider!(%{
      provider_id: provider_id,
      provider_kind: "google_ai_studio_openai",
      base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
      connection_options: %{"api_key" => credential}
    })

    agent = create_agent!("e2e-google-agent-#{suffix}", %{})

    put_profile!(agent.uid, "primary", %{
      provider_id: provider_id,
      model: "gemini-3.1-flash-lite"
    })

    Map.put(setup, :google_agent, agent)
  end

  defp setup_claude_openrouter(%{suffix: suffix} = setup, credential) do
    provider_id = "e2e-claude-openrouter-#{suffix}"

    model =
      System.get_env("AI_GATEWAY_E2E_OPENROUTER_CLAUDE_MODEL") ||
        "anthropic/claude-sonnet-4.5"

    create_provider!(%{
      provider_id: provider_id,
      provider_kind: "claude",
      base_url: "https://openrouter.ai/api/v1",
      connection_options: %{
        "api_key" => credential,
        "auth_mode" => "auth_token",
        "messages_path" => "messages"
      }
    })

    agent = create_agent!("e2e-claude-openrouter-agent-#{suffix}", %{})

    put_profile!(agent.uid, "primary", %{
      provider_id: provider_id,
      model: model
    })

    setup
    |> Map.put(:claude_openrouter_agent, agent)
    |> Map.put(:claude_openrouter_model, model)
  end

  defp setup_claude_direct(%{suffix: suffix} = setup, credential) do
    provider_id = "e2e-claude-direct-#{suffix}"
    base_url = System.get_env("ANTHROPIC_BASE_URL") || "https://api.anthropic.com"
    model = System.get_env("AI_GATEWAY_E2E_CLAUDE_MODEL") || "claude-haiku-4-5-20251001"

    create_provider!(%{
      provider_id: provider_id,
      provider_kind: "claude",
      base_url: base_url,
      connection_options: %{
        "api_key" => credential,
        "auth_mode" => "auth_token",
        "messages_path" => System.get_env("ANTHROPIC_MESSAGES_PATH") || "v1/messages"
      }
    })

    agent = create_agent!("e2e-claude-direct-agent-#{suffix}", %{})

    put_profile!(agent.uid, "primary", %{
      provider_id: provider_id,
      model: model
    })

    setup
    |> Map.put(:claude_direct_agent, agent)
    |> Map.put(:claude_direct_model, model)
  end

  defp fake_setup(:openrouter) do
    %{
      openrouter_provider: "fake-openrouter",
      openrouter_agent: %{uid: "fake-openrouter-agent"},
      openrouter_llm_model: "fake-openrouter-model",
      openrouter_embedding_model: "fake-openrouter-embedding-model",
      openrouter_rerank_model: "fake-openrouter-rerank-model"
    }
  end

  defp fake_setup(:jina), do: %{jina_agent: %{uid: "fake-jina-agent"}}
  defp fake_setup(:google), do: %{google_agent: %{uid: "fake-google-agent"}}
  defp fake_setup(:claude_openrouter), do: %{claude_openrouter_agent: %{uid: "fake-claude-agent"}}
  defp fake_setup(:claude_direct), do: %{claude_direct_agent: %{uid: "fake-claude-direct-agent"}}

  defp cases(setup, image) do
    []
    |> add_openrouter_cases(setup, image)
    |> add_jina_cases(setup)
    |> add_google_cases(setup, image)
    |> add_claude_openrouter_cases(setup)
    |> add_claude_direct_cases(setup)
    |> Enum.reverse()
  end

  defp add_openrouter_cases(
         cases,
         %{
           openrouter_agent: agent,
           openrouter_provider: provider,
           openrouter_llm_model: llm_model,
           openrouter_embedding_model: embedding_model,
           openrouter_rerank_model: rerank_model
         },
         image
       ) do
    [
      {"openrouter.models_http_agent_catalog", fn -> case_models_http(agent) end},
      {"openrouter.llm_alias_direct_text", fn -> case_llm_direct(agent, "primary") end},
      {"openrouter.llm_explicit_direct_text",
       fn -> case_llm_direct(agent, "#{provider}/#{llm_model}") end},
      {"openrouter.llm_http_json", fn -> case_llm_http_json(agent) end},
      {"openrouter.llm_structured_json", fn -> case_llm_structured_json(agent) end},
      {"openrouter.llm_http_sse", fn -> case_llm_http_sse(agent) end},
      {"openrouter.llm_function_call", fn -> case_llm_function_call(agent) end},
      {"openrouter.llm_multimodal", fn -> case_llm_multimodal(agent, "primary", image) end},
      {"openrouter.embedding_batch",
       fn ->
         case_embedding(agent, "embedding.default", [
           "Ankole gateway test query",
           "Ankole gateway test passage"
         ])
       end},
      {"openrouter.embedding_multimodal",
       fn -> case_embedding_multimodal(agent, "embedding.default", image) end},
      {"openrouter.rerank_text_structured", fn -> case_rerank(agent, "rerank.default", true) end},
      {"openrouter.concurrent_multi_agent_mixed",
       fn ->
         case_openrouter_concurrent_multi_agent(
           provider,
           llm_model,
           embedding_model,
           rerank_model
         )
       end},
      {"openrouter.chaos_mixed_success_and_expected_failures",
       fn ->
         case_openrouter_chaos_mixed(provider, llm_model, embedding_model, rerank_model, image)
       end}
      | cases
    ]
  end

  defp add_openrouter_cases(cases, _setup, _image), do: cases

  defp add_jina_cases(cases, %{jina_agent: agent}) do
    [
      {"jina.embedding_batch_dimensions",
       fn ->
         case_embedding(
           agent,
           "embedding.default",
           ["search query: durable actor runtime", "passage: runtime fabric uses zeromq"],
           %{"dimensions" => 128, "embedding_type" => "float", "task" => "retrieval.query"}
         )
       end},
      {"jina.rerank_return_documents_true", fn -> case_rerank(agent, "rerank.default", true) end},
      {"jina.rerank_return_documents_false",
       fn -> case_rerank(agent, "rerank.default", false) end}
      | cases
    ]
  end

  defp add_jina_cases(cases, _setup), do: cases

  defp add_google_cases(cases, %{google_agent: agent}, image) do
    [
      {"google_ai_studio.llm_text", fn -> case_llm_direct(agent, "primary") end},
      {"google_ai_studio.llm_multimodal", fn -> case_llm_multimodal(agent, "primary", image) end},
      {"google_ai_studio.concurrent_llm_text", fn -> case_google_concurrent_llm(agent) end}
      | cases
    ]
  end

  defp add_google_cases(cases, _setup, _image), do: cases

  defp add_claude_openrouter_cases(cases, %{claude_openrouter_agent: agent}) do
    [
      {"claude_openrouter.messages_text", fn -> case_llm_direct(agent, "primary") end},
      {"claude_openrouter.messages_sse", fn -> case_llm_http_sse(agent) end}
      | cases
    ]
  end

  defp add_claude_openrouter_cases(cases, _setup), do: cases

  defp add_claude_direct_cases(cases, %{claude_direct_agent: agent}) do
    [
      {"claude_direct.messages_text", fn -> case_llm_direct(agent, "primary") end},
      {"claude_direct.messages_sse", fn -> case_llm_http_sse(agent) end}
      | cases
    ]
  end

  defp add_claude_direct_cases(cases, _setup), do: cases

  defp case_models_http(agent) do
    conn =
      agent.uid
      |> mint_agent_token!()
      |> authed_conn()
      |> get("/api/v1/ai-gateway/models")

    body = json_response!(conn, 200)
    data = Map.fetch!(body, "data")

    require!(Enum.any?(data, &(&1["id"] == "primary")), "models missing primary selector")

    require!(
      Enum.any?(data, &(&1["id"] == "embedding.default")),
      "models missing embedding.default"
    )

    require!(Enum.any?(data, &(&1["id"] == "rerank.default")), "models missing rerank.default")

    %{count: length(data), selectors: Enum.map(data, & &1["id"])}
  end

  defp case_llm_direct(agent, model) do
    {:ok, response} =
      AIGateway.create_response(agent.uid, %{
        "model" => model,
        "input" => "Reply with exactly these two words: ankole gateway",
        "max_output_tokens" => 32,
        "temperature" => 0
      })

    summarize_llm_response(response.body)
  end

  defp case_llm_http_json(agent) do
    conn =
      agent.uid
      |> mint_agent_token!()
      |> authed_conn()
      |> post("/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "Reply with one short sentence about stateless gateways.",
        "stream" => false,
        "max_output_tokens" => 40
      })

    conn
    |> json_response!(200)
    |> summarize_llm_response()
  end

  defp case_llm_structured_json(agent) do
    {:ok, response} =
      AIGateway.create_response(agent.uid, %{
        "model" => "primary",
        "input" =>
          "Return JSON for this object only: gateway=ankole, transport=sse, stable=true.",
        "max_output_tokens" => 120,
        "temperature" => 0,
        "response_format" => %{
          "type" => "json_schema",
          "json_schema" => %{
            "name" => "ankole_gateway_check",
            "strict" => true,
            "schema" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["gateway", "transport", "stable"],
              "properties" => %{
                "gateway" => %{"type" => "string"},
                "transport" => %{"type" => "string"},
                "stable" => %{"type" => "boolean"}
              }
            }
          }
        }
      })

    response.body
    |> output_text()
    |> String.trim()
    |> Ankole.JSON.decode()
    |> case do
      {:ok, parsed} ->
        require!(parsed["gateway"] == "ankole", "structured JSON gateway mismatch")
        require!(parsed["transport"] == "sse", "structured JSON transport mismatch")
        require!(parsed["stable"] == true, "structured JSON stable mismatch")

        response.body
        |> summarize_llm_response()
        |> Map.put(:json_keys, parsed |> Map.keys() |> Enum.sort())

      {:error, reason} ->
        raise "structured JSON parse failed: #{inspect(reason)}"
    end
  end

  defp case_llm_http_sse(agent) do
    conn =
      agent.uid
      |> mint_agent_token!()
      |> authed_conn()
      |> post("/api/v1/ai-gateway/responses", %{
        "model" => "primary",
        "input" => "Reply with exactly: streaming ok",
        "stream" => true,
        "max_output_tokens" => 32
      })

    response = response(conn, 200)

    require!(
      get_resp_header(conn, "content-type") == ["text/event-stream"],
      "missing SSE content type"
    )

    require!(String.contains?(response, "data: [DONE]"), "missing SSE DONE sentinel")

    events = decode_sse_events(response)
    require!(length(events) >= 2, "SSE event count too low")

    require!(
      List.last(events)["type"] in [
        "response.completed",
        "response.failed",
        "response.incomplete"
      ],
      "missing terminal response event"
    )

    Enum.each(events, fn event -> require!(event["type"] != nil, "SSE event missing type") end)

    %{event_count: length(events), events: Enum.map(events, & &1["type"])}
  end

  defp case_llm_function_call(agent) do
    {:ok, response} =
      AIGateway.create_response(agent.uid, %{
        "model" => "primary",
        "input" => "Use the tool to look up the weather for Shanghai.",
        "extra_body" => %{"enable_thinking" => false},
        "max_output_tokens" => 120,
        "temperature" => 0,
        "tools" => [
          %{
            "type" => "function",
            "name" => "get_weather",
            "description" => "Gets current weather for one city.",
            "parameters" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => ["city"],
              "properties" => %{"city" => %{"type" => "string"}}
            },
            "strict" => true
          }
        ],
        "tool_choice" => "auto"
      })

    call =
      response.body
      |> Map.fetch!("output")
      |> Enum.find(&(&1["type"] == "function_call"))

    require!(is_map(call), "function_call output item missing")
    require!(call["name"] == "get_weather", "function_call name mismatch")

    arguments = Ankole.JSON.decode!(call["arguments"] || "{}")

    require!(
      String.downcase(to_string(arguments["city"])) =~ "shanghai",
      "function_call arguments missing Shanghai"
    )

    %{
      id: response.body["id"],
      model: response.body["model"],
      status: response.body["status"],
      function_name: call["name"],
      argument_keys: arguments |> Map.keys() |> Enum.sort()
    }
  end

  defp case_llm_multimodal(agent, model, image) do
    {:ok, response} =
      AIGateway.create_response(agent.uid, %{
        "model" => model,
        "input" => [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [
              %{"type" => "input_text", "text" => "Describe this image in five words or fewer."},
              %{"type" => "input_image", "image_url" => image.data_url}
            ]
          }
        ],
        "max_output_tokens" => 40
      })

    response.body
    |> summarize_llm_response()
    |> Map.put(:image_source, image.source)
    |> Map.put(:image_bytes, image.bytes)
  end

  defp case_embedding(agent, model, input, extra \\ %{}) do
    request = Map.merge(%{"model" => model, "input" => input}, extra)
    {:ok, response} = AIGateway.create_embeddings(agent.uid, request)
    data = Map.fetch!(response.body, "data")
    require!(length(data) >= 1, "embedding data is empty")

    dimensions =
      data
      |> hd()
      |> Map.fetch!("embedding")
      |> embedding_dimensions()

    require!(dimensions > 0, "embedding dimensions missing")
    %{count: length(data), dimensions: dimensions, model: response.body["model"]}
  end

  defp case_embedding_multimodal(agent, model, image) do
    request = %{
      "model" => model,
      "input" => [
        %{
          "content" => [
            %{"type" => "text", "text" => "A local test image for embedding."},
            %{"type" => "image_url", "image_url" => %{"url" => image.data_url}}
          ]
        }
      ],
      "encoding_format" => "float"
    }

    case AIGateway.create_embeddings(agent.uid, request) do
      {:ok, response} ->
        data = Map.fetch!(response.body, "data")
        require!(length(data) >= 1, "multimodal embedding data is empty")

        dimensions =
          data
          |> hd()
          |> Map.fetch!("embedding")
          |> embedding_dimensions()

        require!(dimensions > 0, "multimodal embedding dimensions missing")

        %{
          outcome: "embedded",
          count: length(data),
          dimensions: dimensions,
          image_bytes: image.bytes,
          image_source: image.source,
          model: response.body["model"]
        }

      {:error, {:upstream_response_failed, status, body}} ->
        message = get_in(body, ["error", "message"]) || inspect(body["error"])

        require!(
          status in 400..499 and String.contains?(String.downcase(message), "image"),
          "unexpected multimodal embedding rejection status=#{status} message=#{message}"
        )

        %{
          outcome: "provider_rejected_unsupported_image_input",
          image_bytes: image.bytes,
          image_source: image.source,
          message: message,
          status: status
        }
    end
  end

  defp case_rerank(agent, model, return_documents?) do
    {:ok, response} =
      AIGateway.create_rerank(agent.uid, %{
        "model" => model,
        "query" => "Which document is about Paris?",
        "documents" => [
          "Paris is the capital of France.",
          %{"text" => "Berlin is the capital of Germany."},
          "The Pacific Ocean is very large."
        ],
        "top_n" => 2,
        "return_documents" => return_documents?
      })

    results = Map.fetch!(response.body, "results")
    require!(length(results) >= 1, "rerank results empty")

    Enum.each(results, fn result ->
      require!(is_integer(result["index"]), "rerank result missing index")
      require!(is_number(result["relevance_score"]), "rerank result missing score")
      require!(is_map(result["document"]), "rerank result missing normalized document")
    end)

    %{count: length(results), model: response.body["model"], top_index: hd(results)["index"]}
  end

  defp case_openrouter_concurrent_multi_agent(provider, llm_model, embedding_model, rerank_model) do
    suffix = unique_suffix()

    agents =
      for index <- 1..4 do
        agent = create_agent!("e2e-openrouter-concurrent-#{suffix}-#{index}", %{})

        put_profile!(agent.uid, "primary", %{provider_id: provider, model: llm_model})
        put_profile!(agent.uid, "embedding", %{provider_id: provider, model: embedding_model})
        put_profile!(agent.uid, "rerank", %{provider_id: provider, model: rerank_model})

        {index, agent}
      end

    jobs =
      agents
      |> Enum.flat_map(fn {index, agent} ->
        [
          {"agent#{index}.llm_json", fn -> case_llm_direct(agent, "primary") end},
          {"agent#{index}.llm_sse", fn -> case_llm_http_sse(agent) end}
        ]
      end)
      |> Kernel.++([
        {"embedding.batch",
         fn ->
           {_index, agent} = hd(agents)
           case_embedding(agent, "embedding.default", ["concurrent query", "concurrent passage"])
         end},
        {"rerank.structured",
         fn ->
           {_index, agent} = List.last(agents)
           case_rerank(agent, "rerank.default", true)
         end}
      ])

    summarize_concurrent_results(run_concurrent!(jobs))
  end

  defp case_openrouter_chaos_mixed(provider, llm_model, embedding_model, rerank_model, image) do
    suffix = unique_suffix()
    agent = create_agent!("e2e-openrouter-chaos-#{suffix}", %{})

    put_profile!(agent.uid, "primary", %{provider_id: provider, model: llm_model})
    put_profile!(agent.uid, "embedding", %{provider_id: provider, model: embedding_model})
    put_profile!(agent.uid, "rerank", %{provider_id: provider, model: rerank_model})

    invalid_model = "#{provider}/ankole-invalid-model-#{suffix}"

    jobs = [
      {"good.llm_json", fn -> case_llm_direct(agent, "primary") end},
      {"good.llm_sse", fn -> case_llm_http_sse(agent) end},
      {"good.embedding",
       fn -> case_embedding(agent, "embedding.default", ["chaos query", "chaos passage"]) end},
      {"good.rerank", fn -> case_rerank(agent, "rerank.default", true) end},
      {"expected_failure.invalid_model",
       fn ->
         expect_upstream_failure(fn ->
           AIGateway.create_response(agent.uid, %{
             "model" => invalid_model,
             "input" => "This request should fail at the provider.",
             "max_output_tokens" => 16,
             "temperature" => 0
           })
         end)
       end},
      {"expected_failure.embedding_image_or_provider_support",
       fn ->
         case_embedding_multimodal(agent, "embedding.default", image)
       end}
    ]

    results = run_concurrent!(jobs)

    results
    |> summarize_concurrent_results()
    |> Map.put(:expected_failure_count, expected_failure_count(results))
  end

  defp case_google_concurrent_llm(agent) do
    jobs =
      for index <- 1..4 do
        {"google.llm_text.#{index}", fn -> case_llm_direct(agent, "primary") end}
      end

    summarize_concurrent_results(
      run_concurrent!(jobs, max_concurrency: min(4, concurrency_limit()))
    )
  end

  defp run_concurrent!(jobs, opts \\ []) do
    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, concurrency_limit())
      |> min(length(jobs))

    jobs
    |> Task.async_stream(
      fn {label, fun} ->
        started_at = System.monotonic_time(:millisecond)

        try do
          summary = fun.()
          {:ok, label, elapsed_ms(started_at), summary}
        rescue
          exception ->
            {:error, label, elapsed_ms(started_at),
             Exception.format(:error, exception, __STACKTRACE__)}
        catch
          kind, reason ->
            {:error, label, elapsed_ms(started_at), "#{inspect(kind)} #{inspect(reason)}"}
        end
      end,
      max_concurrency: max_concurrency,
      on_timeout: :kill_task,
      ordered: false,
      timeout: @concurrency_timeout_ms
    )
    |> Enum.map(fn
      {:ok, {:ok, label, duration_ms, summary}} ->
        %{label: label, duration_ms: duration_ms, summary: summary}

      {:ok, {:error, label, duration_ms, error}} ->
        raise "concurrent job #{label} failed after #{duration_ms}ms: #{error}"

      {:exit, reason} ->
        raise "concurrent job exited: #{inspect(reason)}"
    end)
  end

  defp summarize_concurrent_results(results) do
    %{
      count: length(results),
      labels: results |> Enum.map(& &1.label) |> Enum.sort(),
      max_duration_ms: results |> Enum.map(& &1.duration_ms) |> Enum.max(fn -> 0 end)
    }
  end

  defp expect_upstream_failure(fun) do
    case fun.() do
      {:error, {:upstream_response_failed, status, body}} when status in 400..499 ->
        %{
          outcome: "expected_upstream_failure",
          status: status,
          error_keys: upstream_error_keys(body)
        }

      {:ok, response} ->
        raise "expected upstream failure, got successful response #{inspect(response.body)}"

      {:error, reason} ->
        raise "expected upstream 4xx failure, got #{inspect(reason)}"
    end
  end

  defp expected_failure_count(results) do
    Enum.count(results, fn %{summary: summary} ->
      case summary do
        %{outcome: "expected_upstream_failure"} -> true
        %{outcome: "provider_rejected_unsupported_image_input"} -> true
        _summary -> false
      end
    end)
  end

  defp upstream_error_keys(%{"error" => error}) when is_map(error),
    do: error |> Map.keys() |> Enum.sort()

  defp upstream_error_keys(error) when is_map(error), do: error |> Map.keys() |> Enum.sort()
  defp upstream_error_keys(_error), do: []

  defp concurrency_limit do
    case System.get_env("AI_GATEWAY_E2E_CONCURRENCY") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _value -> 6
        end

      _value ->
        6
    end
  end

  defp run_case(name, fun, credentials) do
    started_at = System.monotonic_time(:millisecond)

    record =
      try do
        summary = fun.()
        %{case: name, duration_ms: elapsed_ms(started_at), status: "pass", summary: summary}
      rescue
        exception ->
          %{
            case: name,
            duration_ms: elapsed_ms(started_at),
            error: redact(Exception.format(:error, exception, __STACKTRACE__), credentials),
            status: "fail"
          }
      catch
        kind, reason ->
          %{
            case: name,
            duration_ms: elapsed_ms(started_at),
            error: redact("#{inspect(kind)} #{inspect(reason)}", credentials),
            status: "fail"
          }
      end

    append_record(record)
    IO.puts("#{record.status} #{name} #{record.duration_ms}ms")
    record
  end

  defp summarize(results) do
    pass = Enum.count(results, &(&1.status == "pass"))
    fail = Enum.count(results, &(&1.status == "fail"))
    IO.puts("summary pass=#{pass} fail=#{fail} results=#{@results_path}")

    if fail > 0, do: System.halt(1), else: System.halt(0)
  end

  defp create_provider!(attrs) do
    case ProviderConfigs.create_provider(attrs) do
      {:ok, provider} -> provider
      {:error, reason} -> raise "create provider failed: #{inspect(reason)}"
    end
  end

  defp create_agent!(uid, options) do
    case Principals.create_agent(%{
           uid: uid,
           display_name: uid,
           role: "AIGateway E2E Agent",
           options: options
         }) do
      {:ok, %{principal: principal}} -> principal
      {:error, reason} -> raise "create agent failed: #{inspect(reason)}"
    end
  end

  defp put_profile!(agent_uid, profile, attrs) do
    case ModelProfiles.put_model_profile(agent_uid, profile, attrs) do
      {:ok, value} -> value
      {:error, reason} -> raise "put model profile failed: #{inspect(reason)}"
    end
  end

  defp mint_agent_token!(agent_uid) do
    case AIGatewayTokens.mint_for_agent(agent_uid) do
      {:ok, token} -> token.api_key
      {:error, reason} -> raise "mint token failed: #{inspect(reason)}"
    end
  end

  defp authed_conn(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp json_response!(conn, status) do
    case json_response(conn, status) do
      %{"error" => error} when not is_nil(error) ->
        raise "HTTP #{status} returned error #{inspect(error)}"

      body ->
        body
    end
  end

  defp summarize_llm_response(body) do
    require!(body["object"] == "response", "LLM body is not a ResponseResource")

    require!(
      body["status"] in ["completed", "incomplete", "failed"],
      "unexpected response status"
    )

    text = output_text(body)
    require!(String.trim(text) != "", "LLM output text empty")

    %{
      id: body["id"],
      model: body["model"],
      output_chars: String.length(text),
      status: body["status"],
      usage: Map.take(body["usage"] || %{}, ["input_tokens", "output_tokens", "total_tokens"])
    }
  end

  defp output_text(body) do
    body
    |> Map.get("output", [])
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) -> content
      _item -> []
    end)
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      %{"refusal" => refusal} when is_binary(refusal) -> [refusal]
      _part -> []
    end)
    |> Enum.join("\n")
  end

  defp decode_sse_events(response) do
    response
    |> String.split("\n\n", trim: true)
    |> Enum.flat_map(fn chunk ->
      case sse_data(chunk) do
        "[DONE]" -> []
        data when is_binary(data) -> [Ankole.JSON.decode!(data)]
        nil -> []
      end
    end)
  end

  defp sse_data(chunk) do
    chunk
    |> String.split(["\n", "\r\n"], trim: true)
    |> Enum.find_value(fn
      "data:" <> value -> String.trim_leading(value)
      _line -> nil
    end)
  end

  defp embedding_dimensions(values) when is_list(values), do: length(values)
  defp embedding_dimensions(value) when is_binary(value), do: byte_size(value)
  defp embedding_dimensions(_value), do: 0

  defp deterministic_image_data_url do
    # A tiny generated image avoids depending on local Downloads contents. Some
    # multimodal providers reject 1x1 images, so keep this above common minimums.
    data =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAFklEQVR42mP4TyFgGDVg1IBRA4aLAQBdePwurSGpXgAAAABJRU5ErkJggg=="
      )

    %{
      bytes: byte_size(data),
      data_url: "data:image/png;base64,#{Base.encode64(data)}",
      source: "generated-16x16-png"
    }
  end

  defp append_record(record) do
    # Result lines are JSONL so a failing run can be inspected without parsing
    # terminal logs. Secrets are redacted before this point.
    File.write!(@results_path, Ankole.JSON.encode!(stringify(record)) <> "\n", [:append])
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp redact(value, credentials) do
    credentials
    |> Map.values()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.reduce(to_string(value), fn secret, acc ->
      String.replace(acc, secret, "[REDACTED]")
    end)
  end

  defp required_env(names, provider) do
    Enum.find_value(names, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end) ||
      raise "missing #{provider} credential; set #{Enum.join(names, " or ")} or use --providers=available"
  end

  defp require!(true, _message), do: :ok
  defp require!(false, message), do: raise(message)

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at

  defp unique_suffix do
    "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    |> String.replace(~r/[^a-zA-Z0-9-]/, "-")
    |> String.downcase()
  end

  defp normalize_argv(argv), do: Enum.reject(argv, &(&1 == "--"))
end

Ankole.Tools.AIGatewayRealProviderE2E.run()
