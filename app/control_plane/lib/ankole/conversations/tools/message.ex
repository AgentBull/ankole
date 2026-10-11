defmodule Ankole.Conversations.Tools.Message do
  @behaviour Ankole.Conversations.Tool
  @moduledoc false
  import Ecto.Query
  alias Ankole.Conversations.{Run, Tools}
  alias Ankole.Files
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{ActorEvent, Adapters, Channel, Outbox, OutboxAdapter}

  @declaration %{
    "type" => "function",
    "name" => "send_message",
    "description" =>
      "Send a message through one of your IM bindings. Use a reachable channel_id, or a principal_uid when the adapter can resolve that person's existing direct conversation. Attachments name files in your drive. The result reports sent only after provider delivery; failed reports its reason; unknown means the provider may have delivered it; queued means delivery is still pending. Do not resend an unknown message or claim delivery from queued.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "destination" => %{
          "oneOf" => [
            %{
              "type" => "object",
              "properties" => %{
                "binding" => %{"type" => "string", "minLength" => 1},
                "channel_id" => %{"type" => "string", "minLength" => 1}
              },
              "required" => ~w(binding channel_id),
              "additionalProperties" => false
            },
            %{
              "type" => "object",
              "properties" => %{
                "binding" => %{"type" => "string", "minLength" => 1},
                "principal_uid" => %{"type" => "string", "minLength" => 1}
              },
              "required" => ~w(binding principal_uid),
              "additionalProperties" => false
            }
          ]
        },
        "text" => %{"type" => "string", "minLength" => 1},
        "attachments" => %{
          "type" => "array",
          "maxItems" => 16,
          "items" => %{"type" => "string", "minLength" => 1}
        }
      },
      "required" => ~w(destination text),
      "additionalProperties" => false
    },
    "execution_mode" => "sequential",
    "read_only" => false,
    "destructive" => false
  }
  @impl true
  def normalize(_name, args), do: args

  @impl true
  def declarations, do: [@declaration]

  # The text and each attachment are separate posts, like a final reply, so
  # every adapter delivers all of them. The text post keeps the call's key and
  # attachment posts extend it.
  @impl true
  def execute_in_tx(repo, run, call, args) do
    destination = args["destination"]
    key = "tool:#{Run.response_id(run.model_response)}:#{Run.call_id(call)}"

    with {:ok, binding} <- SignalsGateway.get_binding(run.agent_uid, destination["binding"]),
         {:ok, adapter} <- Adapters.fetch_outbox(binding.adapter),
         true <- MapSet.member?(adapter.capabilities, :post_entry),
         {:ok, channel} <- channel_in_tx(repo, run, binding, adapter, destination),
         {:ok, attachments} <- attachment_refs(run.agent_uid, args["attachments"] || []),
         :ok <-
           commit_posts_in_tx(repo, run, binding, channel, [
             {key, %{"text" => args["text"]}, args["text"]}
             | Enum.with_index(attachments, &{"#{key}:#{&2}", %{"attachments" => [&1]}, nil})
           ]) do
      {:ok,
       {:await,
        %Ankole.Conversations.Wait{
          kind: :outbox,
          binding_name: binding.name,
          outbound_key: key,
          timeout_ms: 10_000
        }}, []}
    else
      false -> {:error, :adapter_cannot_post}
      {:error, _} = error -> error
    end
  end

  defp commit_posts_in_tx(repo, run, binding, channel, posts) do
    Enum.reduce_while(posts, :ok, fn {key, payload, text}, :ok ->
      case Outbox.commit_outbox_in_tx(repo, %{
             agent_uid: run.agent_uid,
             binding_name: binding.name,
             outbound_key: key,
             operation: :post,
             signal_channel_id: channel.id,
             source_actor_event_id: run.actor_event_id,
             payload: payload,
             fallback_visible_text: text,
             idempotency_key: String.replace_prefix(key, "tool:", "")
           }) do
        {:ok, _outbox} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def observe(run, wait, _steered?, expired?) do
    rows =
      Ankole.Repo.all(
        from row in Ankole.SignalsGateway.OutboxEntry,
          where:
            row.agent_uid == ^run.agent_uid and row.binding_name == ^wait.binding_name and
              (row.outbound_key == ^wait.outbound_key or
                 fragment("starts_with(?, ?)", row.outbound_key, ^(wait.outbound_key <> ":")))
      )

    text = Enum.find(rows, &(&1.outbound_key == wait.outbound_key))
    failed = Enum.find(rows, &(&1.status in [:failed, :unsupported]))
    unknown = Enum.find(rows, &(&1.status == :unknown_after_send))

    cond do
      is_nil(text) ->
        {:ready, Tools.error("The durable outbox message is unavailable."), []}

      failed ->
        {:ready, Tools.result(%{"status" => "failed", "reason" => failed.last_error}), []}

      unknown ->
        {:ready,
         Tools.result(%{
           "status" => "unknown",
           "reason" => unknown.last_error,
           "retry_scheduled" => not is_nil(unknown.next_attempt_at)
         }), []}

      Enum.all?(rows, &(&1.status == :succeeded)) ->
        {:ready,
         Tools.result(%{
           "status" => "sent",
           "provider_message_id" => text.created_source_entry_id
         }), []}

      expired? ->
        {:ready, Tools.result(%{"status" => "queued"}), []}

      true ->
        :pending
    end
  end

  defp channel_in_tx(repo, run, binding, _adapter, %{"channel_id" => id}) do
    with true <-
           repo.exists?(
             from e in ActorEvent,
               where:
                 e.agent_uid == ^run.agent_uid and e.binding_name == ^binding.name and
                   e.signal_channel_id == ^id
           ),
         %Channel{kind: kind} = channel <- repo.get_by(Channel, id: id),
         true <- kind in [:im_dm, :im_group] do
      {:ok, channel}
    else
      _ -> {:error, :destination_not_reachable_from_binding}
    end
  end

  defp channel_in_tx(repo, run, binding, adapter, %{"principal_uid" => uid}) do
    with {:ok, %Channel{kind: :im_dm, id: id}} <-
           OutboxAdapter.open_conversation(adapter, binding, uid) do
      channel_in_tx(repo, run, binding, adapter, %{"channel_id" => id})
    end
  end

  defp attachment_refs(agent_uid, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, refs} ->
      case Files.fetch(agent_uid, path) do
        {:ok, file} ->
          {:cont,
           {:ok,
            [
              %{
                "path" => file.path,
                "blob_ref" => Base.encode16(file.sha256, case: :lower),
                "name" => Path.basename(file.path),
                "size" => file.size
              }
              | refs
            ]}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end
end
