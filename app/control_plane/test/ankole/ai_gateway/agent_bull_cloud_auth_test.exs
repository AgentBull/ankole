defmodule Ankole.AIGateway.AgentBullCloudAuthTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.Providers.AgentBullCloud
  alias Ankole.AIGateway.UniversalAIRequest

  @default_root "https://cloudapis.agentbull.com/v1"
  @static_key "sk-static"

  @prepare_functions [
    :prepare_language_model,
    :prepare_embedding_model,
    :prepare_rerank_model,
    :prepare_image_generate,
    :prepare_web_search
  ]

  defmodule SigningProvider do
    @behaviour Ankole.AIGateway.Providers.AgentBullCloud

    @impl true
    def sign(_claims, _opts), do: {:ok, "agb_rt_minted"}
  end

  defmodule RevokedProvider do
    @behaviour Ankole.AIGateway.Providers.AgentBullCloud

    @impl true
    def sign(_claims, _opts), do: {:error, :revoked}
  end

  defmodule EmptyTokenProvider do
    @behaviour Ankole.AIGateway.Providers.AgentBullCloud

    @impl true
    def sign(_claims, _opts), do: {:ok, ""}
  end

  test "uses an explicitly configured static key when no hosted credential material is present" do
    ctx = context(settings: %{api_key: @static_key})

    assert {:ok, @static_key} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:ok, spec} = prepared_spec(prepare, ctx)
      assert authorization(spec) == "Bearer #{@static_key}"
    end

    assert {:ok, {:openrouter, source}} = AgentBullCloud.models_metadata_source(ctx)
    assert authorization(source) == "Bearer #{@static_key}"

    assert {:ok, image_source} = AgentBullCloud.image_models_metadata_source(ctx)
    assert authorization(image_source) == "Bearer #{@static_key}"
  end

  test "mints and uses a hosted caller token instead of an explicit static key" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: hosted_identity(SigningProvider)
      )

    assert {:ok, "agb_rt_minted"} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:ok, spec} = prepared_spec(prepare, ctx)
      assert authorization(spec) == "Bearer agb_rt_minted"
    end

    assert {:ok, {:openrouter, source}} = AgentBullCloud.models_metadata_source(ctx)
    assert authorization(source) == "Bearer agb_rt_minted"

    assert {:ok, image_source} = AgentBullCloud.image_models_metadata_source(ctx)
    assert authorization(image_source) == "Bearer agb_rt_minted"
  end

  test "uses an explicit hosted caller token without falling back to a static key" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: %{hosted_token: "agb_rt_explicit"}
      )

    assert {:ok, "agb_rt_explicit"} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:ok, spec} = prepared_spec(prepare, ctx)
      assert authorization(spec) == "Bearer agb_rt_explicit"
    end
  end

  test "fails closed when hosted token minting is rejected" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: hosted_identity(RevokedProvider)
      )

    assert {:error, :hosted_token_unavailable} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:error, :hosted_token_unavailable} = apply(AgentBullCloud, prepare, [ctx])
    end

    assert {:error, :hosted_token_unavailable} = AgentBullCloud.models_metadata_source(ctx)
    assert {:error, :hosted_token_unavailable} = AgentBullCloud.image_models_metadata_source(ctx)
  end

  test "fails closed when no hosted token provider is registered" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: Map.delete(hosted_identity(SigningProvider), :hosted_token_provider)
      )

    assert {:error, :hosted_token_unavailable} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:error, :hosted_token_unavailable} = apply(AgentBullCloud, prepare, [ctx])
    end
  end

  test "fails closed when the signing provider returns an empty token" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: hosted_identity(EmptyTokenProvider)
      )

    assert {:error, :hosted_token_unavailable} = AgentBullCloud.resolve_auth_token(ctx)
  end

  test "reports missing credentials without building an unauthenticated request" do
    ctx = context()

    assert {:error, :missing_credentials} = AgentBullCloud.resolve_auth_token(ctx)

    for prepare <- @prepare_functions do
      assert {:error, :missing_credentials} = apply(AgentBullCloud, prepare, [ctx])
    end

    assert {:error, :missing_credentials} = AgentBullCloud.models_metadata_source(ctx)
    assert {:error, :missing_credentials} = AgentBullCloud.image_models_metadata_source(ctx)
  end

  test "reports incomplete hosted claims without falling back to a static key" do
    ctx =
      context(
        settings: %{api_key: @static_key},
        auth: %{isolation_scope: "ten_sec_ank", principal_uid: "usr_sec_ank"}
      )

    assert {:error, :missing_policy} = AgentBullCloud.resolve_auth_token(ctx)
    assert {:error, :missing_policy} = AgentBullCloud.prepare_language_model(ctx)
  end

  defp hosted_identity(provider) do
    %{
      isolation_scope: "ten_sec_ank",
      principal_uid: "usr_sec_ank",
      allowed_models: ["*"],
      budget_ceiling: 1_000_000,
      hosted_token_provider: provider
    }
  end

  defp context(opts \\ []) do
    settings =
      opts
      |> Keyword.get(:settings, %{})
      |> Map.put_new(:base_url, @default_root)

    %{
      settings: settings,
      connection: %{base_url: @default_root},
      provider_options: %{},
      request: %{},
      request_context: %{},
      stream?: false,
      auth: Keyword.get(opts, :auth, %{}),
      pod: Keyword.get(opts, :pod, %{}),
      session: Keyword.get(opts, :session, %{})
    }
  end

  defp prepared_spec(prepare, ctx) do
    case apply(AgentBullCloud, prepare, [ctx]) do
      %UniversalAIRequest{} = request -> UniversalAIRequest.to_spec(request)
      {:error, _reason} = error -> error
    end
  end

  defp authorization(%{headers: headers}), do: header(headers, "authorization")
  defp authorization(%{upstream: %{headers: headers}}), do: header(headers, "authorization")

  defp header(headers, name) do
    Enum.find_value(headers || [], fn
      {header_name, value} -> if String.downcase(header_name) == name, do: value
      _other -> nil
    end)
  end
end
