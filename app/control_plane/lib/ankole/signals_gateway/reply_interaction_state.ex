defmodule Ankole.SignalsGateway.ReplyInteractionState do
  @moduledoc """
  Pure state machine for one durable reply interaction.

  PostgreSQL checkpoints carry the state; provider surfaces are projections. A
  terminal answer or supersession is monotonic, including when a delayed
  provider write tries to persist an older pending projection.

  Every transition returns a checkpoint for `Actors.put_reply_preview_checkpoint`.
  That write projects the terminal interaction into the presentation through
  `merge_checkpoint/3`, so no transition needs to know whether a provider
  surface exists.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPresentation

  @terminal_states ~w(answered superseded)

  @type checkpoint :: %{optional(String.t()) => term()}
  @type surface_fun :: (checkpoint() -> boolean())

  @spec initialize(checkpoint(), map(), DateTime.t(), keyword()) :: checkpoint()
  def initialize(checkpoint, presentation, %DateTime{} = now, opts \\ [])
      when is_map(checkpoint) and is_map(presentation) do
    interactions = interactions(checkpoint)
    superseded_by = Keyword.get(opts, :superseded_by)

    initialized =
      presentation
      |> interaction_ids()
      |> Map.new(fn interaction_id ->
        {interaction_id, initial_interaction(interaction_id, now, superseded_by)}
      end)

    checkpoint
    |> Map.put("presentation", ReplyPresentation.checkpoint(presentation))
    |> Map.put("interactions", initialize_interactions(interactions, initialized))
  end

  @spec pending_interaction_ids(checkpoint()) :: [String.t()]
  def pending_interaction_ids(checkpoint) when is_map(checkpoint) do
    checkpoint
    |> candidate_interaction_ids()
    |> Enum.filter(&(interaction_state(checkpoint, &1) == "pending"))
  end

  @spec interaction(checkpoint(), String.t()) :: map() | nil
  def interaction(checkpoint, interaction_id)
      when is_map(checkpoint) and is_binary(interaction_id) do
    Map.get(interactions(checkpoint), interaction_id)
  end

  @spec resolve(checkpoint(), String.t(), map()) :: {:ok, checkpoint()} | :stale
  def resolve(checkpoint, interaction_id, resolution)
      when is_map(checkpoint) and is_binary(interaction_id) and is_map(resolution) do
    if interaction_state(checkpoint, interaction_id) == "pending" and
         terminal_state?(resolution) do
      interactions =
        checkpoint
        |> interactions()
        |> Map.put(
          interaction_id,
          resolution
          |> stringify_keys()
          |> Map.put("interaction_id", interaction_id)
        )

      {:ok, Map.put(checkpoint, "interactions", interactions)}
    else
      :stale
    end
  end

  @spec supersede(checkpoint(), ActorEvent.t(), DateTime.t()) ::
          {:ok, checkpoint()} | :noop
  def supersede(checkpoint, %ActorEvent{} = newer_event, %DateTime{} = now)
      when is_map(checkpoint) do
    case pending_interaction_ids(checkpoint) do
      [] ->
        :noop

      interaction_ids ->
        resolution = %{
          "state" => "superseded",
          "resolved_at" => DateTime.to_iso8601(now),
          "superseded_by_actor_event_id" => newer_event.id
        }

        interactions =
          Enum.reduce(interaction_ids, interactions(checkpoint), fn interaction_id, acc ->
            Map.put(acc, interaction_id, Map.put(resolution, "interaction_id", interaction_id))
          end)

        {:ok, Map.put(checkpoint, "interactions", interactions)}
    end
  end

  @doc """
  Applies the durable interaction result to a provider-neutral presentation.
  """
  @spec project(map(), checkpoint()) :: ReplyPresentation.t()
  def project(presentation, checkpoint) when is_map(presentation) and is_map(checkpoint) do
    normalized = ReplyPresentation.normalize(presentation)

    normalized
    |> interaction_ids()
    |> Enum.find_value(fn interaction_id ->
      case interaction(checkpoint, interaction_id) do
        %{"state" => state} = resolved when state in @terminal_states ->
          {state, resolution_answer(resolved, interaction_id)}

        _pending_or_missing ->
          nil
      end
    end)
    |> case do
      {state, answer} -> ReplyPresentation.resolve_interaction(normalized, state, answer)
      nil -> presentation
    end
  end

  @doc """
  Merges one checkpoint write without allowing a resolved interaction to reopen.

  Provider calls can span network I/O. A provider write that started from a
  pending provider write may therefore finish after PostgreSQL already recorded an answer
  or a newer turn. The terminal interaction wins. When the projection changes
  the stored presentation and `surface_fun` reports a provider surface, the
  write also schedules a corrective refresh of that surface.
  """
  @spec merge_checkpoint(checkpoint() | nil, checkpoint(), surface_fun()) :: checkpoint()
  def merge_checkpoint(existing, incoming, surface_fun)
      when is_map(incoming) and is_function(surface_fun, 1) do
    existing = if is_map(existing), do: existing, else: %{}
    merged_interactions = merge_interactions(interactions(existing), interactions(incoming))
    incoming = put_interactions(incoming, merged_interactions)

    case incoming["presentation"] do
      %{} = proposed ->
        proposed = ReplyPresentation.normalize(proposed)
        projected = project(proposed, incoming)

        if projected == proposed do
          incoming
        else
          incoming
          |> Map.put("previous_presentation", ReplyPresentation.checkpoint(proposed))
          |> Map.put("presentation", ReplyPresentation.checkpoint(projected))
          |> maybe_schedule_refresh(surface_fun)
        end

      _missing ->
        incoming
    end
  end

  defp initial_interaction(interaction_id, now, nil) do
    %{
      "interaction_id" => interaction_id,
      "state" => "pending",
      "opened_at" => DateTime.to_iso8601(now)
    }
  end

  defp initial_interaction(interaction_id, now, %ActorEvent{} = newer_event) do
    %{
      "interaction_id" => interaction_id,
      "state" => "superseded",
      "resolved_at" => DateTime.to_iso8601(now),
      "superseded_by_actor_event_id" => newer_event.id
    }
  end

  defp maybe_schedule_refresh(checkpoint, surface_fun) do
    if surface_fun.(checkpoint) do
      checkpoint
      |> Map.put("refresh_pending", true)
      |> Map.put("refresh_reason", "interaction")
    else
      checkpoint
    end
  end

  defp merge_interactions(existing, proposed) do
    Map.merge(existing, proposed, fn _interaction_id, current, next ->
      if terminal_state?(current), do: current, else: next
    end)
  end

  defp initialize_interactions(existing, initialized) do
    Map.merge(initialized, existing, fn _interaction_id, fresh, current ->
      if is_map(current), do: current, else: fresh
    end)
  end

  defp interactions(%{"interactions" => interactions}) when is_map(interactions) do
    Enum.reduce(interactions, %{}, fn
      {interaction_id, %{} = interaction}, acc when is_binary(interaction_id) ->
        case normalize_interaction(interaction) do
          %{} = normalized -> Map.put(acc, interaction_id, normalized)
          nil -> acc
        end

      _invalid, acc ->
        acc
    end)
  end

  defp interactions(_checkpoint), do: %{}

  defp put_interactions(checkpoint, interactions) when map_size(interactions) == 0,
    do: Map.delete(checkpoint, "interactions")

  defp put_interactions(checkpoint, interactions),
    do: Map.put(checkpoint, "interactions", interactions)

  defp candidate_interaction_ids(checkpoint) do
    checkpoint
    |> interactions()
    |> Map.keys()
    |> Kernel.++(interaction_ids(checkpoint["presentation"]))
    |> Enum.uniq()
  end

  defp interaction_ids(presentation) when is_map(presentation) do
    presentation
    |> ReplyPresentation.normalize()
    |> Map.fetch!("actions")
    |> Enum.map(& &1["interaction_id"])
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp interaction_ids(_presentation), do: []

  defp interaction_state(checkpoint, interaction_id) do
    case interaction(checkpoint, interaction_id) do
      %{"state" => state} -> state
      nil -> nil
    end
  end

  defp normalize_interaction(interaction) do
    interaction = stringify_keys(interaction)

    case interaction do
      %{"state" => "pending"} ->
        interaction

      %{"state" => "answered", "answer" => %{} = answer} ->
        case normalize_answer(answer) do
          %{} = normalized -> Map.put(interaction, "answer", normalized)
          nil -> nil
        end

      %{"state" => "superseded"} ->
        interaction

      _stale ->
        nil
    end
  end

  defp normalize_answer(answer) do
    answer = stringify_keys(answer)

    case answer do
      %{"kind" => "choice", "value" => value, "option_id" => option_id}
      when is_binary(value) and value != "" and is_binary(option_id) and option_id != "" ->
        answer

      %{"kind" => "free_text", "value" => value} when is_binary(value) and value != "" ->
        answer

      _stale ->
        nil
    end
  end

  defp resolution_answer(interaction, interaction_id) do
    case interaction["answer"] do
      %{} = answer -> Map.put(answer, "interaction_id", interaction_id)
      _missing -> %{"interaction_id" => interaction_id}
    end
  end

  defp terminal_state?(%{} = interaction) do
    state = Map.get(interaction, "state") || Map.get(interaction, :state)
    state in @terminal_states
  end

  defp terminal_state?(_interaction), do: false

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
