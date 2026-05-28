defmodule Feishu.DirectCommand do
  @moduledoc false

  alias BullX.AIAgent.CommandCatalog
  alias Feishu.{Source, UserInfo}

  import BullX.Utils.Map, only: [maybe_put: 3]

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

  @spec parse_mentioned_text(String.t() | nil) :: {:ok, map()} | :error
  def parse_mentioned_text(text) when is_binary(text) do
    text = String.trim(text)

    with false <- String.starts_with?(text, "/"),
         [name | rest] <- String.split(text, ~r/\s+/, parts: 2),
         true <- name != "",
         args <- Enum.join(rest, " "),
         {:ok, canonical} <- CommandCatalog.canonical_command_name(name),
         :ok <- validate_mentioned_args(canonical, args) do
      {:ok,
       %{
         name: canonical,
         input_name: name,
         args: String.trim(args),
         surface: "mention_text"
       }}
    else
      _other -> :error
    end
  end

  def parse_mentioned_text(_text), do: :error

  defp canonical_name(name) do
    case CommandCatalog.canonical_command_name(name) do
      {:ok, canonical} -> canonical
      :error -> name |> String.trim() |> String.downcase()
    end
  end

  defp validate_mentioned_args("steer", _args), do: :ok
  defp validate_mentioned_args(_name, ""), do: :ok
  defp validate_mentioned_args(_name, _args), do: :error

  @spec handle(Source.t(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def handle(%Source{} = source, %{event_id: event_id} = command, opts \\ []) do
    start_time = System.monotonic_time()
    meta = %{source_id: source.id, command_name: command.name}

    :telemetry.execute(
      [:bullx, :im_gateway, :adapter, :feishu, :direct_command, :start],
      %{system_time: System.system_time()},
      meta
    )

    result = do_handle(source, command, event_id, opts)

    :telemetry.execute(
      [:bullx, :im_gateway, :adapter, :feishu, :direct_command, :stop],
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

  defp run(%Source{} = source, %{name: "root_init"} = command, opts) do
    case BullX.AuthZ.ensure_root_init_open() do
      :ok -> run_root_init_open(source, command, opts)
      {:error, :root_init_closed} -> {:ok, %{"command_name" => "root_init", "status" => "ignored"}}
    end
  end

  defp run(%Source{} = source, %{name: "webauth", chat_type: chat_type} = command, opts)
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.feishu.auth.direct_command_dm_only"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts)
       when source.web_login_disabled? do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.feishu.auth.webauth_disabled"),
      "webauth",
      opts
    )
  end

  defp run(%Source{} = source, %{name: "webauth"} = command, opts) do
    text =
      source
      |> maybe_ensure_command_actor(command)
      |> issue_login_auth_code("feishu", source.id, command.actor.id)
      |> webauth_reply(BullX.Principals.web_login_url())

    reply_text(command, source, text, "webauth", opts)
  end

  defp run(%Source{} = source, command, opts) do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.feishu.errors.unsupported_message"),
      command.name,
      opts
    )
  end

  defp run_root_init_open(%Source{} = source, %{chat_type: chat_type} = command, opts)
       when chat_type != "p2p" do
    reply_text(
      command,
      source,
      BullX.I18n.t("im_gateway.feishu.auth.direct_command_dm_only"),
      "root_init",
      opts
    )
  end

  defp run_root_init_open(%Source{} = source, %{args: args} = command, opts) do
    text =
      source
      |> root_init_account_input(command)
      |> root_init(args)
      |> root_init_reply()

    reply_text(command, source, text, "root_init", opts)
  end

  defp root_init_reply({:ok, _principal, _identity}),
    do: BullX.I18n.t("im_gateway.feishu.auth.root_init_success")

  defp root_init_reply({:error, :invalid_or_expired_code}),
    do: BullX.I18n.t("im_gateway.feishu.auth.activation_code_invalid")

  defp root_init_reply({:error, :principal_disabled}),
    do: BullX.I18n.t("im_gateway.feishu.auth.denied")

  defp root_init_reply({:error, _reason}),
    do: BullX.I18n.t("im_gateway.feishu.auth.root_init_failed")

  defp root_init({:ok, account_input}, args) do
    args
    |> to_string()
    |> String.trim()
    |> BullX.Principals.root_init_with_bootstrap_code(account_input)
  end

  defp root_init({:error, reason}, _args), do: {:error, reason}

  defp maybe_ensure_command_actor(%Source{trusted_realm_by_default: true} = source, command) do
    case BullX.Principals.ensure_human_from_channel_actor(command_account_input(source, command)) do
      {:ok, _principal, _identity} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_ensure_command_actor(%Source{}, _command), do: :ok

  defp issue_login_auth_code(:ok, adapter, source_id, external_id) do
    BullX.Principals.issue_login_auth_code(adapter, source_id, external_id)
  end

  defp issue_login_auth_code({:error, reason}, _adapter, _source_id, _external_id),
    do: {:error, reason}

  defp command_account_input(%Source{} = source, command) do
    command
    |> map_value(:account_input)
    |> stringify_map()
    |> Map.put("trusted_realm_by_default", source.trusted_realm_by_default)
  end

  defp root_init_account_input(%Source{} = source, command) do
    with {:ok, open_id} <- command_actor_open_id(command),
         {:ok, userinfo} <- UserInfo.fetch_contact(source, open_id),
         :ok <- validate_contact_open_id(userinfo, open_id),
         userinfo <- Map.put_new(userinfo, "open_id", open_id),
         :ok <- validate_root_init_actor(command, open_id) do
      {:ok, build_root_init_account_input(source, command, open_id, userinfo)}
    end
  end

  defp validate_contact_open_id(userinfo, open_id) do
    case userinfo |> stringify_map() |> Map.get("open_id") |> present_string() do
      ^open_id -> :ok
      nil -> :ok
      _other_open_id -> {:error, Feishu.Error.payload("Feishu contact user mismatch")}
    end
  end

  defp validate_root_init_actor(command, open_id) do
    case command_actor_open_id(command) do
      {:ok, ^open_id} -> :ok
      {:ok, _other_open_id} -> {:error, Feishu.Error.payload("Feishu root_init actor mismatch")}
      {:error, error} -> {:error, error}
    end
  end

  defp build_root_init_account_input(%Source{} = source, command, open_id, userinfo) do
    account_input = command |> map_value(:account_input) |> stringify_map()
    metadata = account_input |> Map.get("metadata", %{}) |> stringify_map()

    %{
      "adapter" => "feishu",
      "channel_id" => source.id,
      "external_id" => "feishu:" <> open_id,
      "trusted_realm_by_default" => true,
      "profile" => UserInfo.profile(userinfo),
      "metadata" =>
        metadata
        |> Map.put("source", "feishu_im")
        |> maybe_put("tenant_key", Map.get(userinfo, "tenant_key"))
        |> maybe_put("domain", Atom.to_string(source.domain))
    }
  end

  defp command_actor_open_id(command) do
    command
    |> map_value(:actor)
    |> stringify_map()
    |> actor_open_id()
  end

  defp actor_open_id(actor) do
    cond do
      present_string(actor["open_id"]) ->
        {:ok, actor["open_id"]}

      match?("feishu:" <> _open_id, actor["id"]) ->
        {:ok, String.trim_leading(actor["id"], "feishu:")}

      true ->
        {:error, Feishu.Error.payload("Feishu root_init actor is missing open_id")}
    end
  end

  defp webauth_reply({:ok, code}, login_url) do
    BullX.I18n.t("im_gateway.feishu.auth.webauth_created", %{code: code, login_url: login_url})
  end

  defp webauth_reply({:error, :not_bound}, _login_url),
    do: BullX.I18n.t("im_gateway.feishu.auth.webauth_not_bound")

  defp webauth_reply({:error, :identity_unverified}, _login_url),
    do: BullX.I18n.t("im_gateway.feishu.auth.webauth_not_bound")

  defp webauth_reply({:error, :not_human}, _login_url),
    do: BullX.I18n.t("im_gateway.feishu.auth.webauth_not_bound")

  defp webauth_reply({:error, :principal_disabled}, _login_url),
    do: BullX.I18n.t("im_gateway.feishu.auth.denied")

  defp webauth_reply({:error, _reason}, _login_url),
    do: BullX.I18n.t("im_gateway.feishu.auth.webauth_failed")

  defp direct_cache_key(%Source{} = source, event_id) do
    "feishu:#{source.id}:direct_command:#{event_id}"
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_value(_map, _key), do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_map(_value), do: %{}

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp present_string(_value), do: nil

  defp telemetry_result({:ok, _result}), do: :ok
  defp telemetry_result({:error, %{"kind" => kind}}) when is_binary(kind), do: kind
  defp telemetry_result(_result), do: :error
end
