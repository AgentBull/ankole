defmodule Ankole.Plugins.LarkAdapter.Outbox do
  @moduledoc """
  SignalsGateway outbox adapter for Lark / Feishu provider-visible output.
  """

  @behaviour Ankole.SignalsGateway.OutboxAdapter

  import Ecto.Query, warn: false

  alias Ankole.Plugins.LarkAdapter.Card
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Emoji
  alias Ankole.Repo
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.SignalBinding
  alias FeishuOpenAPI.Error

  @impl true
  def capabilities do
    [
      :post_entry,
      :reply_entry,
      :edit_entry,
      :delete_entry,
      :add_reaction,
      :remove_reaction,
      :divider,
      :card,
      :outbound_reconciliation
    ]
  end

  @impl true
  def send(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config),
         {:ok, request} <- request_for_outbox(outbox) do
      request
      |> perform(client)
      |> maybe_reply_fallback(client, outbox, request)
    end
  end

  @impl true
  def reconcile(%OutboxEntry{provider_entry_id: nil}), do: :unknown

  def reconcile(%OutboxEntry{} = outbox) do
    with {:ok, config} <- config_for_outbox(outbox),
         client <- Config.client(config) do
      case FeishuOpenAPI.get(client, "im/v1/messages/:message_id",
             path_params: %{message_id: outbox.provider_entry_id}
           ) do
        {:ok, body} ->
          {:ok,
           %{
             provider_entry_id: outbox.provider_entry_id,
             raw_payload: body,
             recovery_state: %{"exists" => true}
           }}

        {:error, %Error{} = error} ->
          case error_not_found?(error) do
            true -> :unknown
            false -> {:error, error}
          end
      end
    end
  end

  @doc """
  Builds the provider REST request for an outbox row without sending it.
  """
  @spec request_for_outbox(OutboxEntry.t()) :: {:ok, map()} | {:error, term()}
  def request_for_outbox(%OutboxEntry{operation: :post} = outbox) do
    {:ok, message_request(:post, "im/v1/messages", outbox, text_body(outbox))}
  end

  def request_for_outbox(%OutboxEntry{operation: :reply} = outbox) do
    {:ok,
     message_request(:post, "im/v1/messages", outbox, text_body(outbox),
       reply_to: outbox.source_provider_entry_id
     )}
  end

  def request_for_outbox(%OutboxEntry{operation: :edit} = outbox) do
    {:ok,
     %{
       method: :put,
       path: "im/v1/messages/:message_id",
       path_params: %{message_id: outbox.target_provider_entry_id},
       body: text_body(outbox)
     }}
  end

  def request_for_outbox(%OutboxEntry{operation: :delete} = outbox) do
    {:ok,
     %{
       method: :delete,
       path: "im/v1/messages/:message_id",
       path_params: %{message_id: outbox.target_provider_entry_id}
     }}
  end

  def request_for_outbox(%OutboxEntry{operation: operation} = outbox)
      when operation in [:reaction_add, :reaction_remove] do
    reaction_key =
      outbox.payload
      |> fetch_value("reaction_key")
      |> Emoji.provider_key()

    request =
      case operation do
        :reaction_add ->
          %{
            method: :post,
            path: "im/v1/messages/:message_id/reactions",
            path_params: %{message_id: outbox.target_provider_entry_id},
            body: %{reaction_type: %{emoji_type: reaction_key}}
          }

        :reaction_remove ->
          %{
            method: :delete,
            path: "im/v1/messages/:message_id/reactions/:reaction_id",
            path_params: %{
              message_id: outbox.target_provider_entry_id,
              reaction_id: reaction_key
            }
          }
      end

    {:ok, request}
  end

  def request_for_outbox(%OutboxEntry{operation: :divider} = outbox) do
    text =
      outbox.fallback_visible_text
      |> to_string()
      |> String.trim()
      |> String.slice(0, 20)

    body = %{
      msg_type: "system",
      content: Card.system_divider_content(text, divider_i18n(outbox.payload))
    }

    {:ok, message_request(:post, "im/v1/messages", outbox, body)}
  end

  def request_for_outbox(%OutboxEntry{operation: :card} = outbox) do
    with {:ok, card} <- Card.render(outbox.payload) do
      body = %{
        receive_id: chat_id_from_channel(outbox.signal_channel_id),
        msg_type: "interactive",
        content: Card.message_content(card)
      }

      {:ok,
       message_request(:post, "im/v1/messages", outbox, body,
         reply_to: outbox.source_provider_entry_id
       )}
    end
  end

  def request_for_outbox(_outbox), do: {:error, :unsupported_outbox_operation}

  defp perform(%{method: method, path: path} = request, client) do
    opts =
      request
      |> Map.take([:body, :query, :path_params])
      |> Enum.to_list()

    client
    |> FeishuOpenAPI.request(method, path, opts)
    |> normalize_send_response()
  end

  defp maybe_reply_fallback({:error, %Error{} = error}, client, outbox, %{reply_to: reply_to})
       when is_binary(reply_to) do
    case target_gone_error?(error) do
      true ->
        # Lark rejects replies after the target disappears. Posting as a new
        # message preserves operator-visible output instead of losing the outbox.
        :post
        |> message_request("im/v1/messages", outbox, text_body(outbox))
        |> perform(client)

      false ->
        {:error, error}
    end
  end

  defp maybe_reply_fallback(result, _client, _outbox, _request), do: result

  @doc false
  @spec target_gone_error?(Error.t()) :: boolean()
  def target_gone_error?(%Error{code: code, msg: msg}) do
    code in [23_000, 23_002, 23_006] or
      (is_binary(msg) and String.contains?(String.downcase(msg), ["withdraw", "not exist", "not found"]))
  end

  defp normalize_send_response({:ok, %{"data" => data} = body}) when is_map(data) do
    {:ok,
     %{
       provider_entry_id: data["message_id"],
       provider_thread_id: data["root_id"],
       raw_payload: body
     }
     |> compact_map()}
  end

  defp normalize_send_response({:ok, body}), do: {:ok, %{raw_payload: body}}
  defp normalize_send_response({:error, reason}), do: {:error, reason}

  defp message_request(method, path, outbox, body, opts \\ []) do
    reply_to = Keyword.get(opts, :reply_to)
    path = if is_binary(reply_to), do: "im/v1/messages/:message_id/reply", else: path
    path_params = Keyword.get(opts, :path_params, %{})
    path_params = if is_binary(reply_to), do: Map.put(path_params, :message_id, reply_to), else: path_params

    base_body = maybe_put(body, :uuid, outbox.idempotency_key)

    # Replies and new messages use different Lark API shapes. Keeping the branch
    # here makes every outbox operation share one idempotency/body path.
    case reply_to do
      value when is_binary(value) ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          body: base_body,
          reply_to: reply_to
        }

      _value ->
        %{
          method: method,
          path: path,
          path_params: path_params,
          query: [receive_id_type: "chat_id"],
          body: maybe_put(base_body, :receive_id, chat_id_from_channel(outbox.signal_channel_id)),
          reply_to: reply_to
        }
    end
  end

  defp text_body(%{fallback_visible_text: text}) when is_binary(text) do
    %{msg_type: "text", content: Card.text_content(text)}
  end

  defp text_body(_outbox), do: %{msg_type: "text", content: Card.text_content("")}

  defp divider_i18n(%{"i18n" => i18n}) when is_map(i18n) do
    i18n
    |> Enum.flat_map(fn
      {locale, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> []
          text -> [{to_string(locale), String.slice(text, 0, 20)}]
        end

      _entry ->
        []
    end)
    |> Map.new()
  end

  defp divider_i18n(_payload), do: nil

  defp config_for_outbox(%OutboxEntry{} = outbox) do
    with %SignalBinding{} = binding <- binding_for_outbox(outbox),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      {:ok, config}
    else
      nil -> {:error, :binding_not_found}
      :error -> {:error, :binding_config_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp binding_for_outbox(outbox) do
    Repo.one(
      from binding in SignalBinding,
        where: binding.agent_uid == ^outbox.agent_uid and binding.name == ^outbox.binding_name
    )
  end

  defp chat_id_from_channel("lark:" <> encoded), do: URI.decode(encoded)
  defp chat_id_from_channel(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_value(map, key) when is_map(map) do
    atom_key = atom_key(key)

    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      not is_nil(atom_key) and Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)

      true -> nil
    end
  end

  defp atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp compact_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp error_not_found?(%Error{} = error), do: target_gone_error?(error)
end
