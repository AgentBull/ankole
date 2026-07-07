defmodule Ankole.AIGateway.Conversations do
  @moduledoc """
  Durable AIGateway conversation and runtime-profile API.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.AgentConfig
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.Ecto.UUIDv7
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.Repo

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Creates or reuses the active conversation for one actor session.

  The conversation is the durable transcript owner. ActorRuntime owns worker
  delivery and activation fences, but it should not create a separate transcript
  model for the same user story.
  """
  @spec ensure_conversation(String.t(), String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(agent_uid, session_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    ensure_conversation_in_tx(repo, normalize_uid(agent_uid), session_id)
  end

  @doc """
  Creates a conversation for a first `response.create store=true` request that
  did not name an existing conversation or previous response anchor.

  The generated conversation key is an implementation detail. The metadata flag
  lets operators and future cleanup distinguish conversations created implicitly
  by the stateful Responses API from actor-session conversations.
  """
  @spec create_managed_stateful_responses_conversation(String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def create_managed_stateful_responses_conversation(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    metadata = managed_stateful_responses_metadata(Keyword.get(opts, :metadata, %{}))

    %Conversation{}
    |> Conversation.changeset(%{
      agent_uid: normalize_uid(agent_uid),
      conversation_key: managed_stateful_responses_conversation_key(),
      metadata: metadata
    })
    |> repo.insert()
  end

  @doc """
  Ensures the active conversation inside a caller-owned transaction.
  """
  @spec ensure_conversation_in_tx(module(), String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, term()}
  # Uses insert-then-refetch to tolerate concurrent first input for the same
  # actor session without exposing unique-constraint details to callers.
  def ensure_conversation_in_tx(repo, agent_uid, session_id) do
    agent_uid = normalize_uid(agent_uid)

    case active_conversation(repo, agent_uid, session_id) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          agent_uid: agent_uid,
          conversation_key: session_id,
          metadata: %{}
        })
        |> repo.insert()
        |> case do
          {:ok, %Conversation{} = conversation} -> {:ok, conversation}
          {:error, _changeset} -> refetch_active_conversation(repo, agent_uid, session_id)
        end
    end
  end

  @doc """
  Builds the worker turn-start model/request context for one conversation.

  AIGateway owns durable response rows. ActorRuntime only needs this
  transport-facing spec before handing an actor event to the worker.
  """
  @spec build_turn_start_spec(Conversation.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build_turn_start_spec(%Conversation{} = conversation, opts \\ []) do
    with {:ok, model_ref} <-
           turn_model_ref(conversation.agent_uid, Keyword.get(opts, :profile, "primary")),
         {:ok, agent_runtime_policy} <-
           AgentConfig.runtime_policy(conversation.agent_uid,
             max_completion_tokens: model_ref["max_completion_tokens"]
           ) do
      {:ok,
       %{
         model_ref: model_ref,
         request_context:
           request_context(
             conversation,
             model_ref,
             agent_runtime_policy,
             Keyword.get(opts, :request_context, %{})
           )
       }}
    end
  end

  @doc """
  Locks a conversation row for update.
  """
  @spec lock_conversation(module(), term()) :: Conversation.t() | nil
  def lock_conversation(repo, conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp active_conversation(repo, agent_uid, session_id) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^agent_uid)
    |> where([conversation], conversation.conversation_key == ^session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> repo.one()
  end

  defp refetch_active_conversation(repo, agent_uid, session_id) do
    case active_conversation(repo, agent_uid, session_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :conversation_not_found}
    end
  end

  defp request_context(
         %Conversation{} = conversation,
         model_ref,
         agent_runtime_policy,
         extra_context
       )
       when is_map(extra_context) do
    %{
      "actor_key" => %{
        "agent_uid" => conversation.agent_uid,
        "session_id" => conversation.conversation_key
      },
      "model_ref" => model_ref
    }
    |> Map.merge(extra_context)
    |> Map.put("ai_agent", agent_runtime_policy)
  end

  defp request_context(
         %Conversation{} = conversation,
         model_ref,
         agent_runtime_policy,
         _extra_context
       ) do
    request_context(conversation, model_ref, agent_runtime_policy, %{})
  end

  defp turn_model_ref(agent_uid, profile) do
    case ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
      {:ok, runtime_profile} ->
        model_ref = model_ref_from_runtime_profile(runtime_profile)

        {:ok,
         model_ref
         |> maybe_put_vision_fallback_model_ref(agent_uid)}

      {:error, reason} ->
        {:error, {:model_profile_unavailable, profile, reason}}
    end
  end

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)

  defp managed_stateful_responses_metadata(metadata) when is_map(metadata) do
    Map.put(metadata, "managed_by_stateful_responses_api", true)
  end

  defp managed_stateful_responses_metadata(_metadata) do
    %{"managed_by_stateful_responses_api" => true}
  end

  defp managed_stateful_responses_conversation_key do
    "stateful-responses-api:#{UUIDv7.autogenerate()}"
  end

  defp model_ref_from_runtime_profile(runtime_profile) when is_map(runtime_profile) do
    %{
      "profile" => runtime_profile["profile"],
      "provider_id" => runtime_profile["provider_id"],
      "provider_kind" => runtime_profile["provider_kind"],
      "model" => runtime_profile["model"],
      "input_modalities" => input_modalities_for_runtime_profile(runtime_profile)
    }
    |> maybe_put(
      "max_completion_tokens",
      max_completion_tokens_for_runtime_profile(runtime_profile)
    )
  end

  defp maybe_put_vision_fallback_model_ref(model_ref, agent_uid) do
    if "image" in Map.get(model_ref, "input_modalities", []) do
      model_ref
    else
      case ModelProfiles.resolve_runtime_profile(agent_uid, "vision_fallback") do
        {:ok, fallback_runtime_profile} ->
          fallback_ref = model_ref_from_runtime_profile(fallback_runtime_profile)

          case "image" in fallback_ref["input_modalities"] do
            true -> Map.put(model_ref, "vision_fallback_model_ref", fallback_ref)
            false -> model_ref
          end

        {:error, _reason} ->
          model_ref
      end
    end
  end

  defp input_modalities_for_runtime_profile(%{
         "provider" => %Provider{} = provider,
         "model" => model
       }) do
    input_modalities(provider, model)
  end

  defp input_modalities_for_runtime_profile(%{"provider_id" => provider_id, "model" => model})
       when is_binary(provider_id) do
    case ProviderConfigs.fetch_active_provider(provider_id) do
      {:ok, provider} -> input_modalities(provider, model)
      {:error, _reason} -> ["text"]
    end
  end

  defp input_modalities_for_runtime_profile(_runtime_profile), do: ["text"]

  defp input_modalities(%Provider{} = provider, model) when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"architecture" => %{"input_modalities" => [_ | _] = modalities}}} ->
        Enum.map(modalities, &to_string/1)

      _metadata ->
        ["text"]
    end
  end

  defp input_modalities(_provider, _model), do: ["text"]

  defp max_completion_tokens_for_runtime_profile(%{
         "provider" => %Provider{} = provider,
         "model" => model
       }) do
    max_completion_tokens(provider, model)
  end

  defp max_completion_tokens_for_runtime_profile(%{
         "provider_id" => provider_id,
         "model" => model
       })
       when is_binary(provider_id) do
    case ProviderConfigs.fetch_active_provider(provider_id) do
      {:ok, provider} -> max_completion_tokens(provider, model)
      {:error, _reason} -> nil
    end
  end

  defp max_completion_tokens_for_runtime_profile(_runtime_profile), do: nil

  defp max_completion_tokens(%Provider{} = provider, model) when is_binary(model) do
    case ModelMetadata.model_metadata(provider, model) do
      {:ok, %{"top_provider" => %{"max_completion_tokens" => value}}} ->
        positive_integer(value)

      _metadata ->
        nil
    end
  end

  defp max_completion_tokens(_provider, _model), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
