defmodule Ankole.Connectors.AuthWaits do
  @moduledoc false
  require Ash.Query

  alias Ankole.Connectors.{Accounts, AuthWait, Registry, Store}
  alias Ankole.Conversations.Delivery.{Interactions, ReplyPresentation}
  alias Ankole.Repo

  @flush_key {__MODULE__, :flushed}

  def with_flush(fun) when is_function(fun, 0) do
    Process.put(@flush_key, [])

    try do
      fun.()
    after
      Process.delete(@flush_key)
    end
  end

  def publish_flushed do
    items = Process.get(@flush_key, [])
    Process.put(@flush_key, [])

    signals =
      items
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&is_struct(&1, Ankole.Signals.Signal))

    if signals != [], do: Ankole.Signals.publish_committed(signals)

    items
    |> Enum.map(&elem(&1, 1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.each(&Ankole.Conversations.Events.publish_message/1)

    :ok
  end

  def record_blocked_turn(error, context, toolkit, tool_name)
      when is_map(error) and is_map(context) and is_binary(toolkit) do
    with nil <- Map.get(context, :return_to),
         %{
           actor: %{
             principal: %{uid: agent_uid},
             turn_authority: {%Ankole.Sessions.RunRef{} = ref, _}
           }
         } <-
           context,
         {:conversation, conversation_id} <- Ankole.Sessions.Key.parse(ref.session_id),
         {:ok, _conversation} <- Ankole.Conversations.get_conversation(conversation_id) do
      query_params =
        error.authorization_url
        |> URI.parse()
        |> Map.get(:query)
        |> Kernel.||("")
        |> URI.decode_query()

      subject_kind = if query_params["subject_kind"] == "app", do: "app", else: "human"
      human_uid = if subject_kind == "human", do: human_authority_uid(agent_uid), else: nil

      if subject_kind == "human" and is_nil(human_uid) do
        :ok
      else
        plugin_id = Registry.plugin_id(toolkit)

        {auth_config_id, resolved_plugin_id} =
          case Store.get_auth_config(error.connection, plugin_id) do
            {:ok, config} -> {config.id, config.plugin_id}
            _ -> {nil, plugin_id}
          end

        attrs = %{
          signal_id: ref.signal_id,
          conversation_id: conversation_id,
          agent_uid: agent_uid,
          human_uid: human_uid,
          auth_config_id: auth_config_id,
          connection_slug: error.connection,
          plugin_id: resolved_plugin_id,
          toolkit: toolkit,
          tool_name: tool_name,
          subject_kind: subject_kind,
          required_scopes: List.wrap(Map.get(error, :scopes, [])),
          authorization_url: error.authorization_url,
          status: "recorded"
        }

        _ =
          if Repo.in_transaction?() do
            Ankole.Ash.create(AuthWait, :record, attrs)
          else
            Repo.transact_top_level(fn -> Ankole.Ash.create(AuthWait, :record, attrs) end)
          end

        :ok
      end
    else
      _ -> :ok
    end
  end

  def record_blocked_turn(_error, _context, _toolkit, _tool_name), do: :ok

  def list_for_signal(signal_id) when is_binary(signal_id) do
    case Ecto.UUID.cast(signal_id) do
      {:ok, signal_id} ->
        AuthWait
        |> Ash.Query.filter(signal_id == ^signal_id)
        |> Ash.Query.sort(inserted_at: :asc, id: :asc)
        |> Ankole.Ash.read!()

      :error ->
        []
    end
  end

  def list_for_signal(_), do: []

  def active_wait_for_signal(signal_id) when is_binary(signal_id) do
    signal_id
    |> list_for_signal()
    |> Enum.find(&(&1.status in ["recorded", "pending"]))
  end

  def active_wait_for_signal(_), do: nil

  def unready_wait_for_signal(signal_id) when is_binary(signal_id) do
    signal_id
    |> list_for_signal()
    |> Enum.find(&(&1.status in ["recorded", "pending"] and not account_ready?(&1)))
  end

  def unready_wait_for_signal(_), do: nil

  def interaction_local_id(%AuthWait{id: id}), do: "connector_auth:" <> id

  def client_payload(%AuthWait{} = wait, signal_id) do
    local_id = interaction_local_id(wait)

    {display_name, auth_scheme} =
      case Store.get_auth_config(wait.connection_slug, wait.plugin_id) do
        {:ok, config} -> {config.display_name || wait.connection_slug, config.auth_scheme}
        _ -> {wait.connection_slug, "oauth2"}
      end

    %{
      "wait_id" => wait.id,
      "interaction_id" => signal_id <> ":" <> local_id,
      "connection_slug" => wait.connection_slug,
      "display_name" => display_name,
      "plugin_id" => wait.plugin_id,
      "toolkit" => wait.toolkit,
      "tool_name" => wait.tool_name,
      "subject_kind" => wait.subject_kind,
      "human_uid" => wait.human_uid,
      "auth_scheme" => auth_scheme,
      "required_scopes" => wait.required_scopes || [],
      "authorization_url" => wait.authorization_url
    }
  end

  def build_presentation(%AuthWait{} = wait, signal_id, answer_text) do
    local_id = interaction_local_id(wait)
    payload = client_payload(wait, signal_id)
    display_name = payload["display_name"]

    prompt =
      case answer_text do
        text when is_binary(text) and text != "" ->
          text

        _ ->
          "Connect #{display_name} to continue this request."
      end

    ReplyPresentation.new(state: "awaiting_input")
    |> ReplyPresentation.link_interaction_request(signal_id, %{
      "interaction_id" => local_id,
      "prompt" => prompt,
      "label" => "Connect #{display_name}",
      "url" => absolute_authorization_url(wait.authorization_url)
    })
  end

  defp absolute_authorization_url("https://" <> _ = url), do: url
  defp absolute_authorization_url("http://" <> _ = url), do: url

  defp absolute_authorization_url("/" <> _ = path) do
    String.trim_trailing(AnkoleWeb.Endpoint.url(), "/") <> path
  end

  defp absolute_authorization_url(_other) do
    String.trim_trailing(AnkoleWeb.Endpoint.url(), "/") <> "/connectors"
  end

  def mark_pending_in_tx(%AuthWait{} = wait, local_id) when is_binary(local_id) do
    :ok = Repo.require_transaction()

    locked =
      AuthWait
      |> Ash.Query.filter(id == ^wait.id)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!(lock_identity: {"connector_auth_waits", [wait.id]})

    if locked do
      Ankole.Ash.update(locked, :mark_pending, %{
        interaction_id: local_id,
        status: "pending"
      })
    else
      {:ok, wait}
    end
  end

  @doc """
  Finalizes a blocked-turn AuthWait right after opening its reply interaction.
  If the required account was already connected before the turn finished posting
  (`record -> connect -> post`), resolves the interaction immediately and returns
  any woken continuation Signals so the outer commit delivers them.
  """
  def activate_or_complete_in_tx(
        %AuthWait{} = wait,
        %Ankole.Signals.Signal{} = source,
        local_id,
        now
      )
      when is_binary(local_id) do
    :ok = Repo.require_transaction()

    case ready_account(wait) do
      :not_ready ->
        with {:ok, _} <- mark_pending_in_tx(wait, local_id), do: {:ok, []}

      {:ok, config, account} ->
        actor_uid =
          account.owner_principal_uid || config.created_by_uid || wait.human_uid || "system"

        actor_name = resolve_actor_name(actor_uid)

        answer = %{
          "kind" => "connector_connected",
          "value" => config.slug
        }

        {next_status, woken_signals} =
          case Interactions.resolve_external_wait_in_tx(
                 source,
                 local_id,
                 actor_uid,
                 actor_name,
                 answer,
                 now
               ) do
            {:ok, %Ankole.Signals.Signal{} = woken} ->
              {"completed", [woken]}

            {:ok, %{signals: signals}} ->
              {"completed", List.wrap(signals)}

            _stale ->
              {"superseded", []}
          end

        locked =
          AuthWait
          |> Ash.Query.filter(id == ^wait.id)
          |> Ash.Query.lock(:for_update)
          |> Ankole.Ash.read_one!(lock_identity: {"connector_auth_waits", [wait.id]})

        if locked do
          {:ok, _} =
            Ankole.Ash.update(locked, :resolve, %{
              status: next_status,
              auth_config_id: config.id
            })
        end

        {:ok, woken_signals}
    end
  end

  @doc """
  Resolves pending connector auth waits matching `config` and `account` in
  strictly ascending lock order: caller holds Rank 6 -> Session Rank 9 ->
  Signal & PreviewState Rank 11 -> AuthWait Rank 12.
  """
  def resolve_for_account_in_tx(config, account) do
    :ok = Repo.require_transaction()
    candidates = matching_pending_waits(config, account)

    if candidates == [] do
      :ok
    else
      signal_ids = candidates |> Enum.map(& &1.signal_id) |> Enum.uniq()

      signals =
        Ankole.Signals.list_signals!(query: [filter: [id: [in: signal_ids]]])
        |> Map.new(&{&1.id, &1})

      session_keys =
        candidates
        |> Enum.flat_map(fn wait ->
          case signals[wait.signal_id] do
            %{agent_uid: uid, session_id: session_id} -> [{uid, session_id}]
            _ -> []
          end
        end)
        |> Enum.uniq()
        |> Enum.sort()

      :ok = Ankole.Sessions.Queue.lock_sessions_in_tx(session_keys)
      now = DateTime.utc_now(:microsecond)
      actor_uid = account.owner_principal_uid || config.created_by_uid || "system"
      actor_name = resolve_actor_name(actor_uid)

      outcomes =
        candidates
        |> Enum.sort_by(&{&1.signal_id, &1.id})
        |> Map.new(fn wait ->
          local_id = wait.interaction_id || interaction_local_id(wait)

          outcome =
            case signals[wait.signal_id] do
              nil ->
                :superseded

              source ->
                answer = %{
                  "kind" => "connector_connected",
                  "value" => config.slug
                }

                case Interactions.resolve_external_wait_in_tx(
                       source,
                       local_id,
                       actor_uid,
                       actor_name,
                       answer,
                       now
                     ) do
                  {:ok, woken} ->
                    buffer_flushed(woken, wait.conversation_id)
                    :completed

                  _stale ->
                    :superseded
                end
            end

          {wait.id, outcome}
        end)

      wait_ids = candidates |> Enum.map(& &1.id) |> Enum.sort()

      locked_waits =
        AuthWait
        |> Ash.Query.filter(id in ^wait_ids)
        |> Ash.Query.sort(id: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read!(lock_identity: {:rows, "connector_auth_waits", :id})

      Enum.each(locked_waits, fn locked ->
        next_status =
          case outcomes[locked.id] do
            :completed -> "completed"
            _ -> "superseded"
          end

        {:ok, _} =
          Ankole.Ash.update(locked, :resolve, %{
            status: next_status,
            auth_config_id: config.id
          })
      end)

      :ok
    end
  end

  defp buffer_flushed(woken, conversation_id) do
    case Process.get(@flush_key) do
      list when is_list(list) -> Process.put(@flush_key, [{woken, conversation_id} | list])
      _ -> :ok
    end
  end

  defp matching_pending_waits(config, account) do
    slug = config.slug
    config_id = config.id
    kind = account.subject_kind
    owner_uid = account.owner_principal_uid

    query =
      AuthWait
      |> Ash.Query.filter(
        status == "pending" and subject_kind == ^kind and
          (auth_config_id == ^config_id or
             (is_nil(auth_config_id) and connection_slug == ^slug))
      )

    query =
      if kind == "human" and is_binary(owner_uid) do
        Ash.Query.filter(query, human_uid == ^owner_uid)
      else
        query
      end

    query
    |> Ankole.Ash.read!()
    |> Enum.filter(&scopes_satisfied?(&1, config, account))
  end

  defp account_ready?(%AuthWait{} = wait) do
    match?({:ok, _, _}, ready_account(wait))
  end

  defp ready_account(%AuthWait{} = wait) do
    with {:ok, config} <- Store.get_auth_config(wait.connection_slug, wait.plugin_id),
         false <- is_nil(config.id) do
      case wait.subject_kind do
        "human" when is_binary(wait.human_uid) ->
          case Accounts.get_account(config.id, "human", wait.human_uid) do
            {:ok, %{} = account} ->
              if Accounts.valid?(account) and scopes_satisfied?(wait, config, account),
                do: {:ok, config, account},
                else: :not_ready

            _ ->
              :not_ready
          end

        "app" ->
          case Accounts.application_account(config, nil) do
            {:ok, %{} = account} ->
              if Accounts.valid?(account) and scopes_satisfied?(wait, config, account),
                do: {:ok, config, account},
                else: :not_ready

            _ ->
              :not_ready
          end

        _ ->
          :not_ready
      end
    else
      _ -> :not_ready
    end
  end

  defp scopes_satisfied?(%AuthWait{required_scopes: required}, config, account) do
    required = required || []
    granted = account.granted_scopes || []

    case Registry.adapter(config.plugin_id) do
      {:ok, adapter} ->
        if function_exported?(adapter, :scopes_satisfied?, 3),
          do: adapter.scopes_satisfied?(required, granted, config),
          else: Enum.all?(required, &(&1 in granted))

      _ ->
        Enum.all?(required, &(&1 in granted))
    end
  end

  defp human_authority_uid(uid) do
    authority = Ankole.Principals.authority_uid(uid)

    case Ankole.Principals.get_principal(authority) do
      {:ok, %{type: :human, status: :active}} -> authority
      _ -> nil
    end
  end

  defp resolve_actor_name(uid) when is_binary(uid) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, principal} -> principal.display_name || uid
      _ -> uid
    end
  end
end
