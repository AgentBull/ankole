defmodule Feishu.DirectCommand do
  @moduledoc false

  alias BullX.EventBus.CommandCatalog
  alias Feishu.Source

  @spec parse(String.t() | nil) :: {:ok, map()} | :error
  def parse(text) when is_binary(text) do
    text = String.trim(text)

    with true <- String.starts_with?(text, "/"),
         [name | rest] <- String.split(String.trim_leading(text, "/"), ~r/\s+/, parts: 2),
         true <- name != "" do
      {:ok, %{name: canonical_name(name), input_name: name, args: Enum.join(rest, " ")}}
    else
      _other -> :error
    end
  end

  def parse(_text), do: :error

  defp canonical_name(name) do
    case CommandCatalog.canonical_command_name(name) do
      {:ok, canonical} -> canonical
      :error -> name |> String.trim() |> String.downcase()
    end
  end

  @spec handle(Source.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(%Source{} = source, %{event_id: event_id} = command, opts \\ []) do
    start_time = System.monotonic_time()
    meta = %{source_id: source.id, command_name: command.name}

    :telemetry.execute(
      [:bullx, :event_bus, :adapter, :feishu, :direct_command, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = do_handle(source, command, event_id, opts)

    :telemetry.execute(
      [:bullx, :event_bus, :adapter, :feishu, :direct_command, :stop],
      %{duration: System.monotonic_time() - start_time},
      Map.put(meta, :result, telemetry_result(result))
    )

    result
  end

  @spec reply_text(map(), Source.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def reply_text(command, %Source{} = source, text, command_name, opts \\ []) do
    with {:ok, result} <- Feishu.Outbound.reply_text(command, source, text, opts) do
      {:ok, Map.merge(result, %{"command_name" => command_name})}
    end
  end

  defp do_handle(%Source{} = source, command, event_id, opts) do
    key = direct_cache_key(source, event_id)

    case BullX.Cache.get(key) do
      {:ok, result} ->
        {:ok, Map.put(result, "duplicate", true)}

      {:error, :not_found} ->
        run_and_cache(source, command, key, opts)

      {:error, reason} ->
        {:error, Feishu.Error.map(reason)}
    end
  end

  defp run_and_cache(%Source{} = source, command, key, opts) do
    with {:ok, result} <- run(source, command, opts),
         :ok <- BullX.Cache.put(key, result, source.direct_command_dedupe_ttl_seconds) do
      {:ok, result}
    end
  end

  defp run(%Source{} = source, %{name: "preauth", chat_type: chat_type} = command, opts)
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.feishu.auth.direct_command_dm_only"),
      "preauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "preauth", args: args} = command, opts) do
    text =
      args
      |> to_string()
      |> String.trim()
      |> BullX.Principals.consume_activation_code(command.account_input)
      |> activation_reply()

    reply_text(command, source, text, "preauth", opts)
  end

  defp run(%Source{} = source, %{name: "web_auth", chat_type: chat_type} = command, opts)
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.feishu.auth.direct_command_dm_only"),
      "web_auth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "web_auth"} = command, opts)
       when source.web_login_disabled? do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.feishu.auth.web_auth_disabled"),
      "web_auth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "web_auth"} = command, opts) do
    text =
      "feishu"
      |> BullX.Principals.issue_login_auth_code(source.id, command.actor.id)
      |> web_auth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "web_auth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("eventbus.feishu.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp activation_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("eventbus.feishu.auth.activation_success")

  defp activation_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("eventbus.feishu.auth.activation_code_invalid")

  defp activation_reply({:error, :already_bound}),
    do: BullX.I18n.t("eventbus.feishu.auth.already_linked")

  defp activation_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("eventbus.feishu.auth.denied")

  defp activation_reply({:error, _reason}),
    do: BullX.I18n.t("eventbus.feishu.auth.activation_failed")

  defp web_auth_reply({:ok, code}, login_url) do
    BullX.I18n.t("eventbus.feishu.auth.web_auth_created", %{code: code, login_url: login_url})
  end

  defp web_auth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("eventbus.feishu.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("eventbus.feishu.auth.web_auth_not_bound")

  defp web_auth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("eventbus.feishu.auth.denied")

  defp web_auth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("eventbus.feishu.auth.web_auth_failed")

  defp direct_cache_key(%Source{} = source, event_id) do
    "feishu:#{source.id}:direct_command:#{event_id}"
  end

  defp telemetry_result({:ok, _result}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error
end
