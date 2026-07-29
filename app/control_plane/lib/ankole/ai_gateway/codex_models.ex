defmodule Ankole.AIGateway.CodexModels do
  @moduledoc """
  Codex `/models` manifest for AIGateway-backed codex runtimes.

  Codex fetches `GET {base_url}/models?client_version=…` when its provider uses
  command auth, and applies each returned card with full-card replacement
  semantics (`construct_model_info_from_candidates`, codex
  rust-v0.146.0). Every card therefore reproduces the codex fallback
  card (`model_info_from_slug`) exactly and changes only what AIGateway owns:
  `supports_search_tool` opens the native deferred-tool gate, and
  `base_instructions` carries the prompt text vendored from the same codex pin.

  Cards must stay in lockstep with the pinned codex version. Re-vendor
  `priv/codex/base_instructions.md` and re-check the card baseline when the
  codex pin changes.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Models
  alias Ankole.AIGateway.ProviderConfigs

  @responses_lite_models MapSet.new(~w(gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna))

  @external_resource Path.join(:code.priv_dir(:ankole), "codex/base_instructions.md")
  @base_instructions File.read!(Path.join(:code.priv_dir(:ankole), "codex/base_instructions.md"))

  @doc """
  Returns whether one `/models` request comes from a codex models refresh.

  Codex always appends `client_version` to its manifest request; the ordinary
  OpenAI-compatible model listing never sends it.
  """
  @spec codex_manifest_request?(map()) :: boolean()
  def codex_manifest_request?(%{} = params), do: is_binary(Map.get(params, "client_version"))

  @doc """
  Builds the manifest body for one authenticated subject.

  One card is served per model selector the subject can address, so the card
  slug equals the `model` value a codex job config carries.
  """
  @spec manifest(String.t(), String.t()) :: {:ok, map()}
  def manifest(subject_uid, subject_type) do
    {:ok, %{"data" => entries}} = Models.list_models(subject_uid, subject_type)

    slugs =
      entries
      |> Enum.map(&Map.get(&1, "id"))
      |> Kernel.++(runtime_model_slugs(subject_uid, subject_type))
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    {:ok, %{"models" => Enum.map(slugs, &card/1)}}
  end

  @doc """
  Builds one full model card for a selector slug.
  """
  @spec card(String.t()) :: map()
  def card(slug) when is_binary(slug) do
    %{
      "slug" => slug,
      "display_name" => slug,
      "description" => nil,
      "supported_reasoning_levels" => [],
      "shell_type" => "default",
      "visibility" => "none",
      "supported_in_api" => true,
      "priority" => 99,
      "availability_nux" => nil,
      "upgrade" => nil,
      "base_instructions" => @base_instructions,
      "default_reasoning_summary" => "auto",
      "support_verbosity" => false,
      "default_verbosity" => nil,
      "apply_patch_tool_type" => "freeform",
      "web_search_tool_type" => "text",
      "truncation_policy" => %{"mode" => "bytes", "limit" => 10_000},
      "supports_parallel_tool_calls" => false,
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "effective_context_window_percent" => 95,
      "experimental_supported_tools" => [],
      "input_modalities" => ["text", "image"],
      "supports_search_tool" => true,
      "use_responses_lite" => MapSet.member?(@responses_lite_models, slug)
    }
  end

  defp runtime_model_slugs(agent_uid, "agent") do
    case ModelProfiles.get_model_profiles(agent_uid) do
      {:ok, profiles} ->
        Enum.flat_map(profiles, fn {profile, attrs} ->
          with {:ok, "llm"} <- ModelProfiles.profile_capability(profile),
               %{"provider_id" => provider_id, "model" => model} <- attrs,
               true <- is_binary(model) and model != "",
               {:ok, provider} <- ProviderConfigs.fetch_active_provider(provider_id) do
            [codex_model_slug(provider.provider_kind, model)]
          else
            _reason -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp runtime_model_slugs(_subject_uid, _subject_type), do: []

  defp codex_model_slug("openrouter", model) do
    case String.split(model, "/", parts: 2) do
      [_provider, slug] when slug != "" -> slug
      _parts -> model
    end
  end

  defp codex_model_slug(_provider_kind, model), do: model
end
