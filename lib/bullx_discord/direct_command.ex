defmodule BullXDiscord.DirectCommand do
  @moduledoc """
  Adapter-local Discord commands.
  """

  alias BullXGateway.Delivery
  alias BullXGateway.Delivery.Content
  alias BullXDiscord.{Cache, Config, Error}

  @ephemeral_flag 64

  @type command :: map()

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

  def parse(_text), do: :error

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
    reply_and_cache(command, config, cache, BullX.I18n.t("gateway.discord.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", dm?: false} = command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.discord.auth.direct_command_dm_only"),
      "preauth"
    )
  end

  defp run(%{name: "preauth", args: args} = command, config, cache) do
    code = args |> to_string() |> String.trim()

    text =
      case config.accounts_module.consume_activation_code(code, command.account_input) do
        {:ok, _user, _binding} ->
          BullX.I18n.t("gateway.discord.auth.activation_success")

        {:error, :invalid_or_expired_code} ->
          BullX.I18n.t("gateway.discord.auth.activation_code_invalid")

        {:error, :already_bound} ->
          BullX.I18n.t("gateway.discord.auth.already_linked")

        {:error, :user_banned} ->
          BullX.I18n.t("gateway.discord.auth.denied")

        {:error, _} ->
          BullX.I18n.t("gateway.discord.auth.activation_failed")
      end

    reply_and_cache(command, config, cache, text, "preauth")
  end

  defp run(%{name: "web_auth", dm?: false} = command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.discord.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, config, cache) do
    text =
      case Config.web_login_allowed?(config) do
        true -> issue_web_auth_code(config, command.actor.id)
        false -> BullX.I18n.t("gateway.discord.auth.web_auth_disabled")
      end

    reply_and_cache(command, config, cache, text, "web_auth")
  end

  defp run(command, config, cache) do
    reply_and_cache(
      command,
      config,
      cache,
      BullX.I18n.t("gateway.discord.errors.unsupported_message"),
      command.name
    )
  end

  defp issue_web_auth_code(config, external_id) do
    case config.accounts_module.issue_user_channel_auth_code(
           :discord,
           config.channel_id,
           external_id
         ) do
      {:ok, code} ->
        BullX.I18n.t("gateway.discord.auth.web_auth_created", %{
          code: code,
          login_url: web_login_url(config)
        })

      {:error, :not_bound} ->
        BullX.I18n.t("gateway.discord.auth.web_auth_not_bound")

      {:error, :user_banned} ->
        BullX.I18n.t("gateway.discord.auth.denied")

      {:error, _} ->
        BullX.I18n.t("gateway.discord.auth.web_auth_failed")
    end
  end

  defp reply_and_cache(command, config, cache, text, command_name) do
    case do_reply(command, config, text, command_name) do
      {:ok, result} ->
        cache = Cache.put_direct_result(cache, command.event_id, result, config.dedupe_ttl_ms)
        {:ok, result, cache}

      {:error, error} ->
        {:error, error, cache}
    end
  end

  defp do_reply(
         %{transport: :interaction, interaction: interaction} = command,
         config,
         text,
         command_name
       ) do
    response = %{
      type: 4,
      data: %{
        content: text,
        flags: @ephemeral_flag,
        allowed_mentions: BullXDiscord.Delivery.allowed_mentions()
      }
    }

    Config.with_bot(config, fn ->
      config.interaction_api.create_response(interaction, response)
    end)
    |> case do
      :ok -> {:ok, %{interaction_id: command.event_id, command_name: command_name}}
      {:ok, _} -> {:ok, %{interaction_id: command.event_id, command_name: command_name}}
      {:error, error} -> {:error, Error.map(error)}
      error -> {:error, Error.map(error)}
    end
  end

  defp do_reply(command, config, text, command_name) do
    delivery = %Delivery{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: command.channel,
      scope_id: command.discord_channel_id,
      thread_id: nil,
      reply_to_external_id: command.message_id,
      content: %Content{kind: :text, body: %{"text" => text}},
      extensions: %{
        "discord" => %{"direct_command" => command_name, "event_id" => command.event_id}
      }
    }

    case config.gateway_module.deliver(delivery) do
      {:ok, delivery_id} -> {:ok, %{delivery_id: delivery_id, command_name: command_name}}
      {:error, reason} -> {:error, Error.map(reason)}
    end
  end

  defp web_login_url(%Config{endpoint: endpoint}) do
    endpoint.url()
    |> String.trim_trailing("/")
    |> Kernel.<>("/sessions/new")
  end
end
