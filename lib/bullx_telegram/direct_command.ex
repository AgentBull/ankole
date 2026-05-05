defmodule BullXTelegram.DirectCommand do
  @moduledoc """
  Adapter-local Telegram slash commands.

  `/ping`, `/preauth`, and `/web_auth` are handled before Gateway inbound
  publish. `/ask` is mapped to Gateway only when it carries a non-empty prompt.
  """

  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Content
  alias BullXTelegram.{Cache, Config, Error}

  @type command :: map()

  @spec parse(String.t() | nil, Config.t() | nil) :: {:ok, map()} | :error
  def parse(text, config \\ nil)

  def parse(text, config) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [raw_name | rest] <- String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         {:ok, name} <- normalize_command_name(raw_name, config),
         true <- name != "" do
      {:ok, %{name: name, args: Enum.join(rest, " ")}}
    else
      _ -> :error
    end
  end

  def parse(_text, _config), do: :error

  @spec strip_command_prefix(String.t(), Config.t()) :: {:ok, String.t(), String.t()} | :error
  def strip_command_prefix(text, %Config{} = config) when is_binary(text) do
    with {:ok, %{name: name, args: args}} <- parse(text, config) do
      {:ok, name, String.trim(args)}
    end
  end

  def strip_command_prefix(_text, %Config{}), do: :error

  @spec handle(command(), Config.t(), Cache.t()) ::
          {:ok, term(), Cache.t()} | {:error, map(), Cache.t()}
  def handle(%{event_id: event_id} = command, %Config{} = config, %Cache{} = cache) do
    case Cache.fetch_direct_result(cache, event_id) do
      {:ok, result} ->
        {:ok, %{duplicate: true, result: result}, cache}

      :error ->
        run(command, config, cache)
    end
  end

  @spec reply_text(command(), Config.t(), Cache.t(), String.t(), String.t()) ::
          {:ok, term(), Cache.t()} | {:error, map(), Cache.t()}
  def reply_text(command, config, cache, text, command_name) do
    reply_and_cache(command, config, cache, text, command_name)
  end

  defp normalize_command_name(raw_name, config) do
    case String.split(raw_name, "@", parts: 2) do
      [name] ->
        {:ok, String.downcase(name)}

      [name, bot_username] ->
        normalize_bot_qualified_command(name, bot_username, config)
    end
  end

  defp normalize_bot_qualified_command(name, bot_username, %Config{bot_username: configured})
       when is_binary(configured) do
    case String.downcase(bot_username) == String.downcase(configured) do
      true -> {:ok, String.downcase(name)}
      false -> :error
    end
  end

  defp normalize_bot_qualified_command(_name, _bot_username, _config), do: :error

  defp run(%{name: "ping"} = command, config, cache) do
    reply_and_cache(command, config, cache, BullX.I18n.t("gateway.telegram.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", chat_type: chat_type} = command, config, cache)
       when chat_type != "private" do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.telegram.auth.direct_command_dm_only"),
      "preauth"
    )
  end

  defp run(%{name: "preauth", args: args} = command, config, cache) do
    code = args |> to_string() |> String.trim()

    text =
      case config.accounts_module.consume_activation_code(code, command.account_input) do
        {:ok, _user, _binding} ->
          BullX.I18n.t("gateway.telegram.auth.activation_success")

        {:error, :invalid_or_expired_code} ->
          BullX.I18n.t("gateway.telegram.auth.activation_code_invalid")

        {:error, :already_bound} ->
          BullX.I18n.t("gateway.telegram.auth.already_linked")

        {:error, :user_banned} ->
          BullX.I18n.t("gateway.telegram.auth.denied")

        {:error, _} ->
          BullX.I18n.t("gateway.telegram.auth.activation_failed")
      end

    reply_and_cache(command, config, cache, text, "preauth")
  end

  defp run(%{name: "web_auth", chat_type: chat_type} = command, config, cache)
       when chat_type != "private" do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.telegram.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, config, cache) do
    text =
      case Config.web_login_allowed?(config) do
        true -> issue_web_auth_code(config, command.actor.id)
        false -> BullX.I18n.t("gateway.telegram.auth.web_auth_disabled")
      end

    reply_and_cache(command, config, cache, text, "web_auth")
  end

  defp run(%{name: "ask_prompt_required"} = command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.telegram.ask.prompt_required"),
      "ask"
    )
  end

  defp run(command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.telegram.errors.unsupported_message"),
      command.name
    )
  end

  defp issue_web_auth_code(config, external_id) do
    case config.accounts_module.issue_user_channel_auth_code(
           :telegram,
           config.channel_id,
           external_id
         ) do
      {:ok, code} ->
        BullX.I18n.t("gateway.telegram.auth.web_auth_created", %{
          code: code,
          login_url: web_login_url(config)
        })

      {:error, :not_bound} ->
        BullX.I18n.t("gateway.telegram.auth.web_auth_not_bound")

      {:error, :user_banned} ->
        BullX.I18n.t("gateway.telegram.auth.denied")

      {:error, _} ->
        BullX.I18n.t("gateway.telegram.auth.web_auth_failed")
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
        {:error, Error.map(reason), cache}
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
        "telegram" => %{"direct_command" => command_name, "event_id" => command.event_id}
      }
    }
  end

  defp web_login_url(%Config{endpoint: endpoint}) do
    endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/new")
  end
end
