defmodule Ankole.Plugins.DiscordAdapter.Dispatcher do
  @moduledoc """
  Routes one gateway dispatch event to the ingress projection.

  The session owner asks `handled?/1` before it spends a task on an event, so
  the list of interesting event names stays in one place.
  """

  alias Ankole.Plugins.DiscordAdapter.{Client, Inbound}

  @message_component_interaction 3
  @deferred_update_callback 6

  @handled [
    "MESSAGE_CREATE",
    "MESSAGE_REACTION_ADD",
    "MESSAGE_REACTION_REMOVE",
    "INTERACTION_CREATE"
  ]

  @spec handled?(String.t()) :: boolean()
  def handled?(type) when is_binary(type), do: type in @handled
  def handled?(_type), do: false

  @doc false
  @spec acknowledge(String.t(), map(), Client.t()) :: :ok
  def acknowledge(
        "INTERACTION_CREATE",
        %{"type" => @message_component_interaction, "id" => id, "token" => token},
        %Client{} = client
      )
      when is_binary(id) and is_binary(token) do
    _result =
      Client.post(client, "/interactions/#{id}/#{token}/callback", %{
        "type" => @deferred_update_callback
      })

    :ok
  end

  def acknowledge(_type, _data, _client), do: :ok

  @spec dispatch(String.t(), map(), map(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def dispatch(type, data, consumer, bot, opts \\ [])

  def dispatch("MESSAGE_CREATE", data, consumer, bot, opts) do
    Inbound.handle_message_receive("MESSAGE_CREATE", event(data, "message", bot, opts), [consumer])
  end

  def dispatch("MESSAGE_REACTION_ADD", data, consumer, bot, opts) do
    Inbound.handle_reaction_created(
      "MESSAGE_REACTION_ADD",
      event(data, "reaction", bot, opts),
      [consumer]
    )
  end

  def dispatch("MESSAGE_REACTION_REMOVE", data, consumer, bot, opts) do
    Inbound.handle_reaction_deleted(
      "MESSAGE_REACTION_REMOVE",
      event(data, "reaction", bot, opts),
      [consumer]
    )
  end

  # Discord delivers every interaction on the same event. Only a message
  # component carries an Ankole action token; slash commands and modals belong
  # to features this adapter does not declare.
  def dispatch(
        "INTERACTION_CREATE",
        %{"type" => @message_component_interaction} = data,
        consumer,
        bot,
        opts
      ) do
    Inbound.handle_card_action("INTERACTION_CREATE", event(data, "interaction", bot, opts), [
      consumer
    ])
  end

  def dispatch(_type, _data, _consumer, _bot, _opts),
    do: {:ok, %{status: :ignored_unsupported_event}}

  defp event(data, key, bot, opts) do
    %{
      key => data,
      "bot" => bot,
      "client" => Keyword.get(opts, :client),
      "gateway_session_id" => Keyword.get(opts, :gateway_session_id),
      "gateway_sequence" => Keyword.get(opts, :gateway_sequence)
    }
  end
end
