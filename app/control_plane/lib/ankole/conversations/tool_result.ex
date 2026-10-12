defmodule Ankole.Conversations.ToolResult do
  @moduledoc "A tool's model output and explicit local presentation effects."
  defstruct [
    :output,
    :final_text,
    :details,
    :failure_kind,
    :outcome,
    :cursor,
    :todos,
    is_error: false,
    terminate: false,
    presentation: [],
    web_cache: %{}
  ]

  @type t :: %__MODULE__{}

  @doc "Returns whether a successful terminating result ends the model turn."
  @spec ends_turn?(t()) :: boolean()
  def ends_turn?(%__MODULE__{} = result),
    do: result.terminate == true and result.is_error != true

  @doc "The fields that a recorded tool round keeps beside each output."
  @spec journal_fields(t()) :: map()
  def journal_fields(%__MODULE__{} = result),
    do:
      result |> encode() |> Map.take(~w(is_error terminate outcome failure_kind todos final_text))

  @spec encode(t() | {:await, Ankole.Conversations.Wait.t()}) :: map()
  def encode({:await, wait}), do: %{"wait" => Ankole.Conversations.Wait.encode(wait)}

  def encode(%__MODULE__{} = result) do
    result
    |> Map.from_struct()
    |> Map.drop([:web_cache])
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> encode_cursor(result.cursor)
    |> encode_outcome(result.outcome)
  end

  defp encode_outcome(value, nil), do: value

  defp encode_outcome(value, outcome),
    do: Map.put(value, "outcome", Ankole.Conversations.Outcome.encode(outcome))

  defp encode_cursor(value, nil), do: value

  defp encode_cursor(value, {subject, cursor}),
    do: Map.put(value, "cursor", %{"subject" => subject, "value" => cursor})

  @spec decode(map(), DateTime.t() | nil) :: t() | {:await, Ankole.Conversations.Wait.t()}
  def decode(value, inserted_at \\ nil)

  def decode(%{"wait" => wait}, inserted_at),
    do: {:await, Ankole.Conversations.Wait.decode(wait, inserted_at)}

  def decode(value, _inserted_at) do
    attrs =
      for key <- Map.keys(%__MODULE__{}) -- [:__struct__, :web_cache, :cursor],
          Map.has_key?(value, Atom.to_string(key)),
          into: %{},
          do: {key, value[Atom.to_string(key)]}

    cursor =
      case value["cursor"] do
        %{"subject" => subject, "value" => cursor} -> {subject, cursor}
        _ -> nil
      end

    attrs =
      if attrs[:outcome],
        do: Map.update!(attrs, :outcome, &Ankole.Conversations.Outcome.decode/1),
        else: attrs

    struct!(__MODULE__, Map.put(attrs, :cursor, cursor))
  end
end
