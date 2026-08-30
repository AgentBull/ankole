defmodule Ankole.Plugins.DiscordAdapter.Gateway do
  @moduledoc """
  Discord Gateway protocol facts and frame construction.

  This module owns the wire protocol only: opcodes, intents, close-code
  classification, and payload construction. `Ankole.Plugins.DiscordAdapter.Socket`
  owns the connection, and `ConnectionOwner` owns the session lifecycle.
  """

  @op_dispatch 0
  @op_heartbeat 1
  @op_identify 2
  @op_resume 6
  @op_reconnect 7
  @op_invalid_session 9
  @op_hello 10
  @op_heartbeat_ack 11

  # GUILD_MESSAGES and DIRECT_MESSAGES deliver the message events, and their
  # REACTIONS counterparts deliver reaction facts. The adapter keeps no channel
  # cache, so it does not ask for GUILDS.
  @base_intents [
    guild_messages: 512,
    guild_message_reactions: 1_024,
    direct_messages: 4_096,
    direct_message_reactions: 8_192
  ]

  # MESSAGE_CONTENT is privileged. Discord closes the connection with 4014 when
  # a client asks for a privileged intent the application does not have, so the
  # bit is added only after the preflight reads the application flags. Without
  # it Discord sends empty `content` for guild messages that do not mention the
  # bot, and the adapter skips those instead of projecting blank text.
  @message_content_intent 32_768

  # Application flags GATEWAY_MESSAGE_CONTENT (1 <<< 18) and its LIMITED
  # counterpart (1 <<< 19). The limited flag belongs to an application below the
  # verification threshold; it carries the same gateway permission.
  @message_content_flags 262_144 + 524_288

  # 4004 authenticate_failed, 4010 invalid_shard, 4011 sharding_required,
  # 4012 invalid_api_version, 4013 invalid_intents, 4014 disallowed_intents.
  # None of these clear without an operator changing the token or the
  # Developer Portal, so the owner must stop reconnecting and report instead.
  @fatal_close_codes %{
    4_004 => :authentication_failed,
    4_010 => :invalid_shard,
    4_011 => :sharding_required,
    4_012 => :invalid_api_version,
    4_013 => :invalid_intents,
    4_014 => :disallowed_intents
  }

  # 4007 invalid_seq and 4009 session_timeout invalidate the session but the
  # token stays good, so the owner reconnects with a fresh identify.
  @session_invalid_close_codes [4_007, 4_009]

  @doc """
  Returns the intent bitfield. `message_content?` comes from the application
  flags that the preflight reads.
  """
  @spec intents(boolean()) :: non_neg_integer()
  def intents(message_content?) when is_boolean(message_content?) do
    base = Enum.reduce(@base_intents, 0, fn {_name, value}, acc -> acc + value end)
    if message_content?, do: base + @message_content_intent, else: base
  end

  @doc "Reads the message-content permission out of the application flags."
  @spec message_content_flag?(term()) :: boolean()
  def message_content_flag?(flags) when is_integer(flags),
    do: Bitwise.band(flags, @message_content_flags) != 0

  def message_content_flag?(_flags), do: false

  @doc """
  Classifies one decoded gateway payload so the session owner never needs the
  opcode numbers.
  """
  @spec classify(term()) ::
          {:dispatch, String.t(), integer() | nil, map()}
          | {:hello, pos_integer()}
          | {:invalid_session, boolean()}
          | :heartbeat_ack
          | :heartbeat_request
          | :reconnect
          | :unknown
  def classify(%{"op" => @op_dispatch, "t" => type, "d" => data} = payload)
      when is_binary(type) and is_map(data) do
    {:dispatch, type, sequence(Map.get(payload, "s")), data}
  end

  def classify(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}})
      when is_integer(interval) and interval > 0 do
    {:hello, interval}
  end

  def classify(%{"op" => @op_heartbeat_ack}), do: :heartbeat_ack
  def classify(%{"op" => @op_heartbeat}), do: :heartbeat_request
  def classify(%{"op" => @op_reconnect}), do: :reconnect
  def classify(%{"op" => @op_invalid_session, "d" => true}), do: {:invalid_session, true}
  def classify(%{"op" => @op_invalid_session}), do: {:invalid_session, false}
  def classify(_payload), do: :unknown

  @doc "Builds the IDENTIFY payload that opens a new gateway session."
  @spec identify(String.t(), boolean(), {non_neg_integer(), non_neg_integer()}) :: map()
  def identify(token, message_content?, {shard_id, shard_count}) when is_binary(token) do
    %{
      "op" => @op_identify,
      "d" => %{
        "token" => token,
        "intents" => intents(message_content?),
        "shard" => [shard_id, shard_count],
        "properties" => %{
          "os" => to_string(:erlang.system_info(:system_architecture)),
          "browser" => "ankole",
          "device" => "ankole"
        }
      }
    }
  end

  @doc "Builds the RESUME payload that replays a dropped session."
  @spec resume(String.t(), String.t(), integer()) :: map()
  def resume(token, session_id, sequence)
      when is_binary(token) and is_binary(session_id) and is_integer(sequence) do
    %{
      "op" => @op_resume,
      "d" => %{"token" => token, "session_id" => session_id, "seq" => sequence}
    }
  end

  @doc "Builds a heartbeat payload carrying the last received sequence."
  @spec heartbeat(integer() | nil) :: map()
  def heartbeat(sequence) when is_integer(sequence) or is_nil(sequence),
    do: %{"op" => @op_heartbeat, "d" => sequence}

  @doc """
  Returns the first heartbeat delay. Discord asks each client to jitter its
  first heartbeat so that a mass reconnect does not align every bot on the same
  interval boundary.
  """
  @spec first_heartbeat_delay(pos_integer()) :: non_neg_integer()
  def first_heartbeat_delay(interval_ms) when is_integer(interval_ms) and interval_ms > 0,
    do: floor(interval_ms * :rand.uniform())

  @doc """
  Classifies a gateway close code.

  `:fatal` needs operator action and must not reconnect. `:session_invalid`
  drops the resume state and identifies again. `:resumable` keeps the session
  and resumes.
  """
  @spec close_action(integer() | nil) ::
          {:fatal, atom()} | :session_invalid | :resumable
  def close_action(code) when is_map_key(@fatal_close_codes, code),
    do: {:fatal, Map.fetch!(@fatal_close_codes, code)}

  def close_action(code) when code in @session_invalid_close_codes, do: :session_invalid
  def close_action(_code), do: :resumable

  @doc "Appends the query Discord requires on the gateway URL."
  @spec socket_url(String.t()) :: String.t()
  def socket_url(url) when is_binary(url) do
    url
    |> String.trim_trailing("/")
    |> Kernel.<>("/?v=10&encoding=json")
  end

  defp sequence(value) when is_integer(value), do: value
  defp sequence(_value), do: nil
end
