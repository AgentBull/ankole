defmodule Ankole.Sessions.Tools.Message do
  @behaviour Ankole.Sessions.Tool
  @moduledoc false
  import Ash.Expr, only: [expr: 1]
  alias Ankole.Sessions.Run
  alias Ankole.Sessions.Tools
  alias Ankole.Files

  alias Ankole.Signals.Adapters
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.Delivery.Adapter

  @declaration %{
    "type" => "function",
    "name" => "send_message",
    "activity" => "processing",
    "description" =>
      "Send a message through one of your IM bindings. Use a reachable conversation_id, or a principal_uid when the adapter can resolve that person's existing direct conversation. Attachments name files in your drive. The result reports sent only after provider delivery; failed reports its reason; unknown means the provider may have delivered it; queued means delivery is still pending. Do not resend an unknown message or claim delivery from queued.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "destination" => %{
          "oneOf" => [
            %{
              "type" => "object",
              "properties" => %{
                "binding" => %{"type" => "string", "minLength" => 1},
                "conversation_id" => %{"type" => "string", "minLength" => 1}
              },
              "required" => ~w(binding conversation_id),
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
  def prepare_in_tx(run, call, args),
    do: {:ok, [], fn -> commit_tool_in_tx(run, call, args) end}

  defp commit_tool_in_tx(run, call, args) do
    destination = args["destination"]
    key = "tool:#{Run.response_id(run.model_response)}:#{Run.call_id(call)}"

    with {:ok, binding} <-
           Ankole.Signals.Bindings.get_binding(run.agent_uid, destination["binding"]),
         {:ok, adapter} <- Adapters.fetch_delivery(binding.adapter),
         true <- MapSet.member?(adapter.capabilities, :post_entry),
         {:ok, channel} <- conversation_in_tx(run, binding, adapter, destination),
         {:ok, attachments} <- attachment_refs(run.agent_uid, args["attachments"] || []),
         :ok <-
           commit_posts_in_tx(run, binding, channel, [
             {key, %{"text" => args["text"]}, args["text"]}
             | Enum.with_index(attachments, &{"#{key}:#{&2}", %{"attachments" => [&1]}, nil})
           ]) do
      {:ok,
       {:await,
        %Ankole.Sessions.Wait{
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

  defp commit_posts_in_tx(run, binding, channel, posts) do
    Enum.reduce_while(posts, :ok, fn {key, payload, text}, :ok ->
      case Delivery.commit_in_tx(%{
             agent_uid: run.agent_uid,
             binding_name: binding.name,
             outbound_key: key,
             operation: :post,
             conversation_id: channel.id,
             source_signal_id: run.signal_id,
             payload: payload,
             fallback_visible_text: text,
             idempotency_key: String.replace_prefix(key, "tool:", "")
           }) do
        {:ok, _intent} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @impl true
  def observe(run, wait, _steered?, expired?) do
    outbound_prefix = wait.outbound_key <> ":"

    rows =
      Ankole.Conversations.list_intents!(
        query: [
          filter:
            expr(
              agent_uid == ^run.agent_uid and binding_name == ^wait.binding_name and
                (outbound_key == ^wait.outbound_key or
                   fragment("starts_with(?, ?)", outbound_key, ^outbound_prefix))
            )
        ]
      )

    text = Enum.find(rows, &(&1.outbound_key == wait.outbound_key))
    failed = Enum.find(rows, &(&1.status in [:failed, :expired]))
    unknown = Enum.find(rows, &(&1.status == :unknown))

    cond do
      is_nil(text) ->
        {:ready, Tools.error("The durable intent message is unavailable."), []}

      failed ->
        {:ready, Tools.result(%{"status" => "failed", "reason" => failed.last_error}), []}

      unknown ->
        {:ready,
         Tools.result(%{
           "status" => "unknown",
           "reason" => unknown.last_error,
           "retry_scheduled" => not is_nil(unknown.next_attempt_at)
         }), []}

      Enum.all?(rows, &(&1.status == :sent)) ->
        {:ready,
         Tools.result(%{
           "status" => "sent",
           "provider_message_id" => text.created_provider_message_id
         }), []}

      expired? ->
        {:ready, Tools.result(%{"status" => "queued"}), []}

      true ->
        :pending
    end
  end

  defp conversation_in_tx(run, binding, _adapter, %{"conversation_id" => id}) do
    with [_signal] <-
           Ankole.Signals.list_signals!(
             query: [
               filter: [
                 agent_uid: run.agent_uid,
                 reply_binding_name: binding.name,
                 conversation_id: id
               ],
               select: [:id],
               limit: 1
             ]
           ),
         %Conversation{kind: :external, external_kind: kind} = channel <-
           Ankole.Conversations.get_conversation!(id),
         true <- kind in [:im_dm, :im_group] do
      {:ok, channel}
    else
      _ -> {:error, :destination_not_reachable_from_binding}
    end
  end

  defp conversation_in_tx(run, binding, adapter, %{"principal_uid" => uid}) do
    with {:ok, %Conversation{kind: :external, external_kind: :im_dm, id: id}} <-
           Adapter.open_conversation(adapter, binding, uid) do
      conversation_in_tx(run, binding, adapter, %{"conversation_id" => id})
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
