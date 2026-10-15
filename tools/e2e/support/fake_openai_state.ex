defmodule Ankole.E2E.FakeOpenAIState do
  @moduledoc """
  Records fake upstream requests made by AIGateway during Lark worker chaos tests.
  """

  use Agent

  @doc """
  Starts or resets the request recorder for the current test process.
  """
  @spec start_link(pid()) :: {:ok, pid()}
  def start_link(owner) do
    initial = fn -> %{owner: owner, requests: [], counters: %{}, waiting: %{}} end

    case Agent.start_link(initial, name: __MODULE__) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Agent.update(__MODULE__, fn _state -> initial.() end)
        {:ok, pid}
    end
  end

  @doc """
  Records one upstream request and returns that request kind's counter.
  """
  @spec record(atom(), map()) :: pos_integer()
  def record(kind, request) do
    Agent.get_and_update(__MODULE__, fn state ->
      count = Map.get(state.counters, kind, 0) + 1
      counters = Map.put(state.counters, kind, count)
      entry = %{kind: kind, count: count, model: request["model"], request: request}
      Kernel.send(state.owner, {:fake_llm_request, kind, count, request})
      {count, %{state | counters: counters, requests: [entry | state.requests]}}
    end)
  end

  @doc """
  Returns request counters grouped by scenario kind.
  """
  @spec counters() :: map()
  def counters, do: Agent.get(__MODULE__, & &1.counters)

  @doc """
  Returns recorded upstream requests in arrival order.
  """
  @spec requests() :: [map()]
  def requests, do: Agent.get(__MODULE__, fn state -> Enum.reverse(state.requests) end)

  def await_release(kind) do
    receiver = self()
    ref = make_ref()
    Agent.update(__MODULE__, &put_in(&1.waiting[kind], {receiver, ref}))

    receive do
      {:release_fake_response, ^ref} -> :ok
    after
      60_000 -> raise "Fake upstream response was not released: #{kind}"
    end
  end

  def waiting?(kind), do: Agent.get(__MODULE__, &Map.has_key?(&1.waiting, kind))

  def release(kind) do
    waiting =
      Agent.get_and_update(__MODULE__, fn state ->
        {waiting, remaining} = Map.pop(state.waiting, kind)
        {waiting, %{state | waiting: remaining}}
      end)

    case waiting do
      {receiver, ref} ->
        send(receiver, {:release_fake_response, ref})
        :ok

      nil ->
        {:error, :not_waiting}
    end
  end
end
