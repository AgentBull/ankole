defmodule Ankole.Plugins.EmailAdapter.MailboxSession do
  @moduledoc """
  One IMAP session that runs inside a supervised task.

  The session lists unseen messages, hands each one to the inbound handler,
  and sets `\\Seen` only after the handler durably accepted or explicitly
  ignored it. It then waits in IDLE, or polls when the server has no IDLE, and
  repeats. Any failure ends the session; the owner decides when to start the
  next one.
  """

  alias Ankole.Logging
  alias Ankole.Plugins.EmailAdapter.Config
  alias Ankole.Plugins.EmailAdapter.Config.Runtime
  alias Ankole.Plugins.EmailAdapter.Imap.Client

  @size_limit_bytes 25 * 1024 * 1024
  @default_idle_ms 5 * 60 * 1000
  @default_poll_ms 60_000

  @type handler :: (map() -> {:ok, term()} | {:error, term()})

  @spec run(Runtime.t(), handler(), keyword()) :: {:blocked, atom()} | {:error, term()}
  def run(%Runtime{} = config, handler, opts \\ []) when is_function(handler, 1) do
    owner = Keyword.get(opts, :owner)

    with {:ok, client} <- Client.connect(Config.imap_options(config)),
         {:ok, client} <- authenticate(client, config),
         {:ok, client, mailbox} <- Client.select(client, "INBOX") do
      notify(
        owner,
        {:ready, %{uidvalidity: mailbox.uidvalidity, idle: Client.supports?(client, "IDLE")}}
      )

      loop(client, mailbox.uidvalidity, handler, opts)
    else
      {:blocked, reason} -> {:blocked, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Processes every unseen message once; exposed for the fake-server tests."
  @spec sync(Client.t(), pos_integer() | nil, handler()) ::
          {:ok, Client.t(), non_neg_integer()} | {:error, term()}
  def sync(%Client{} = client, uidvalidity, handler) do
    with {:ok, client, uids} <- Client.uid_search_unseen(client) do
      Enum.reduce_while(uids, {:ok, client, 0}, fn uid, {:ok, client, count} ->
        case process(client, uidvalidity, uid, handler) do
          {:ok, client} -> {:cont, {:ok, client, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp authenticate(client, config) do
    case Client.login(client, config.username, config.password) do
      {:ok, client} ->
        {:ok, client}

      {:error, {:no, _text}} ->
        Client.close(client)
        {:blocked, :authentication_failed}

      {:error, reason} ->
        Client.close(client)
        {:error, reason}
    end
  end

  defp loop(client, uidvalidity, handler, opts) do
    with {:ok, client, count} <- sync(client, uidvalidity, handler),
         :ok <- notify(Keyword.get(opts, :owner), {:synced, count}),
         {:ok, client} <- wait(client, opts) do
      loop(client, uidvalidity, handler, opts)
    else
      {:error, reason} ->
        Client.close(client)
        {:error, reason}
    end
  end

  defp wait(client, opts) do
    if Client.supports?(client, "IDLE") do
      case Client.idle(client, Keyword.get(opts, :idle_ms, @default_idle_ms)) do
        {:ok, client, _outcome} -> {:ok, client}
        {:error, reason} -> {:error, reason}
      end
    else
      Process.sleep(Keyword.get(opts, :poll_ms, @default_poll_ms))
      Client.noop(client)
    end
  end

  defp process(client, uidvalidity, uid, handler) do
    with {:ok, client, size} <- Client.uid_fetch_size(client, uid),
         section <- if(size > @size_limit_bytes, do: :header, else: :full),
         {:ok, client, raw} <- Client.uid_fetch_body(client, uid, section),
         {:ok, _result} <-
           handler.(%{
             "uid" => uid,
             "uidvalidity" => uidvalidity,
             "size" => size,
             "raw" => raw,
             "headers_only" => section == :header
           }) do
      Client.uid_store_seen(client, uid)
    else
      {:error, reason} ->
        Logging.warning(
          "email_adapter.mailbox_session.message_not_confirmed",
          "email message stays unseen after a failure",
          %{uid: uid, reason: inspect(reason)}
        )

        {:error, reason}
    end
  end

  defp notify(nil, _event), do: :ok

  defp notify(owner, event) when is_pid(owner) do
    send(owner, {:mailbox_session, self(), event})
    :ok
  end
end
