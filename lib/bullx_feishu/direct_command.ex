defmodule BullXFeishu.DirectCommand do
  @moduledoc """
  Adapter-local Feishu slash commands.

  `/ping`, `/preauth`, and `/web_auth` are handled before Gateway inbound
  publish. They intentionally keep account-linking side effects outside the
  Runtime signal stream.
  """

  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Content
  alias BullXFeishu.{Cache, Config}

  @type command :: %{
          name: String.t(),
          args: String.t(),
          event_id: String.t(),
          channel: BullXGateway.Delivery.channel(),
          channel_id: String.t(),
          chat_id: String.t(),
          chat_type: String.t() | nil,
          thread_id: String.t() | nil,
          message_id: String.t() | nil,
          actor: map(),
          account_input: map(),
          source: String.t()
        }

  @spec parse(String.t() | nil) :: {:ok, map()} | :error
  def parse(text) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [name | rest] <- String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         true <- name != "" do
      {:ok, %{name: name, args: Enum.join(rest, " ")}}
    else
      _ -> :error
    end
  end

  def parse(_), do: :error

  @spec handle(command(), Config.t(), Cache.t()) ::
          {:ok, term(), Cache.t()} | {:error, map(), Cache.t()}
  def handle(%{event_id: event_id} = command, %Config{} = config, %Cache{} = cache) do
    case Cache.fetch_direct_result(cache, event_id) do
      {:ok, result} ->
        {:ok, {:duplicate, result}, cache}

      :error ->
        run(command, config, cache)
    end
  end

  @spec reply_text(command(), Config.t(), Cache.t(), String.t(), String.t()) ::
          {:ok, term(), Cache.t()} | {:error, map(), Cache.t()}
  def reply_text(command, config, cache, text, command_name) do
    reply_and_cache(command, config, cache, text, command_name)
  end

  defp run(%{name: "ping"} = command, config, cache) do
    reply_and_cache(command, config, cache, BullX.I18n.t("gateway.feishu.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", chat_type: chat_type} = command, config, cache)
       when chat_type != "p2p" do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.feishu.auth.direct_command_dm_only"),
      "preauth"
    )
  end

  defp run(%{name: "preauth", args: args} = command, config, cache) do
    code = args |> to_string() |> String.trim()

    text =
      case config.accounts_module.consume_activation_code(code, command.account_input) do
        {:ok, _user, _binding} ->
          BullX.I18n.t("gateway.feishu.auth.activation_success")

        {:error, :invalid_or_expired_code} ->
          BullX.I18n.t("gateway.feishu.auth.activation_code_invalid")

        {:error, :already_bound} ->
          BullX.I18n.t("gateway.feishu.auth.already_linked")

        {:error, :user_banned} ->
          BullX.I18n.t("gateway.feishu.auth.denied")

        {:error, _} ->
          BullX.I18n.t("gateway.feishu.auth.activation_failed")
      end

    reply_and_cache(command, config, cache, text, "preauth")
  end

  defp run(%{name: "web_auth", chat_type: chat_type} = command, config, cache)
       when chat_type != "p2p" do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.feishu.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, config, cache) do
    external_id = command.actor.id

    text =
      case Config.web_login_allowed?(config) do
        true ->
          issue_web_auth_code(config, external_id)

        false ->
          BullX.I18n.t("gateway.feishu.auth.web_auth_disabled")
      end

    reply_and_cache(command, config, cache, text, "web_auth")
  end

  defp run(command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.feishu.errors.unsupported_message"),
      command.name
    )
  end

  defp issue_web_auth_code(config, external_id) do
    case config.accounts_module.issue_user_channel_auth_code(
           :feishu,
           config.channel_id,
           external_id
         ) do
      {:ok, code} ->
        BullX.I18n.t("gateway.feishu.auth.web_auth_created", %{
          code: code,
          login_url: web_login_url(config)
        })

      {:error, :not_bound} ->
        BullX.I18n.t("gateway.feishu.auth.web_auth_not_bound")

      {:error, :user_banned} ->
        BullX.I18n.t("gateway.feishu.auth.denied")

      {:error, _} ->
        BullX.I18n.t("gateway.feishu.auth.web_auth_failed")
    end
  end

  defp reply_and_cache(command, config, cache, text, command_name) do
    delivery = reply_delivery(command, text, command_name)

    case config.gateway_module.deliver(delivery) do
      {:ok, delivery_id} ->
        result = %{delivery_id: delivery_id, command_name: command_name}
        cache = Cache.put_direct_result(cache, command.event_id, result, config.dedupe_ttl_ms)
        {:ok, result, cache}

      {:error, reason} ->
        {:error, BullXFeishu.Error.map(reason), cache}
    end
  end

  defp reply_delivery(command, text, command_name) do
    %Delivery{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: command.channel,
      scope_id: command.chat_id,
      thread_id: command.thread_id,
      reply_to_external_id: command.message_id,
      content: %Content{kind: :text, body: %{"text" => text}},
      extensions: %{
        "feishu" => %{
          "direct_command" => command_name,
          "event_id" => command.event_id
        }
      }
    }
  end

  defp web_login_url(%Config{sso: %{login_url: login_url}}) when is_binary(login_url),
    do: login_url

  defp web_login_url(%Config{channel_id: channel_id}) do
    "/sessions/feishu?channel_id=#{URI.encode_www_form(channel_id)}"
  end
end
