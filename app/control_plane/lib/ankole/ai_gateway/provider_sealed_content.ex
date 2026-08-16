defmodule Ankole.AIGateway.ProviderSealedContent do
  @moduledoc """
  Removes the state one Provider sealed before another Provider reads it.

  A Provider seals some of what it returns: reasoning `encrypted_content`, and
  the parameters a tool declared `encrypted`. Only the issuer can read those
  values, and a different Provider rejects the whole request instead of
  ignoring the parts it cannot read.

  The goal is a conversation that still runs after the Provider changes, not a
  conversation that keeps every byte. So this module separates structure from
  content. Messages, calls, outputs, and the pairing between them are
  structure, and they all survive. Sealed values are content, and they do not.
  Nothing here removes an item that another item pairs with, because an orphan
  call would break the history for every later turn.

  What the Agent loses is hidden reasoning it derives again, and the wording of
  a tool call that already ran. The result of that call stays, in plain text.
  """

  @unavailable "[unavailable: sealed by another provider]"

  @doc """
  Rewrites stored items that a different Provider sealed.

  `issuer` names the Provider that will read these items. Items without sealed
  state, and items the same Provider sealed, pass through unchanged.
  """
  @spec strip_foreign([map()], String.t() | nil, String.t() | nil) :: [map()]
  def strip_foreign(items, issuer, item_issuer)
      when is_list(items) and is_binary(issuer) and is_binary(item_issuer) and
             issuer != item_issuer do
    items
    |> Enum.reject(&whole_item_sealed?/1)
    |> Enum.map(&unseal_encrypted_arguments/1)
    |> strip()
  end

  def strip_foreign(items, _issuer, _item_issuer) when is_list(items), do: items

  @doc """
  Removes every Provider-sealed value from a term, at any depth.

  Sealed state appears at the top of an item and inside content parts, so this
  walks the whole term. A part that is nothing but sealed content is removed
  rather than emptied.
  """
  @spec strip(term()) :: term()
  def strip(%{"type" => "encrypted_content"}), do: nil

  def strip(%{} = value) do
    value
    |> Map.drop(["encrypted_content", "encrypted_function_args"])
    |> Map.new(fn {key, nested} -> {key, strip(nested)} end)
  end

  def strip(value) when is_list(value) do
    value
    |> Enum.map(&strip/1)
    |> Enum.reject(&is_nil/1)
  end

  def strip(value), do: value

  # An item whose whole purpose is sealed state leaves, because nothing pairs
  # with it and an emptied shell would carry no meaning to the next Provider.
  defp whole_item_sealed?(%{"type" => type} = item)
       when type in ["reasoning", "compaction", "context_compaction"],
       do: is_binary(item["encrypted_content"]) and item["encrypted_content"] != ""

  defp whole_item_sealed?(_item), do: false

  # A call names which of its parameters the Provider sealed. The call and its
  # output must both survive, so the item stays and only those parameters
  # become plain. The marker goes with them: nothing is encrypted anymore.
  defp unseal_encrypted_arguments(%{"encrypted_function_args" => names} = item)
       when is_list(names) and names != [] do
    item
    |> Map.delete("encrypted_function_args")
    |> redact_sealed_parameters(names)
  end

  defp unseal_encrypted_arguments(item), do: item

  # Only a field the item already has can hold sealed parameters. Adding one
  # would invent a parameter the call never had.
  defp redact_sealed_parameters(item, names) do
    Enum.reduce(["arguments", "input"], item, fn field, item ->
      case Map.fetch(item, field) do
        {:ok, value} -> Map.put(item, field, redact_arguments(value, names))
        :error -> item
      end
    end)
  end

  defp redact_arguments(arguments, names) when is_binary(arguments) do
    case Ankole.JSON.decode(arguments) do
      {:ok, %{} = decoded} ->
        decoded
        |> Map.new(fn {key, value} ->
          if key in names, do: {key, @unavailable}, else: {key, value}
        end)
        |> Ankole.JSON.encode!()

      # Arguments AIGateway cannot read cannot be repaired one field at a time,
      # so the whole value becomes plain rather than staying unreadable.
      _unreadable ->
        Ankole.JSON.encode!(Map.new(names, &{&1, @unavailable}))
    end
  end

  defp redact_arguments(_arguments, names),
    do: Ankole.JSON.encode!(Map.new(names, &{&1, @unavailable}))
end
