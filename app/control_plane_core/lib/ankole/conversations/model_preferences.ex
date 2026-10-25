defmodule Ankole.Conversations.ModelPreferences do
  @moduledoc "Conversation preferences and the logical model captured by each accepted input."

  require Ash.Query
  alias Ankole.Principals
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Conversations.Conversation
  alias Ankole.Sessions.{Commands, Queue}
  alias Ankole.Signals.Signal

  def catalog(agent_uid) do
    with {:ok, %{type: :agent, status: :active}} <- Principals.get_principal(agent_uid),
         {:ok, profiles} <- ModelProfiles.list_custom_model_profiles(agent_uid) do
      {:ok, %{profiles: Enum.filter(profiles, &available?(agent_uid, &1["name"]))}}
    else
      _ -> {:error, :agent_unavailable}
    end
  end

  def validate(_agent_uid, nil), do: {:ok, nil}

  def validate(agent_uid, profile) when is_binary(profile) do
    with {:ok, %{profiles: profiles}} <- catalog(agent_uid),
         true <- Enum.any?(profiles, &(&1["name"] == profile)) do
      {:ok, profile}
    else
      _ -> {:error, :model_profile_unavailable}
    end
  end

  def validate(_, _), do: {:error, :model_profile_unavailable}

  defp available?(agent_uid, profile) do
    with {:ok, attrs} <- ModelProfiles.get_custom_model_profile(agent_uid, profile),
         {:ok, _} <- ProviderConfigs.fetch_active_provider(attrs["provider_id"]),
         do: true,
         else: (_ -> false)
  end

  def selected(%Conversation{preferred_models: models}, agent_uid), do: models[agent_uid]
  def logical(conversation, agent_uid), do: selected(conversation, agent_uid) || "primary"

  def selection(conversation, agent_uid) do
    with {:ok, catalog} <- catalog(agent_uid) do
      {:ok,
       Map.merge(catalog, %{
         profile: selected(conversation, agent_uid),
         active_profile: active_profile(agent_uid, conversation.id)
       })}
    end
  end

  def initialize(%Conversation{sequence_high_water: 0} = conversation, agent_uid, profile) do
    with {:ok, profile} <- validate(agent_uid, profile), do: put(conversation, agent_uid, profile)
  end

  # Retrying the original create must not reset a later, explicitly saved preference.
  def initialize(conversation, _agent_uid, _profile), do: {:ok, conversation}

  def put(conversation, agent_uid, profile) do
    models =
      if is_nil(profile),
        do: Map.delete(conversation.preferred_models, agent_uid),
        else: Map.put(conversation.preferred_models, agent_uid, profile)

    Ankole.Ash.update(conversation, :set_agent_model_profile, %{preferred_models: models})
  end

  def authorize_input(_conversation, _agent_uid, _mode, false), do: :ok

  def authorize_input(conversation, agent_uid, mode, true) do
    with {:ok, _} <- validate(agent_uid, selected(conversation, agent_uid)) do
      if mode == "steer",
        do: ensure_can_steer(agent_uid, conversation.id, logical(conversation, agent_uid)),
        else: :ok
    end
  end

  def ensure_can_steer(agent_uid, conversation_id, profile) do
    case active_profile(agent_uid, conversation_id) do
      nil -> :ok
      ^profile -> :ok
      _ -> {:error, :requires_queue_for_profile}
    end
  end

  def active_profile(agent_uid, conversation_id) do
    case Queue.oldest_started(agent_uid, Ankole.Sessions.Key.conversation(conversation_id)) do
      %Signal{data: %{"model_profile" => profile}} -> profile
      %Signal{} = input -> Commands.profile(input) || "primary"
      nil -> nil
    end
  end

  # Human inputs carry their sending-time choice. Automatic Main wakes use the
  # conversation's preference until admission freezes it into the same input.
  def for_event(%Signal{producer: :kernel, agent_uid: agent_uid, conversation_id: id, data: data})
      when is_binary(id) and is_map(data) do
    case data["model_profile"] do
      profile when is_binary(profile) ->
        profile

      _ ->
        case conversation(id) do
          %Conversation{kind: :native} = conversation -> logical(conversation, agent_uid)
          _ -> nil
        end
    end
  end

  def for_event(_event), do: nil

  def freeze_admission(
        %Signal{producer: :kernel, conversation_id: id, data: data},
        profile
      )
      when is_binary(id) and is_map(data) and is_binary(profile) do
    case conversation(id) do
      %Conversation{kind: :native} ->
        Map.put_new(data, "model_profile", profile)

      _ ->
        data
    end
  end

  def freeze_admission(event, _prepared), do: event.data

  def compatible?(%Signal{data: %{"model_profile" => profile}}, active_profile),
    do: profile == active_profile

  def compatible?(_event, _active_profile), do: true

  defp conversation(id), do: Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()
end
