defmodule Discord.DirectCommand do
  @moduledoc """
  Adapter-local Discord direct commands: `/ping`, `/preauth <code>`,
  `/web_auth`.

  Commands are intercepted before Gateway inbound publish. Text-transport
  replies go through `BullX.Gateway.deliver/1` so the Gateway outbound
  contract owns retries and dead-letter handling. Interaction-transport
  replies are sent ephemerally via Nostrum because Discord interaction
  tokens are short-lived and only the original interaction id can produce an
  ephemeral response visible to the invoking user.
  """

  alias Discord.{Error, Source}

  @intercepted_names ~w(ping preauth web_auth)
  @ephemeral_flag 64

  @spec parse(String.t() | nil) :: {:ok, map()} | :error
  def parse(text) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [raw_name | rest] <- String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         {:ok, name} <- strip_bot_username(raw_name),
         true <- name in @intercepted_names do
      {:ok, %{name: name, args: Enum.join(rest, " ")}}
    else
      _other -> :error
    end
  end

  def parse(_text), do: :error

  @spec intercepted?(String.t()) :: boolean()
  def intercepted?(name) when is_binary(name), do: name in @intercepted_names
  def intercepted?(_name), do: false

  @spec handle(map(), Source.t()) :: {:ok, map()} | {:error, map()}
  def handle(%{event_id: event_id} = command, %Source{} = source) do
    start_time = System.monotonic_time()
    meta = %{channel_id: source.channel_id, command_name: command.name}

    :telemetry.execute(
      [:bullx, :discord, :direct_command, :handled],
      %{system_time: System.system_time()},
      meta
    )

    result = do_handle(command, source, event_id)

    :telemetry.execute(
      [:bullx, :discord, :direct_command, :handled],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :result, telemetry_result(result))
    )

    result
  end

  @doc """
  Sends a localized reply for the given command (or synthetic command for the
  account-gate path). Uses Gateway outbound for message-transport replies and
  Discord's ephemeral interaction response for interaction-transport replies.
  """
  @spec reply_text(map(), Source.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name) do
    do_reply(command, source, text, command_name)
  end

  defp do_handle(%{event_id: event_id} = command, %Source{} = source, _event_id_param) do
    cache_key = cache_key(source, event_id)

    case BullX.Cache.get(cache_key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        run_and_cache(command, source, cache_key)

      {:error, _reason} ->
        run_and_cache(command, source, cache_key)
    end
  end

  defp run_and_cache(command, %Source{} = source, cache_key) do
    with {:ok, result} <- run(command, source),
         _ <- BullX.Cache.put(cache_key, result, source.direct_command_dedupe_ttl_seconds) do
      {:ok, result}
    end
  end

  defp run(%{name: "ping"} = command, %Source{} = source) do
    reply_text(command, source, BullX.I18n.t("gateway.discord.ping.pong"), "ping")
  end

  defp run(%{name: "preauth", dm?: false} = command, %Source{} = source) do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.discord.auth.direct_command_dm_only"),
      "preauth"
    )
  end

  defp run(%{name: "preauth", args: args} = command, %Source{} = source) do
    text =
      args
      |> to_string()
      |> String.trim()
      |> BullX.Principals.consume_activation_code(command.account_input)
      |> activation_reply()

    reply_text(command, source, text, "preauth")
  end

  defp run(%{name: "web_auth", dm?: false} = command, %Source{} = source) do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.discord.auth.direct_command_dm_only"),
      "web_auth"
    )
  end

  defp run(%{name: "web_auth"} = command, %Source{} = source) do
    text =
      "discord"
      |> BullX.Principals.issue_login_auth_code(source.channel_id, command.actor.id)
      |> web_auth_reply(web_login_url(source))

    reply_text(command, source, text, "web_auth")
  end

  defp run(command, %Source{} = source) do
    reply_text(
      command,
      source,
      BullX.I18n.t("gateway.discord.errors.unsupported_message"),
      command.name
    )
  end

  defp do_reply(
         %{transport: :interaction, interaction: interaction} = command,
         %Source{} = source,
         text,
         command_name
       )
       when not is_nil(interaction) do
    response = %{
      type: 4,
      data: %{
        content: text,
        flags: @ephemeral_flag
      }
    }

    Source.with_bot(source, fn ->
      source.interaction_api.create_response(interaction, response)
    end)
    |> case do
      :ok ->
        {:ok,
         %{
           "command_name" => command_name,
           "interaction_id" => command.event_id,
           "status" => "ephemeral_replied"
         }}

      {:ok, _result} ->
        {:ok,
         %{
           "command_name" => command_name,
           "interaction_id" => command.event_id,
           "status" => "ephemeral_replied"
         }}

      {:error, error} ->
        {:error, Error.map(error)}

      other ->
        {:error, Error.map(other)}
    end
  end

  defp do_reply(command, %Source{} = source, text, command_name) do
    delivery = %{
      id: BullX.Ext.gen_uuid_v7(),
      op: :send,
      channel: {source.adapter, source.channel_id},
      scope_id: to_string(command.scope_id || command.discord_channel_id),
      thread_id: nil,
      reply_to_external_id: to_string_or_nil(command.message_id),
      content: [%{"kind" => "text", "body" => %{"text" => text}}],
      extensions: %{"command_name" => command_name}
    }

    case BullX.Gateway.deliver(delivery) do
      {:ok, :accepted, delivery_id} ->
        {:ok,
         %{
           "command_name" => command_name,
           "delivery_id" => delivery_id,
           "status" => "accepted"
         }}

      {:error, error} ->
        {:error, Error.map(error)}
    end
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("gateway.discord.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("gateway.discord.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("gateway.discord.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("gateway.discord.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("gateway.discord.auth.activation_failed")

  defp web_auth_reply({:ok, code}, login_url) do
    BullX.I18n.t("gateway.discord.auth.web_auth_created", %{code: code, login_url: login_url})
  end

  defp web_auth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("gateway.discord.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("gateway.discord.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("gateway.discord.auth.denied")

  defp web_auth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("gateway.discord.auth.web_auth_failed")

  defp telemetry_result({:ok, _result}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error

  defp strip_bot_username(raw_name) do
    case String.split(raw_name, "@", parts: 2) do
      [name] when name != "" -> {:ok, String.downcase(name)}
      [name, _bot] when name != "" -> {:ok, String.downcase(name)}
      _other -> :error
    end
  end

  defp cache_key(%Source{channel_id: channel_id}, event_id) do
    "discord:#{channel_id}:direct_command:#{event_id}"
  end

  defp web_login_url(%Source{endpoint: endpoint}) do
    case Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :url, 0) do
      true ->
        endpoint.url()
        |> String.trim_trailing("/")
        |> Kernel.<>("/sessions/new")

      false ->
        "/sessions/new"
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(""), do: nil
  defp to_string_or_nil(value), do: to_string(value)
end
