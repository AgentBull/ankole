defmodule Ankole.Plugins.LarkAdapter.CardKit.CardChain do
  @moduledoc """
  Durable shape for one logical reply spanning ordered CardKit cards.

  The top-level provider fields always mirror the active tail card because the
  existing recovery scheduler reasons about the reply as one lifecycle. The
  `cards` list is the durable page ledger used to seal prior cards and resume a
  tail after an Ankole process restart.
  """

  alias Ankole.Plugins.LarkAdapter.CardKit.MarkdownSegmenter

  @page_source_bytes 12 * 1_024
  # Feishu renders at most four Markdown tables in one rich-text element, so
  # one page carries at most four answer tables.
  @page_tables 4

  @spec pages(map() | String.t()) :: [MarkdownSegmenter.page()]
  def pages(%{} = presentation), do: pages(presentation["answer"] || "")

  def pages(answer) when is_binary(answer),
    do: MarkdownSegmenter.pages(answer, max_bytes: @page_source_bytes, max_tables: @page_tables)

  @spec cards(map()) :: [map()]
  def cards(%{"cards" => cards}) when is_list(cards) and cards != [] do
    cards
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&non_negative_integer(&1["index"]))
  end

  def cards(checkpoint) when is_map(checkpoint) do
    case checkpoint["card_id"] do
      card_id when is_binary(card_id) and card_id != "" ->
        [
          %{
            "index" => 0,
            "card_id" => card_id,
            "message_id" => checkpoint["message_id"],
            "message_uuid" => checkpoint["message_uuid"],
            "state" => card_state(checkpoint["streaming_state"]),
            "streaming_state" => checkpoint["streaming_state"] || "open",
            "answer_content" => checkpoint["answer_content"] || "",
            "answer_source" => checkpoint["answer_content"] || "",
            "element_ids" => checkpoint["element_ids"] || []
          }
        ]

      _missing ->
        []
    end
  end

  @spec active_index(map()) :: non_neg_integer()
  def active_index(checkpoint) when is_map(checkpoint) do
    cards = cards(checkpoint)
    requested = non_negative_integer(checkpoint["active_card_index"])

    if Enum.any?(cards, &(&1["index"] == requested)) do
      requested
    else
      cards |> List.last() |> then(&if(&1, do: &1["index"], else: 0))
    end
  end

  @spec active_card(map()) :: map() | nil
  def active_card(checkpoint) when is_map(checkpoint) do
    index = active_index(checkpoint)
    Enum.find(cards(checkpoint), &(&1["index"] == index))
  end

  @spec initialize(map(), map()) :: map()
  def initialize(checkpoint, card) when is_map(checkpoint) and is_map(card) do
    checkpoint
    |> Map.put("cards", [card])
    |> Map.put("active_card_index", card["index"] || 0)
    |> sync_active()
  end

  @spec append(map(), map()) :: map()
  def append(checkpoint, card) when is_map(checkpoint) and is_map(card) do
    cards =
      checkpoint
      |> cards()
      |> Enum.reject(&(&1["index"] == card["index"]))
      |> Kernel.++([card])
      |> Enum.sort_by(& &1["index"])

    checkpoint
    |> Map.put("cards", cards)
    |> Map.put("active_card_index", card["index"])
    |> sync_active()
  end

  @spec update_card(map(), non_neg_integer(), (map() -> map())) :: map()
  def update_card(checkpoint, index, fun)
      when is_map(checkpoint) and is_integer(index) and is_function(fun, 1) do
    cards =
      checkpoint
      |> cards()
      |> Enum.map(fn card -> if card["index"] == index, do: fun.(card), else: card end)

    checkpoint
    |> Map.put("cards", cards)
    |> sync_active()
  end

  @spec sync_active(map()) :: map()
  def sync_active(checkpoint) when is_map(checkpoint) do
    cards = cards(checkpoint)
    checkpoint = Map.put(checkpoint, "cards", cards)

    case active_card(checkpoint) do
      nil ->
        checkpoint

      active ->
        checkpoint
        |> put_or_delete("card_id", active["card_id"])
        |> put_or_delete("message_id", active["message_id"])
        |> put_or_delete("message_uuid", active["message_uuid"])
        |> Map.put("streaming_state", active["streaming_state"] || "open")
        |> Map.put("answer_content", active["answer_content"] || "")
        |> Map.put("element_ids", active["element_ids"] || [])
    end
  end

  @spec page_opts(MarkdownSegmenter.page(), non_neg_integer(), pos_integer(), boolean()) ::
          keyword()
  def page_opts(page, index, count, tail?) when is_map(page) do
    [
      answer: page.content,
      page_index: index,
      page_count: max(count, index + 1),
      page_tail: tail?
    ]
  end

  @spec card_record(
          non_neg_integer(),
          String.t(),
          String.t(),
          MarkdownSegmenter.page(),
          String.t(),
          [String.t()]
        ) :: map()
  def card_record(index, card_id, message_uuid, page, state, element_ids)
      when is_integer(index) and is_binary(card_id) and is_binary(message_uuid) and
             is_map(page) do
    streaming_state = if state == "open", do: "open", else: "closed"

    %{
      "index" => index,
      "card_id" => card_id,
      "message_uuid" => message_uuid,
      "state" => state,
      "streaming_state" => streaming_state,
      "answer_start_byte" => page.start_byte,
      "answer_end_byte" => page.end_byte,
      "answer_source" => page.source,
      "answer_digest" => digest(page.source),
      "answer_content" => page.content,
      "element_ids" => element_ids
    }
  end

  @spec sealed_prefix(map()) :: String.t()
  def sealed_prefix(checkpoint) when is_map(checkpoint) do
    checkpoint
    |> cards()
    |> Enum.filter(&(&1["state"] == "sealed"))
    |> Enum.map_join(&(&1["answer_source"] || ""))
  end

  @spec page_at([MarkdownSegmenter.page()], non_neg_integer()) :: MarkdownSegmenter.page()
  def page_at(pages, index) when is_list(pages) and is_integer(index) do
    Enum.at(pages, index) || empty_page()
  end

  @spec digest(binary()) :: String.t()
  def digest(value) when is_binary(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  end

  defp empty_page, do: %{source: "", content: " ", start_byte: 0, end_byte: 0}

  defp card_state("closed"), do: "closed"
  defp card_state("replaced"), do: "replaced"
  defp card_state(_state), do: "open"

  defp put_or_delete(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_or_delete(map, key, _value), do: Map.delete(map, key)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
end
