defmodule Ankole.AIGateway.CodexModels do
  @moduledoc """
  Codex `/models` manifest for AIGateway-backed codex runtimes.

  Codex fetches `GET {base_url}/models?client_version=…` when its provider uses
  command auth, and applies each returned card with full-card replacement
  semantics (`construct_model_info_from_candidates`, codex
  rust-v0.150.1). Every card therefore supplies the complete pinned card shape.
  AIGateway owns selector-specific modalities, the native search gate, and one
  model-visible tool-output limit. Base instructions contain the prompt vendored
  from the same codex pin and the readable form of that output limit. Cards keep
  Responses Lite disabled because the pinned Codex runtime omits configured
  hosted web search from that private carrier; standard Responses preserves the
  native tool.

  Cards must stay in lockstep with the pinned codex version. Re-vendor
  `priv/codex/base_instructions.md` and re-check the card baseline when the
  codex pin changes.
  """

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Models

  @tool_output_limit_tokens 10_000

  @external_resource Path.join(:code.priv_dir(:ankole), "codex/base_instructions.md")
  @base_instructions File.read!(Path.join(:code.priv_dir(:ankole), "codex/base_instructions.md")) <>
                       "\n\n" <>
                       "`max_output_tokens` is a requested upper limit. " <>
                       "Model-visible tool output is limited to #{@tool_output_limit_tokens} tokens. " <>
                       "Process larger output in code before you return it, or write it to a workspace file."

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

    fallback_ref = vision_fallback_ref(subject_uid, subject_type)

    candidates =
      entry_model_candidates(entries, fallback_ref) ++
        runtime_model_candidates(subject_uid, subject_type)

    {:ok,
     %{
       "models" =>
         candidates
         |> intersect_duplicate_modalities()
         |> Enum.map(fn {slug, modalities} -> card(slug, modalities) end)
     }}
  end

  @doc """
  Builds one full model card for a selector slug.
  """
  @spec card(String.t(), [String.t()]) :: map()
  def card(slug, input_modalities) when is_binary(slug) and is_list(input_modalities) do
    %{
      "slug" => slug,
      "display_name" => slug,
      "description" => nil,
      "supported_reasoning_levels" => [],
      "shell_type" => "unified_exec",
      "visibility" => "none",
      "supported_in_api" => true,
      "priority" => 99,
      "availability_nux" => nil,
      "upgrade" => nil,
      "base_instructions" => @base_instructions,
      "model_messages" => %{
        "instructions_template" => @base_instructions,
        "instructions_variables" => nil
      },
      "include_skills_usage_instructions" => false,
      "include_plugin_usage_instructions" => false,
      "include_apps_usage_instructions" => false,
      "default_reasoning_summary" => "auto",
      "support_verbosity" => false,
      "default_verbosity" => nil,
      "apply_patch_tool_type" => "freeform",
      "web_search_tool_type" => "text",
      "truncation_policy" => %{
        "mode" => "tokens",
        "limit" => @tool_output_limit_tokens
      },
      "context_window" => 272_000,
      "max_context_window" => 272_000,
      "effective_context_window_percent" => 95,
      "experimental_supported_tools" => [],
      "input_modalities" => codex_input_modalities(input_modalities),
      "supports_search_tool" => true,
      "use_responses_lite" => false
    }
  end

  defp entry_model_candidates(entries, fallback_ref) do
    Enum.flat_map(entries, fn entry ->
      case Map.get(entry, "id") do
        slug when is_binary(slug) and slug != "" ->
          direct = get_in(entry, ["architecture", "input_modalities"]) || ["text"]
          [{slug, effective_input_modalities(direct, fallback_ref)}]

        _slug ->
          []
      end
    end)
  end

  defp runtime_model_candidates(agent_uid, "agent") do
    case ModelProfiles.get_model_profiles(agent_uid) do
      {:ok, profiles} ->
        Enum.flat_map(profiles, fn {profile, attrs} ->
          with {:ok, "llm"} <- ModelProfiles.profile_capability(profile),
               %{} <- attrs,
               {:ok, model_ref} <- ModelProfiles.resolve_runtime_model_ref(agent_uid, profile),
               model when is_binary(model) and model != "" <- model_ref["model"],
               provider_kind when is_binary(provider_kind) <- model_ref["provider_kind"] do
            [
              {codex_model_slug(provider_kind, model),
               ModelProfiles.effective_input_modalities(model_ref)}
            ]
          else
            _reason -> []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp runtime_model_candidates(_subject_uid, _subject_type), do: []

  defp vision_fallback_ref(agent_uid, "agent") do
    case ModelProfiles.resolve_runtime_model_ref(agent_uid, "vision_fallback") do
      {:ok, %{"input_modalities" => modalities} = model_ref} when is_list(modalities) ->
        if "image" in modalities, do: model_ref

      _result ->
        nil
    end
  end

  defp vision_fallback_ref(_subject_uid, _subject_type), do: nil

  defp effective_input_modalities(direct, fallback_ref) do
    model_ref =
      %{"input_modalities" => Enum.map(List.wrap(direct), &to_string/1)}
      |> maybe_put_fallback(fallback_ref)

    ModelProfiles.effective_input_modalities(model_ref)
  end

  defp maybe_put_fallback(model_ref, nil), do: model_ref

  defp maybe_put_fallback(model_ref, fallback_ref),
    do: Map.put(model_ref, "vision_fallback_model_ref", fallback_ref)

  defp intersect_duplicate_modalities(candidates) do
    {order, modalities_by_slug} =
      Enum.reduce(candidates, {[], %{}}, fn {slug, modalities}, {order, by_slug} ->
        modalities = MapSet.new(codex_input_modalities(modalities))

        case Map.fetch(by_slug, slug) do
          {:ok, current} ->
            {order, Map.put(by_slug, slug, MapSet.intersection(current, modalities))}

          :error ->
            {order ++ [slug], Map.put(by_slug, slug, modalities)}
        end
      end)

    Enum.map(order, fn slug ->
      {slug, Map.fetch!(modalities_by_slug, slug) |> MapSet.to_list()}
    end)
  end

  defp codex_input_modalities(modalities) do
    modalities = MapSet.new(Enum.map(modalities, &to_string/1))
    ["text"] ++ if(MapSet.member?(modalities, "image"), do: ["image"], else: [])
  end

  defp codex_model_slug("openrouter", model) do
    case String.split(model, "/", parts: 2) do
      [_provider, slug] when slug != "" -> slug
      _parts -> model
    end
  end

  defp codex_model_slug(_provider_kind, model), do: model
end
