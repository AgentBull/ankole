defmodule BullX.AIAgent.Message do
  @moduledoc """
  Durable AIAgent transcript row.

  Message content is BullX-normalized evidence. It must not contain raw
  CloudEvents, raw provider payloads, credentials, bearer-like reply handles, or
  MailboxSession output stream chunks.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias BullX.AIAgent.Conversation
  alias BullX.Principals.Agent

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @roles [:user, :assistant, :tool, :im_ambient]
  @kinds [:normal, :summary, :introspection, :error]
  @statuses [:generating, :complete]

  @block_types ~w(
    text
    tool_call
    tool_result
    error
    summary_text
    human_steering_note
    omitted_marker
  )

  @type role :: :user | :assistant | :tool | :im_ambient
  @type kind :: :normal | :summary | :introspection | :error
  @type status :: :generating | :complete
  @type t :: %__MODULE__{}

  schema "conversation_messages" do
    belongs_to :agent, Agent, foreign_key: :agent_uid, references: :uid, type: :string
    belongs_to :conversation, Conversation
    field :role, Ecto.Enum, values: @roles
    field :kind, Ecto.Enum, values: @kinds
    field :status, Ecto.Enum, values: @statuses
    field :content, BullX.Ecto.JSONB, default: []
    field :covers_range, :map
    field :mailbox_queue_key, :string
    field :event_source, :string
    field :event_id, :string
    field :metadata, :map, default: %{}

    timestamps()
  end

  @spec roles() :: [role()]
  def roles, do: @roles

  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :agent_uid,
      :role,
      :kind,
      :status,
      :content,
      :covers_range,
      :mailbox_queue_key,
      :event_source,
      :event_id,
      :metadata
    ])
    |> validate_required([
      :conversation_id,
      :agent_uid,
      :role,
      :kind,
      :status,
      :content,
      :metadata
    ])
    |> validate_valid_combination()
    |> validate_content_blocks()
    |> validate_summary_contract()
    |> validate_json_object(:metadata)
    |> validate_optional_json_object(:covers_range)
    |> foreign_key_constraint(:agent_uid)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint([:conversation_id, :event_source, :event_id],
      name: :conversation_messages_inbound_event_unique_index
    )
    |> unique_constraint(:metadata, name: :conversation_messages_ambient_batch_unique_index)
    |> check_constraint(:content, name: :conversation_messages_content_array)
    |> check_constraint(:metadata, name: :conversation_messages_metadata_object)
    |> check_constraint(:covers_range, name: :conversation_messages_covers_range_object)
    |> check_constraint(:role, name: :conversation_messages_valid_role_kind_status)
    |> check_constraint(:metadata, name: :conversation_messages_summary_contract)
  end

  @spec text_block(String.t()) :: map()
  def text_block(text) when is_binary(text), do: %{"type" => "text", "text" => text}

  @spec error_block(String.t(), String.t(), boolean()) :: map()
  def error_block(code, message, retryable)
      when is_binary(code) and is_binary(message) and is_boolean(retryable) do
    %{
      "type" => "error",
      "code" => code,
      "message" => message,
      "retryable" => retryable
    }
  end

  @spec tool_result_error_block(String.t(), String.t(), String.t()) :: map()
  def tool_result_error_block(tool_call_id, code, message)
      when is_binary(tool_call_id) and is_binary(code) and is_binary(message) do
    %{
      "type" => "tool_result",
      "tool_call_id" => tool_call_id,
      "is_error" => true,
      "error" => %{
        "code" => code,
        "message" => message,
        "retryable" => false
      }
    }
  end

  defp validate_valid_combination(changeset) do
    role = get_field(changeset, :role)
    kind = get_field(changeset, :kind)
    status = get_field(changeset, :status)

    case valid_combination?(role, kind, status) do
      true -> changeset
      false -> add_error(changeset, :role, "has invalid role/kind/status combination")
    end
  end

  defp valid_combination?(:user, :normal, :complete), do: true
  defp valid_combination?(:user, :introspection, :complete), do: true
  defp valid_combination?(:assistant, :normal, status), do: status in [:generating, :complete]
  defp valid_combination?(:assistant, :summary, :complete), do: true
  defp valid_combination?(:assistant, :error, :complete), do: true
  defp valid_combination?(:tool, :normal, :complete), do: true
  defp valid_combination?(:im_ambient, :normal, :complete), do: true
  defp valid_combination?(:im_ambient, :introspection, :complete), do: true
  defp valid_combination?(_role, _kind, _status), do: false

  defp validate_content_blocks(changeset) do
    validate_change(changeset, :content, fn :content, content ->
      case content_errors(content) do
        [] -> []
        errors -> [content: Enum.join(errors, ", ")]
      end
    end)
  end

  defp content_errors(content) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, index} -> block_errors(block, index) end)
  end

  defp content_errors(_content), do: ["must be a JSON array"]

  defp block_errors(%{"type" => type} = block, index) when type in @block_types do
    required_errors =
      type
      |> required_keys_for()
      |> Enum.flat_map(fn key ->
        case Map.has_key?(block, key) do
          true -> []
          false -> ["block #{index} missing #{key}"]
        end
      end)

    required_errors ++ typed_block_errors(type, block, index)
  end

  defp block_errors(%{type: type} = block, index) when is_atom(type) do
    block
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> block_errors(index)
  end

  defp block_errors(_block, index), do: ["block #{index} has invalid type"]

  defp required_keys_for("text"), do: ["text"]
  defp required_keys_for("tool_call"), do: ["tool_call_id", "name", "arguments"]
  defp required_keys_for("tool_result"), do: ["tool_call_id", "is_error"]
  defp required_keys_for("error"), do: ["code", "message", "retryable"]
  defp required_keys_for("summary_text"), do: ["text"]
  defp required_keys_for("human_steering_note"), do: ["text", "command_entry_id"]
  defp required_keys_for("omitted_marker"), do: ["reason"]

  defp typed_block_errors("tool_result", %{"is_error" => true} = block, index) do
    case Map.has_key?(block, "error") and is_map(block["error"]) do
      true -> []
      false -> ["block #{index} missing error"]
    end
  end

  defp typed_block_errors("tool_result", %{"is_error" => false} = block, index) do
    case Map.has_key?(block, "result") do
      true -> []
      false -> ["block #{index} missing result"]
    end
  end

  defp typed_block_errors("tool_result", _block, index),
    do: ["block #{index} has invalid is_error"]

  defp typed_block_errors(_type, _block, _index), do: []

  defp validate_summary_contract(changeset) do
    role = get_field(changeset, :role)
    kind = get_field(changeset, :kind)

    case {role, kind} do
      {:assistant, :summary} ->
        changeset
        |> validate_required([:covers_range])
        |> validate_summary_range()
        |> validate_summary_content()
        |> validate_summary_metadata()

      _other ->
        changeset
    end
  end

  defp validate_summary_range(changeset) do
    case get_field(changeset, :covers_range) do
      %{"from_id" => from_id, "to_id" => to_id}
      when is_binary(from_id) and is_binary(to_id) and from_id != "" and to_id != "" ->
        changeset

      _other ->
        add_error(changeset, :covers_range, "must include from_id and to_id")
    end
  end

  defp validate_summary_content(changeset) do
    content = get_field(changeset, :content) || []

    case Enum.any?(content, fn
           %{"type" => "summary_text", "text" => text} when is_binary(text) and text != "" ->
             true

           _block ->
             false
         end) do
      true -> changeset
      false -> add_error(changeset, :content, "must include summary_text")
    end
  end

  defp validate_summary_metadata(changeset) do
    metadata = get_field(changeset, :metadata) || %{}

    cond do
      not is_binary(metadata["original_dialogue_time_range"]) ->
        add_error(changeset, :metadata, "must include original_dialogue_time_range")

      not is_map(metadata["compression"]) ->
        add_error(changeset, :metadata, "must include compression metadata")

      true ->
        changeset
    end
  end

  defp validate_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_map(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end

  defp validate_optional_json_object(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case is_nil(value) or is_map(value) do
        true -> []
        false -> [{field, "must be a JSON object"}]
      end
    end)
  end
end
