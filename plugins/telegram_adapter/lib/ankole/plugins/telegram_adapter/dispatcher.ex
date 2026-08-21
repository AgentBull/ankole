defmodule Ankole.Plugins.TelegramAdapter.Dispatcher do
  @moduledoc false

  alias Ankole.Plugins.TelegramAdapter.Inbound

  @spec process_updates([map()], map(), map(), integer() | nil, keyword()) ::
          {:ok, integer() | nil} | {:error, term(), integer() | nil}
  def process_updates(updates, consumer, bot, offset, opts \\ []) when is_list(updates) do
    dispatch_fun = Keyword.get(opts, :dispatch, &dispatch/4)

    updates
    |> Enum.sort_by(&Map.get(&1, "update_id", -1))
    |> Enum.reduce_while({:ok, offset}, fn update, {:ok, next_offset} ->
      case Map.get(update, "update_id") do
        update_id when is_integer(update_id) ->
          case dispatch_fun.(update, consumer, bot, opts) do
            {:ok, _result} -> {:cont, {:ok, update_id + 1}}
            {:error, reason} -> {:halt, {:error, reason, next_offset}}
          end

        _missing ->
          {:halt, {:error, :missing_update_id, next_offset}}
      end
    end)
  end

  @spec dispatch(map(), map(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(%{"message" => message, "update_id" => update_id}, consumer, bot, _opts)
      when is_map(message) do
    Inbound.handle_message_receive(
      "message",
      %{"update_id" => update_id, "message" => message, "bot" => bot},
      [consumer]
    )
  end

  def dispatch(
        %{"message_reaction" => reaction, "update_id" => update_id},
        consumer,
        bot,
        _opts
      )
      when is_map(reaction) do
    Inbound.handle_reaction_update(
      "message_reaction",
      %{"update_id" => update_id, "message_reaction" => reaction, "bot" => bot},
      [consumer]
    )
  end

  def dispatch(%{"callback_query" => callback, "update_id" => update_id}, consumer, bot, opts)
      when is_map(callback) do
    Inbound.handle_card_action(
      "callback_query",
      %{
        "update_id" => update_id,
        "callback_query" => callback,
        "bot" => bot,
        "client" => Keyword.get(opts, :client)
      },
      [consumer]
    )
  end

  def dispatch(_unsupported, _consumer, _bot, _opts),
    do: {:ok, %{status: :ignored_unsupported_update}}
end
