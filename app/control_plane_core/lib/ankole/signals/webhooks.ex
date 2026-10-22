defmodule Ankole.Signals.Webhooks do
  @moduledoc """
  Owns webhook capability URLs and their durable consumer handoff.

  A capability URL authorizes one delivery only. It does not authenticate the
  facts in the request body. An Agent or bound automation job must verify those
  facts through the external system before it makes a consequential change.
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Ankole.Signals.Target, as: ExecutionTarget
  alias Ankole.AutomationJobs
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationJobRun
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Conversations.Route
  alias Ankole.Signals.WebhookEndpoint

  @active_statuses [:armed, :active]
  @token_pattern ~r/\Awh_[A-Za-z0-9_-]{43}\z/

  @type receive_result ::
          {:ok,
           %{
             optional(:signal) => Ankole.Signals.Signal.t(),
             optional(:automation_job_run) => AutomationJobRun.t(),
             status: :accepted | :ignored,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}

  @doc """
  Generates a capability for one new endpoint and stores only its token digest.

  The returned plaintext token is used once to construct the callback URL.
  """
  @spec create_endpoint(map(), keyword()) ::
          {:ok, %{webhook_endpoint: WebhookEndpoint.t(), token: String.t()}} | {:error, term()}
  def create_endpoint(attrs, opts \\ [])

  def create_endpoint(attrs, opts) when is_map(attrs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    token = "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    with {:ok, attrs} <- create_attrs(attrs, token),
         :ok <- validate_public_target(attrs),
         :ok <- validate_expiry(attrs, now) do
      Repo.transact(fn repo ->
        with :ok <-
               AutomationJobs.validate_bindable_in_tx(
                 repo,
                 Map.get(attrs, "automation_job_id"),
                 Map.fetch!(attrs, "agent_uid")
               ),
             {:ok, endpoint} <-
               Ankole.Ash.create(WebhookEndpoint, :create, attrs) do
          {:ok, %{webhook_endpoint: endpoint, token: token}}
        end
      end)
    end
  end

  def create_endpoint(_attrs, _opts), do: {:error, :invalid_webhook_endpoint}

  @doc """
  Lists webhook endpoints for one Agent session, for every session of the
  Agent when `session_id` is `nil`, or across every Agent when `agent_uid` is
  also `nil`.

  Active-only lists exclude endpoints whose expiry time has already passed,
  even if the periodic sweep has not updated their stored status yet.
  """
  @spec list_endpoints(String.t() | nil, String.t() | nil, keyword()) :: [WebhookEndpoint.t()]
  def list_endpoints(agent_uid, session_id, opts \\ [])
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(session_id) or is_nil(session_id)) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit()

    WebhookEndpoint
    |> maybe_where_agent(agent_uid)
    |> maybe_where_session(session_id)
    |> maybe_active_only(Keyword.get(opts, :active_only, false), now)
    |> order_by([endpoint], desc: endpoint.inserted_at, desc: endpoint.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Cancels an active endpoint. Repeating the operation keeps the terminal state.

  A `nil` `session_id` accepts any session of the Agent.
  """
  @spec cancel_endpoint(String.t(), String.t() | nil, Ecto.UUID.t(), keyword()) ::
          {:ok,
           %{
             status: :cancelled | :already_terminal,
             webhook_endpoint: WebhookEndpoint.t()
           }}
          | {:error, term()}
  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts \\ [])

  def cancel_endpoint(agent_uid, session_id, endpoint_id, opts)
      when (is_binary(agent_uid) or is_nil(agent_uid)) and
             (is_binary(session_id) or is_nil(session_id)) and
             is_binary(endpoint_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_endpoint(repo, endpoint_id, agent_uid && String.downcase(agent_uid), session_id) do
        %WebhookEndpoint{} = endpoint ->
          cancel_locked_endpoint(repo, endpoint, now)

        nil ->
          {:error, :webhook_endpoint_not_found}
      end
    end)
  end

  def cancel_endpoint(_agent_uid, _session_id, _endpoint_id, _opts),
    do: {:error, :webhook_endpoint_not_found}

  @doc """
  Accepts one callback and stores its Signal or automation job run in the
  same transaction.
  """
  @spec receive(String.t(), [{String.t(), String.t()}], binary(), keyword()) :: receive_result()
  def receive(token, headers, body, opts \\ [])

  def receive(token, headers, body, opts)
      when is_binary(token) and is_list(headers) and is_binary(body) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    receive_at_endpoint(token, "raw", {:raw, headers, body}, now)
  end

  def receive(_token, _headers, _body, _opts), do: {:error, :webhook_endpoint_not_found}

  @doc "Receives a structured CloudEvent through an endpoint's own capability."
  def receive_cloudevent(token, event, opts \\ []) do
    receive_at_endpoint(
      token,
      "cloudevents",
      {:cloudevents, event},
      Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    )
  end

  defp receive_at_endpoint(token, format, input, now) do
    with :ok <- validate_token(token),
         %WebhookEndpoint{tenant_id: tenant_id} <-
           Repo.across_tenants(fn ->
             Repo.get_by(WebhookEndpoint, token_digest: token_digest(token))
           end) do
      Repo.with_tenant(tenant_id, fn ->
        Repo.transact(fn repo ->
          case lock_endpoint_by_token(repo, token) do
            %WebhookEndpoint{event_format: ^format} = endpoint ->
              receive_locked(repo, endpoint, input, now)

            %WebhookEndpoint{} ->
              {:error, :webhook_endpoint_not_found}

            nil ->
              {:error, :webhook_endpoint_not_found}
          end
        end)
      end)
    else
      _ -> {:error, :webhook_endpoint_not_found}
    end
  end

  # Keeps only callback headers that carry event metadata.
  #
  # Authentication and general HTTP headers are deliberately discarded.
  #
  @spec allowlisted_headers([{String.t(), String.t()}]) :: map()
  defp allowlisted_headers(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn
      {name, value}, acc when is_binary(name) and is_binary(value) ->
        name = String.downcase(name)

        if allowlisted_header?(name) and durable_text?(value) do
          Map.update(acc, name, value, &(&1 <> ", " <> value))
        else
          acc
        end

      _header, acc ->
        acc
    end)
  end

  @doc """
  Marks due active endpoints as expired and returns the number changed.
  """
  @spec expire_due(DateTime.t()) :: non_neg_integer()
  def expire_due(%DateTime{} = now) do
    {:ok, count} =
      Repo.transact(fn repo ->
        WebhookEndpoint
        |> Ash.Query.filter(status in ^@active_statuses and expires_at <= ^now)
        |> Ankole.Ash.bulk_update(:expire, %{},
          strategy: [:atomic],
          return_records?: true,
          return_errors?: true
        )
        |> case do
          %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records)}
          %Ash.BulkResult{errors: errors} -> repo.rollback(errors)
        end
      end)

    count
  end

  @doc """
  Returns the Console-safe endpoint projection.
  """
  @spec console_projection(WebhookEndpoint.t()) :: map()
  def console_projection(%WebhookEndpoint{} = endpoint) do
    %{
      id: endpoint.id,
      agent_uid: endpoint.agent_uid,
      binding_name: endpoint.binding_name,
      session_id: endpoint.session_id,
      conversation_id: endpoint.conversation_id,
      provider_thread_id: endpoint.provider_thread_id,
      source_signal_id: endpoint.source_signal_id,
      event_format: endpoint.event_format,
      provider_message_id: endpoint.provider_message_id,
      source_provenance: endpoint.source_provenance || %{},
      automation_job_id: endpoint.automation_job_id,
      label: endpoint.label,
      mode: endpoint.mode,
      status: Atom.to_string(endpoint.status),
      expires_at: Ankole.Attrs.datetime_iso8601(endpoint.expires_at),
      fired_at: Ankole.Attrs.datetime_iso8601(endpoint.fired_at),
      cancelled_at: Ankole.Attrs.datetime_iso8601(endpoint.cancelled_at),
      created_at: Ankole.Attrs.datetime_iso8601(endpoint.inserted_at),
      updated_at: Ankole.Attrs.datetime_iso8601(endpoint.updated_at)
    }
  end

  @doc """
  Returns the model-safe endpoint projection.
  """
  @spec model_projection(WebhookEndpoint.t()) :: map()
  def model_projection(%WebhookEndpoint{} = endpoint) do
    %{
      "id" => endpoint.id,
      "label" => endpoint.label,
      "mode" => endpoint.mode,
      "status" => Atom.to_string(endpoint.status),
      "automation_job_id" => endpoint.automation_job_id,
      "expires_at" => Ankole.Attrs.datetime_iso8601(endpoint.expires_at),
      "created_at" => Ankole.Attrs.datetime_iso8601(endpoint.inserted_at)
    }
  end

  @doc """
  Calculates the digest stored for one plaintext callback token.
  """
  @spec token_digest(String.t()) :: String.t()
  def token_digest(token) when is_binary(token) do
    token
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp create_attrs(attrs, token) do
    attrs = Ankole.Attrs.normalize_external_attrs(attrs)

    {:ok,
     attrs
     |> Map.put(
       "agent_uid",
       then(Map.get(attrs, "agent_uid"), fn uid ->
         if is_binary(uid), do: Ankole.PrincipalKey.canonicalize(uid), else: uid
       end)
     )
     |> Map.put("token_digest", token_digest(token))}
  end

  defp validate_expiry(%{"expires_at" => %DateTime{} = expires_at}, %DateTime{} = now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :webhook_expiry_must_be_future}
  end

  defp validate_expiry(_attrs, _now), do: {:error, :invalid_webhook_expiry}

  defp validate_public_target(%{"session_id" => session}) when is_binary(session) do
    case ExecutionTarget.parse(%{session_id: session}) do
      :error ->
        {:error, :invalid_signal_target}

      _ ->
        if Ankole.Sessions.Key.routable?(session), do: :ok, else: {:error, :invalid_signal_target}
    end
  end

  defp validate_public_target(_attrs), do: :ok

  defp cancel_locked_endpoint(_repo, endpoint, now) do
    cond do
      endpoint.status not in @active_statuses ->
        {:ok, %{status: :already_terminal, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- Ankole.Ash.update(endpoint, :expire, %{}) do
          {:ok, %{status: :already_terminal, webhook_endpoint: expired}}
        end

      true ->
        with {:ok, cancelled} <-
               Ankole.Ash.update(endpoint, :cancel, %{cancelled_at: now}) do
          {:ok, %{status: :cancelled, webhook_endpoint: cancelled}}
        end
    end
  end

  defp receive_locked(repo, endpoint, input, now) do
    cond do
      not Ankole.Tenants.accepting_work?(endpoint.tenant_id) ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      endpoint.status not in @active_statuses ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint}}

      DateTime.compare(endpoint.expires_at, now) != :gt ->
        with {:ok, expired} <- Ankole.Ash.update(endpoint, :expire, %{}) do
          {:ok, %{status: :ignored, webhook_endpoint: expired}}
        end

      true ->
        case input do
          {:raw, headers, body} -> append_receipt(repo, endpoint, headers, body, now)
          {:cloudevents, event} -> append_cloudevent(repo, endpoint, event, now)
        end
    end
  end

  defp append_cloudevent(repo, endpoint, event, now) do
    case Ankole.Signals.CloudEvents.accept_in_tx(repo, endpoint, event, now) do
      {:ok, []} ->
        {:ok, %{status: :ignored, webhook_endpoint: endpoint, signals: []}}

      {:ok, signals} ->
        with {:ok, endpoint} <- maybe_mark_fired(repo, endpoint, now) do
          {:ok, %{status: :accepted, webhook_endpoint: endpoint, signals: signals}}
        end

      error ->
        error
    end
  end

  defp append_receipt(repo, endpoint, headers, body, now) do
    source_event_id = "webhook:#{endpoint.id}:#{UUIDv7.autogenerate()}"
    payload = receipt_payload(endpoint, source_event_id, headers, body, now)

    with {:ok, delivery} <- deliver_receipt(repo, endpoint, source_event_id, payload, now),
         {:ok, endpoint} <- maybe_mark_fired(repo, endpoint, now) do
      {:ok, receipt_result(endpoint, delivery)}
    end
  end

  defp deliver_receipt(repo, endpoint, source_event_id, payload, now) do
    Ankole.Signals.Trigger.deliver_in_tx(repo, endpoint, payload, now, fn ->
      with {:ok, owner} <- Route.long_lived_owner(endpoint.agent_uid, endpoint.session_id),
           attrs <- receipt_signal_attrs(endpoint, source_event_id, payload, now),
           attrs <-
             Map.merge(attrs, %{
               target: %{agent_uid: endpoint.agent_uid, session_id: owner.session_id},
               reply_route: owner.reply_route || attrs.reply_route
             }) do
        Ankole.Signals.accept_in_tx(repo, attrs)
      end
    end)
  end

  defp receipt_signal_attrs(endpoint, source_event_id, payload, now) do
    %{
      producer: :external,
      source: payload["source"],
      id: source_event_id,
      type: "webhook.received",
      subject: payload["subject"],
      time: now,
      data: payload["data"],
      target: %{agent_uid: endpoint.agent_uid, session_id: endpoint.session_id},
      authorization: Ankole.Principals.WorkAccess.service(),
      sender: nil,
      reply_route: %{
        binding_name: endpoint.binding_name,
        conversation_id: endpoint.conversation_id,
        provider_thread_id: endpoint.provider_thread_id,
        provider_message_id: endpoint.provider_message_id
      }
    }
  end

  defp receipt_result(endpoint, {:signal, signal}) do
    %{status: :accepted, webhook_endpoint: endpoint, signal: signal}
  end

  defp receipt_result(endpoint, {:automation_job_run, run, signal}) do
    %{
      status: :accepted,
      webhook_endpoint: endpoint,
      automation_job_run: run,
      signal: signal
    }
  end

  defp receipt_payload(endpoint, source_event_id, headers, body, now) do
    {encoded_body, encoding} = encode_body(body)

    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://signals-gateway/webhooks",
      "subject" => "webhook_endpoint:#{endpoint.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => "webhook.received",
      "data" => %{
        "webhook_endpoint" => %{
          "id" => endpoint.id,
          "label" => endpoint.label,
          "mode" => endpoint.mode
        },
        "headers" => allowlisted_headers(headers),
        "body" => encoded_body,
        "body_encoding" => encoding,
        "body_size" => byte_size(body),
        "received_at" => DateTime.to_iso8601(now),
        "reply_route" =>
          reject_nil_values(%{
            "binding_name" => endpoint.binding_name,
            "conversation_id" => endpoint.conversation_id,
            "provider_thread_id" => endpoint.provider_thread_id,
            "provider_message_id" => endpoint.provider_message_id
          }),
        "source_signal_id" => endpoint.source_signal_id,
        "source_provenance" => endpoint.source_provenance || %{}
      }
    }
  end

  defp maybe_mark_fired(_repo, %WebhookEndpoint{mode: "one_shot"} = endpoint, now),
    do: Ankole.Ash.update(endpoint, :fire, %{fired_at: now})

  defp maybe_mark_fired(_repo, %WebhookEndpoint{mode: "standing"} = endpoint, _now),
    do: {:ok, endpoint}

  defp lock_endpoint(repo, endpoint_id, agent_uid, session_id) do
    WebhookEndpoint
    |> where([endpoint], endpoint.id == ^endpoint_id)
    |> maybe_where_agent(agent_uid)
    |> maybe_where_session(session_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_endpoint_by_token(repo, token) do
    digest = token_digest(token)

    WebhookEndpoint
    |> where([endpoint], endpoint.token_digest == ^digest)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid),
    do: where(query, [endpoint], endpoint.agent_uid == ^String.downcase(agent_uid))

  defp maybe_where_session(query, nil), do: query

  defp maybe_where_session(query, session_id),
    do: where(query, [endpoint], endpoint.session_id == ^session_id)

  defp maybe_active_only(query, false, _now), do: query

  defp maybe_active_only(query, true, now) do
    where(
      query,
      [endpoint],
      endpoint.status in ^@active_statuses and endpoint.expires_at > ^now
    )
  end

  defp allowlisted_header?("content-type"), do: true
  defp allowlisted_header?("x-hub-signature-256"), do: true
  defp allowlisted_header?("ce-" <> _name), do: true
  defp allowlisted_header?("x-github-" <> _name), do: true
  defp allowlisted_header?(_name), do: false

  defp encode_body(body) do
    if durable_text?(body),
      do: {body, "utf-8"},
      else: {Base.encode64(body), "base64"}
  end

  defp durable_text?(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch

  defp validate_token(token) when is_binary(token) do
    if Regex.match?(@token_pattern, token),
      do: :ok,
      else: {:error, :invalid_webhook_token}
  end

  defp validate_token(_token), do: {:error, :invalid_webhook_token}

  defp bounded_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, 500)
  defp bounded_limit(_limit), do: 100

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
