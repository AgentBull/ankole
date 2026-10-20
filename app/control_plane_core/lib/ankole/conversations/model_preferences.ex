defmodule Ankole.Conversations.ModelPreferences do
  @moduledoc "Conversation preferences and the logical model captured by each accepted input."

  alias Ankole.{Repo, Principals}
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

  def selected(%Conversation{metadata: metadata}), do: metadata["model_profile"]
  def logical(conversation), do: selected(conversation) || "primary"

  def selection(repo, conversation, agent_uid) do
    with {:ok, catalog} <- catalog(agent_uid) do
      {:ok,
       Map.merge(catalog, %{
         profile: selected(conversation),
         active_profile: active_profile(repo, agent_uid, conversation.id)
       })}
    end
  end

  def initialize(repo, %Conversation{sequence_high_water: 0} = conversation, agent_uid, profile) do
    with {:ok, profile} <- validate(agent_uid, profile), do: put(repo, conversation, profile)
  end

  # Retrying the original create must not reset a later, explicitly saved preference.
  def initialize(_repo, conversation, _agent_uid, _profile), do: {:ok, conversation}

  def put(repo, conversation, profile) do
    metadata =
      if is_nil(profile),
        do: Map.delete(conversation.metadata, "model_profile"),
        else: Map.put(conversation.metadata, "model_profile", profile)

    conversation |> Conversation.changeset(%{metadata: metadata}) |> repo.update()
  end

  def authorize_input(_repo, _conversation, _agent_uid, _mode, false), do: :ok

  def authorize_input(repo, conversation, agent_uid, mode, true) do
    with {:ok, _} <- validate(agent_uid, selected(conversation)) do
      if mode == "steer",
        do: ensure_can_steer(repo, agent_uid, conversation.id, logical(conversation)),
        else: :ok
    end
  end

  def ensure_can_steer(repo, agent_uid, conversation_id, profile) do
    case active_profile(repo, agent_uid, conversation_id) do
      nil -> :ok
      ^profile -> :ok
      _ -> {:error, :requires_queue_for_profile}
    end
  end

  def active_profile(repo, agent_uid, conversation_id) do
    case Queue.oldest_started(repo, agent_uid, Ankole.Sessions.Key.conversation(conversation_id)) do
      %Signal{data: %{"model_profile" => profile}} -> profile
      %Signal{} = input -> Commands.profile(input) || "primary"
      nil -> nil
    end
  end

  # Human inputs carry their sending-time choice. Automatic Main wakes use the
  # conversation's preference until admission freezes it into the same input.
  def for_event(%Signal{producer: :kernel, conversation_id: id, data: data})
      when is_binary(id) and is_map(data) do
    case data["model_profile"] do
      profile when is_binary(profile) ->
        profile

      _ ->
        case Repo.get_by(Conversation, id: id) do
          %Conversation{kind: :native} = conversation -> logical(conversation)
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
    case Repo.get_by(Conversation, id: id) do
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
end
