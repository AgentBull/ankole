defmodule Ankole.AIGateway.ImageStreamPersistence do
  @moduledoc """
  Persists generated image results before their public completion escapes.

  Non-streaming responses use `persist_response/3`. Streaming responses use the
  state machine, which delays the image `completed` event until the following
  `output_item.done` carries the final bytes and those bytes have been durably
  stored. Transport framing deliberately stays outside this module.
  """

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.HostedTools.ImageGeneration.Error
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.Repo

  defstruct subject_uid: nil,
            message_id: nil,
            pending_completed: %{},
            persisted_image_ids: %{},
            response: nil,
            output_items: %{},
            last_public_sequence: -1

  @type t :: %__MODULE__{
          subject_uid: String.t(),
          message_id: String.t() | nil,
          pending_completed: %{optional(String.t()) => map()},
          persisted_image_ids: %{optional(String.t()) => true},
          response: map() | nil,
          output_items: %{optional(non_neg_integer()) => map()},
          last_public_sequence: integer()
        }

  @type observation ::
          {:ok, t(), [map()]}
          | {:error, t(), [map()], OpenAIError.t() | term()}

  @spec new(String.t(), keyword()) :: t()
  def new(subject_uid, opts \\ []) do
    %__MODULE__{
      subject_uid: subject_uid,
      message_id: Keyword.get(opts, :message_id)
    }
  end

  @spec persist_response(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def persist_response(subject_uid, response, opts \\ []) when is_map(response) do
    output = Map.get(response, "output", [])

    case Repo.transact(fn _repo -> persist_output_items(subject_uid, output, opts) end) do
      {:ok, persisted} -> {:ok, Map.put(response, "output", persisted)}
      {:error, reason} -> {:error, Error.normalize_persistence(reason)}
    end
  end

  @spec observe(t(), map()) :: observation()
  def observe(%__MODULE__{} = state, %{} = event) do
    state = remember_response(state, event)

    case event do
      %{
        "type" => "response.image_generation_call.completed",
        "item_id" => item_id
      }
      when is_binary(item_id) ->
        {:ok, put_in(state.pending_completed[item_id], event), []}

      %{"type" => "response.image_generation_call.completed"} = event ->
        fail_completed_item(
          state,
          %{
            "id" => event["item_id"],
            "type" => "image_generation_call",
            "status" => "completed",
            "result" => nil
          },
          :invalid_completed_image
        )

      %{
        "type" => "response.output_item.done",
        "item" =>
          %{
            "type" => "image_generation_call",
            "id" => item_id,
            "status" => "completed",
            "result" => result
          } = item
      }
      when is_binary(item_id) and is_binary(result) ->
        persist_completed_item(state, event, item)

      %{
        "type" => "response.output_item.done",
        "item" =>
          %{
            "type" => "image_generation_call",
            "id" => item_id,
            "status" => "completed"
          } = item
      }
      when is_binary(item_id) ->
        fail_completed_item(state, item, :missing_completed_image_bytes)

      %{
        "type" => "response.output_item.done",
        "item" =>
          %{
            "type" => "image_generation_call",
            "status" => "completed"
          } = item
      } ->
        fail_completed_item(state, item, :invalid_completed_image)

      %{"type" => type}
      when type in ["response.completed", "response.failed", "response.incomplete"] ->
        cond do
          map_size(state.pending_completed) > 0 ->
            fail_pending_completion(state)

          item = unpersisted_terminal_image(state, event) ->
            fail_completed_item(state, item, :unpersisted_completed_image)

          true ->
            {:ok, remember_public_event(state, event), [event]}
        end

      _event ->
        {:ok, remember_public_event(state, event), [event]}
    end
  end

  @spec storage_items([map()]) :: [map()]
  def storage_items(items) when is_list(items), do: Enum.map(items, &storage_item/1)

  @spec storage_item(map()) :: map()
  def storage_item(%{"type" => "image_generation_call"} = item) do
    item
    |> Map.put("result", nil)
    |> Map.delete("mime_type")
  end

  def storage_item(item), do: item

  defp persist_output_items(subject_uid, output, opts) when is_list(output) do
    Enum.reduce_while(output, {:ok, []}, fn item, {:ok, acc} ->
      case persist_output_item(subject_uid, item, opts) do
        {:ok, persisted} -> {:cont, {:ok, [persisted | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, persisted} -> {:ok, Enum.reverse(persisted)}
      {:error, _reason} = error -> error
    end
  end

  defp persist_output_items(_subject_uid, _output, _opts), do: {:ok, []}

  defp persist_output_item(
         subject_uid,
         %{
           "type" => "image_generation_call",
           "id" => id,
           "status" => "completed",
           "result" => result
         } = item,
         opts
       )
       when is_binary(result) do
    mime_type = Map.get(item, "mime_type", Keyword.get(opts, :mime_type))

    with {:ok, _artifact} <-
           Artifacts.persist_generated_image(subject_uid, id, result, mime_type,
             message_id: Keyword.get(opts, :message_id)
           ) do
      {:ok, Map.drop(item, ["mime_type", "partial_images"])}
    end
  end

  defp persist_output_item(
         _subject_uid,
         %{"type" => "image_generation_call", "status" => "completed"},
         _opts
       ),
       do: {:error, :invalid_completed_image}

  defp persist_output_item(_subject_uid, item, _opts), do: {:ok, item}

  defp persist_completed_item(state, event, item) do
    opts = if is_binary(state.message_id), do: [message_id: state.message_id], else: []

    case persist_output_item(state.subject_uid, item, opts) do
      {:ok, _public_item} ->
        {completed, pending} = Map.pop(state.pending_completed, item["id"])
        events = if is_map(completed), do: [completed, event], else: [event]

        state =
          %{
            state
            | pending_completed: pending,
              persisted_image_ids: Map.put(state.persisted_image_ids, item["id"], true)
          }
          |> remember_public_events(events)

        {:ok, state, events}

      {:error, reason} ->
        fail_completed_item(state, item, reason)
    end
  end

  defp fail_pending_completion(state) do
    {item_id, _completed} =
      Enum.min_by(state.pending_completed, fn {_id, event} ->
        Map.get(event, "output_index", 0)
      end)

    fail_completed_item(
      state,
      %{
        "id" => item_id,
        "type" => "image_generation_call",
        "status" => "completed",
        "result" => nil
      },
      :missing_completed_image_bytes
    )
  end

  defp fail_completed_item(state, item, reason) do
    error = Error.normalize_persistence(reason)
    events = failure_events(state, item, error)
    state = %{remember_public_events(state, events) | pending_completed: %{}}
    {:error, state, events, error}
  end

  defp unpersisted_terminal_image(state, event) do
    event
    |> get_in(["response", "output"])
    |> list_items()
    |> Enum.find(fn
      %{
        "type" => "image_generation_call",
        "status" => "completed"
      } = item ->
        case item["id"] do
          item_id when is_binary(item_id) ->
            not Map.has_key?(state.persisted_image_ids, item_id)

          _invalid_id ->
            true
        end

      _item ->
        false
    end)
  end

  defp list_items(items) when is_list(items), do: items
  defp list_items(_items), do: []

  defp remember_response(state, %{"type" => "response.created", "response" => %{} = response}),
    do: %{state | response: response}

  defp remember_response(state, _event), do: state

  defp remember_public_events(state, events),
    do: Enum.reduce(events, state, &remember_public_event(&2, &1))

  defp remember_public_event(
         state,
         %{
           "type" => "response.output_item.done",
           "output_index" => output_index,
           "item" => %{} = item
         } = event
       )
       when is_integer(output_index) and output_index >= 0 do
    state
    |> Map.update!(:output_items, &Map.put(&1, output_index, item))
    |> remember_public_sequence(event)
  end

  defp remember_public_event(state, event), do: remember_public_sequence(state, event)

  defp remember_public_sequence(state, %{"sequence_number" => sequence})
       when is_integer(sequence) and sequence >= 0,
       do: %{state | last_public_sequence: max(state.last_public_sequence, sequence)}

  defp remember_public_sequence(state, _event), do: state

  defp failure_events(state, item, error) do
    output_index = output_index_for(state, item["id"])
    first_sequence = state.last_public_sequence + 1

    failed_item =
      item
      |> Map.put("status", "failed")
      |> Map.put("result", nil)
      |> Map.delete("mime_type")

    output =
      state.output_items
      |> Map.put(output_index, failed_item)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    failed_response =
      (state.response || %{})
      |> Map.put_new("id", nil)
      |> Map.put_new("object", "response")
      |> Map.put("status", "failed")
      |> Map.put("completed_at", nil)
      |> Map.put("output", output)
      |> Map.put("error", OpenAIError.envelope(error)["error"])

    [
      %{
        "type" => "response.output_item.done",
        "sequence_number" => first_sequence,
        "output_index" => output_index,
        "item" => failed_item
      },
      %{
        "type" => "response.failed",
        "sequence_number" => first_sequence + 1,
        "response" => failed_response
      }
    ]
  end

  defp output_index_for(state, item_id) do
    state.pending_completed
    |> Map.get(item_id, %{})
    |> Map.get("output_index", 0)
  end
end
