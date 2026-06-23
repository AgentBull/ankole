# Event Sourcing & CQRS Worked Examples

Complete working examples for event-sourced Elixir applications using Commanded. Patterns sourced from Commanded library test suite (`commanded/commanded` on GitHub) and `commanded_ecto_projections`.

---

## 1. Aggregate: Command Handling and State Reconstruction

From Commanded's test suite pattern: aggregates are pure functions tested via `execute/2` and `apply/2`.

```elixir
# lib/my_app/aggregates/account.ex
# NOTE: Production aggregates need `use Commanded.Aggregates.Aggregate` — see eventsourcing-reference.md
# Shown here as plain module to demonstrate execute/2 and apply/2 as pure functions for testing.
defmodule MyApp.Aggregates.Account do
  defstruct [
    :account_id,
    :email,
    :name,
    balance: 0,
    status: nil
  ]

  alias MyApp.Commands.{OpenAccount, DepositFunds, WithdrawFunds, CloseAccount}
  alias MyApp.Events.{AccountOpened, FundsDeposited, FundsWithdrawn, AccountClosed}

  # Command handling — validate against state, emit events or return errors

  def execute(%__MODULE__{status: nil}, %OpenAccount{} = cmd) do
    %AccountOpened{
      account_id: cmd.account_id,
      email: cmd.email,
      name: cmd.name,
      initial_balance: cmd.initial_balance || 0,
      opened_at: DateTime.utc_now()
    }
  end

  def execute(%__MODULE__{status: _}, %OpenAccount{}) do
    {:error, :account_already_exists}
  end

  def execute(%__MODULE__{status: :open} = acct, %DepositFunds{} = cmd) do
    %FundsDeposited{
      account_id: acct.account_id,
      amount: cmd.amount,
      new_balance: acct.balance + cmd.amount
    }
  end

  def execute(%__MODULE__{status: :closed}, %DepositFunds{}), do: {:error, :account_closed}
  def execute(%__MODULE__{status: nil}, %DepositFunds{}), do: {:error, :account_not_found}

  def execute(%__MODULE__{status: :open, balance: bal} = acct, %WithdrawFunds{amount: amt})
      when bal >= amt do
    %FundsWithdrawn{
      account_id: acct.account_id,
      amount: amt,
      new_balance: bal - amt
    }
  end

  def execute(%__MODULE__{status: :open}, %WithdrawFunds{}), do: {:error, :insufficient_funds}
  def execute(%__MODULE__{status: :closed}, %WithdrawFunds{}), do: {:error, :account_closed}

  def execute(%__MODULE__{status: :open, balance: 0} = acct, %CloseAccount{}) do
    %AccountClosed{account_id: acct.account_id, closed_at: DateTime.utc_now()}
  end

  def execute(%__MODULE__{status: :open, balance: b}, %CloseAccount{}) when b > 0 do
    {:error, :account_has_balance}
  end

  def execute(%__MODULE__{status: :closed}, %CloseAccount{}), do: {:error, :already_closed}

  # State reconstruction — apply events to rebuild aggregate state

  def apply(%__MODULE__{} = acct, %AccountOpened{} = e) do
    %__MODULE__{acct |
      account_id: e.account_id, email: e.email, name: e.name,
      balance: e.initial_balance, status: :open
    }
  end

  def apply(%__MODULE__{} = acct, %FundsDeposited{new_balance: bal}) do
    %__MODULE__{acct | balance: bal}
  end

  def apply(%__MODULE__{} = acct, %FundsWithdrawn{new_balance: bal}) do
    %__MODULE__{acct | balance: bal}
  end

  def apply(%__MODULE__{} = acct, %AccountClosed{closed_at: t}) do
    %__MODULE__{acct | status: :closed, closed_at: t}
  end
end
```

---

## 2. Commands and Events

```elixir
# Commands — plain structs, represent intent
defmodule MyApp.Commands.OpenAccount do
  @derive Inspect
  defstruct [:account_id, :email, :name, :initial_balance]
end

defmodule MyApp.Commands.DepositFunds do
  @derive Inspect
  defstruct [:account_id, :amount]
end

defmodule MyApp.Commands.WithdrawFunds do
  @derive Inspect
  defstruct [:account_id, :amount]
end

defmodule MyApp.Commands.CloseAccount do
  @derive Inspect
  defstruct [:account_id]
end

# Events — past tense, immutable facts
defmodule MyApp.Events.AccountOpened do
  @derive Inspect
  defstruct [:account_id, :email, :name, :initial_balance, :opened_at]
end

defmodule MyApp.Events.FundsDeposited do
  @derive Inspect
  defstruct [:account_id, :amount, :new_balance]
end

defmodule MyApp.Events.FundsWithdrawn do
  @derive Inspect
  defstruct [:account_id, :amount, :new_balance]
end

defmodule MyApp.Events.AccountClosed do
  @derive Inspect
  defstruct [:account_id, :closed_at]
end
```

---

## 3. Command Validation with Ecto Changesets

```elixir
defmodule MyApp.Commands.OpenAccount do
  use Ecto.Schema
  import Ecto.Changeset

  @derive Inspect
  @primary_key false
  embedded_schema do
    field :account_id, :string
    field :email, :string
    field :name, :string
    field :initial_balance, :integer, default: 0
  end

  defstruct [:account_id, :email, :name, :initial_balance]

  def validate(%__MODULE__{} = cmd) do
    %__MODULE__{}
    |> cast(Map.from_struct(cmd), [:account_id, :email, :name, :initial_balance])
    |> validate_required([:account_id, :email, :name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/)
    |> validate_number(:initial_balance, greater_than_or_equal_to: 0)
    |> case do
      %{valid?: true} -> :ok
      changeset -> {:error, traverse_errors(changeset)}
    end
  end

  defp traverse_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
```

---

## 4. Router and Application

From Commanded's `routing_commands_test.exs` — routers use `identify/2` and `dispatch/2`.

```elixir
# Router
defmodule MyApp.Router do
  use Commanded.Commands.Router

  alias MyApp.Aggregates.Account
  alias MyApp.Commands.{OpenAccount, DepositFunds, WithdrawFunds, CloseAccount}
  alias MyApp.Middleware.Validation

  identify Account, by: :account_id, prefix: "account-"

  middleware Validation

  dispatch [OpenAccount, DepositFunds, WithdrawFunds, CloseAccount],
    to: Account
end

# Application
defmodule MyApp.CommandedApp do
  use Commanded.Application,
    otp_app: :my_app,
    event_store: [
      adapter: Commanded.EventStore.Adapters.EventStore,
      event_store: MyApp.EventStore
    ]

  router MyApp.Router
end

# Validation middleware — from Commanded middleware test patterns
defmodule MyApp.Middleware.Validation do
  @behaviour Commanded.Middleware
  alias Commanded.Middleware.Pipeline

  @impl true
  def before_dispatch(%Pipeline{command: command} = pipeline) do
    if function_exported?(command.__struct__, :validate, 1) do
      case command.__struct__.validate(command) do
        :ok -> pipeline
        {:error, reason} ->
          pipeline
          |> Pipeline.respond({:error, reason})
          |> Pipeline.halt()
      end
    else
      pipeline
    end
  end

  @impl true
  def after_dispatch(pipeline), do: pipeline
  @impl true
  def after_failure(pipeline), do: pipeline
end
```

---

## 5. Ecto Projection

```elixir
# Projection schema
defmodule MyApp.Projections.AccountSummary do
  use Ecto.Schema

  @primary_key {:account_id, :string, []}
  schema "account_summaries" do
    field :email, :string
    field :name, :string
    field :balance, :integer, default: 0
    field :status, Ecto.Enum, values: [:open, :closed]
    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end

# Projector — builds read model from events
defmodule MyApp.Projectors.AccountSummary do
  use Commanded.Projections.Ecto,
    application: MyApp.CommandedApp,
    repo: MyApp.Repo,
    name: "AccountSummary"

  import Ecto.Query  # Required for from/2 in update_all projections

  alias MyApp.Events.{AccountOpened, FundsDeposited, FundsWithdrawn, AccountClosed}
  alias MyApp.Projections.AccountSummary

  project(%AccountOpened{} = e, _metadata, fn multi ->
    Ecto.Multi.insert(multi, :account, %AccountSummary{
      account_id: e.account_id,
      email: e.email,
      name: e.name,
      balance: e.initial_balance,
      status: :open,
      opened_at: e.opened_at
    })
  end)

  project(%FundsDeposited{} = e, _metadata, fn multi ->
    Ecto.Multi.update_all(multi, :account,
      from(a in AccountSummary, where: a.account_id == ^e.account_id),
      set: [balance: e.new_balance, updated_at: DateTime.utc_now()]
    )
  end)

  project(%FundsWithdrawn{} = e, _metadata, fn multi ->
    Ecto.Multi.update_all(multi, :account,
      from(a in AccountSummary, where: a.account_id == ^e.account_id),
      set: [balance: e.new_balance, updated_at: DateTime.utc_now()]
    )
  end)

  project(%AccountClosed{} = e, _metadata, fn multi ->
    Ecto.Multi.update_all(multi, :account,
      from(a in AccountSummary, where: a.account_id == ^e.account_id),
      set: [status: :closed, closed_at: e.closed_at]
    )
  end)
end

# Context module — query interface for projections
defmodule MyApp.Accounts do
  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Projections.AccountSummary

  def get_account(id), do: Repo.get(AccountSummary, id)

  def list_accounts(opts \\ []) do
    AccountSummary
    |> maybe_filter_status(opts[:status])
    |> order_by([a], desc: a.opened_at)
    |> Repo.all()
  end

  defp maybe_filter_status(q, nil), do: q
  defp maybe_filter_status(q, status), do: where(q, [a], a.status == ^status)
end
```

---

## 6. Process Manager (Saga)

From Commanded's `example_process_manager.ex` and `process_manager_routing_test.exs` — process managers use `interested?/1`, `handle/2`, and `apply/2`.

```elixir
defmodule MyApp.ProcessManagers.OrderFulfillment do
  use Commanded.ProcessManagers.ProcessManager,
    application: MyApp.CommandedApp,
    name: __MODULE__

  @derive Inspect
  defstruct [
    :order_id,
    :customer_id,
    :items,
    :total,
    payment_status: nil,
    inventory_status: nil,
    status: :pending
  ]

  alias MyApp.Events.{
    OrderPlaced, PaymentReceived, PaymentFailed,
    InventoryReserved, InventoryUnavailable, OrderShipped, OrderDelivered
  }
  alias MyApp.Commands.{
    ProcessPayment, ReserveInventory, ReleaseInventory, ShipOrder, CancelOrder
  }

  # Routing — lifecycle control
  def interested?(%OrderPlaced{order_id: id}), do: {:start, id}
  def interested?(%PaymentReceived{order_id: id}), do: {:continue, id}
  def interested?(%PaymentFailed{order_id: id}), do: {:continue, id}
  def interested?(%InventoryReserved{order_id: id}), do: {:continue, id}
  def interested?(%InventoryUnavailable{order_id: id}), do: {:continue, id}
  def interested?(%OrderShipped{order_id: id}), do: {:continue, id}
  def interested?(%OrderDelivered{order_id: id}), do: {:stop, id}
  def interested?(_), do: false

  # Event handling — emit commands to advance the process

  def handle(%__MODULE__{}, %OrderPlaced{} = e) do
    [
      %ProcessPayment{order_id: e.order_id, amount: e.total, customer_id: e.customer_id},
      %ReserveInventory{order_id: e.order_id, items: e.items}
    ]
  end

  # Both payment and inventory ready → ship
  def handle(%__MODULE__{inventory_status: :reserved} = s, %PaymentReceived{}) do
    %ShipOrder{order_id: s.order_id, items: s.items}
  end

  def handle(%__MODULE__{payment_status: :received} = s, %InventoryReserved{}) do
    %ShipOrder{order_id: s.order_id, items: s.items}
  end

  # Waiting for other step
  def handle(%__MODULE__{inventory_status: nil}, %PaymentReceived{}), do: []
  def handle(%__MODULE__{payment_status: nil}, %InventoryReserved{}), do: []

  # Compensation — payment failed, release inventory if reserved
  def handle(%__MODULE__{inventory_status: :reserved} = s, %PaymentFailed{}) do
    %ReleaseInventory{order_id: s.order_id, items: s.items}
  end

  def handle(%__MODULE__{} = s, %PaymentFailed{}) do
    %CancelOrder{order_id: s.order_id, reason: :payment_failed}
  end

  # Compensation — inventory unavailable
  def handle(%__MODULE__{} = s, %InventoryUnavailable{}) do
    %CancelOrder{order_id: s.order_id, reason: :inventory_unavailable}
  end

  def handle(%__MODULE__{}, %OrderShipped{}), do: []

  # State tracking
  def apply(%__MODULE__{} = s, %OrderPlaced{} = e) do
    %__MODULE__{s |
      order_id: e.order_id, customer_id: e.customer_id,
      items: e.items, total: e.total, status: :processing
    }
  end

  def apply(%__MODULE__{} = s, %PaymentReceived{}), do: %__MODULE__{s | payment_status: :received}
  def apply(%__MODULE__{} = s, %PaymentFailed{}), do: %__MODULE__{s | payment_status: :failed}
  def apply(%__MODULE__{} = s, %InventoryReserved{}), do: %__MODULE__{s | inventory_status: :reserved}
  def apply(%__MODULE__{} = s, %InventoryUnavailable{}), do: %__MODULE__{s | inventory_status: :unavailable}
  def apply(%__MODULE__{} = s, %OrderShipped{}), do: %__MODULE__{s | status: :shipped}
  def apply(%__MODULE__{} = s, %OrderDelivered{}), do: %__MODULE__{s | status: :completed}

  # Error handling — from Commanded's process_manager_error_handling_test.exs
  def error({:error, :concurrency_error}, command, _failure_context) do
    {:retry, command}
  end

  def error({:error, _reason}, _command, %{context: %{failures: f}}) when f >= 3 do
    {:stop, :too_many_failures}
  end

  def error({:error, _reason}, _command, _failure_context) do
    {:retry, :timer.seconds(5)}
  end
end
```

---

## 7. Event Handler (Notifier/Gateway Out)

From Commanded's `handle_event_test.exs` — event handlers subscribe to events and perform side effects.

```elixir
defmodule MyApp.EventHandlers.EmailNotifier do
  use Commanded.Event.Handler,
    application: MyApp.CommandedApp,
    name: __MODULE__

  alias MyApp.Events.{AccountOpened, AccountClosed}
  require Logger

  def handle(%AccountOpened{email: email, name: name}, _metadata) do
    MyApp.Mailer.send_welcome(email, name)
    :ok
  end

  def handle(%AccountClosed{} = event, metadata) do
    Logger.info("Account closed: #{event.account_id}, event: #{metadata.event_id}")
    :ok
  end

  # Catch-all for unhandled events
  def handle(_event, _metadata), do: :ok

  # Error handling with retry and skip — from event_handler_error_handling_test.exs
  def error({:error, reason}, _event, %{context: context}) do
    failures = Map.get(context, :failures, 0)

    cond do
      failures >= 3 ->
        Logger.error("Skipping event after #{failures} failures: #{inspect(reason)}")
        :skip

      transient_error?(reason) ->
        {:retry, :timer.seconds(min(30, Integer.pow(2, failures)))}

      true ->
        :skip
    end
  end

  defp transient_error?(:timeout), do: true
  defp transient_error?(:econnrefused), do: true
  defp transient_error?(_), do: false
end
```

---

## 8. Testing Aggregates (Pure Function Tests)

From Commanded's own aggregate test patterns — test `execute/2` input/output, not internal state.

```elixir
defmodule MyApp.Aggregates.AccountTest do
  use ExUnit.Case, async: true

  alias MyApp.Aggregates.Account
  alias MyApp.Commands.{OpenAccount, DepositFunds, WithdrawFunds, CloseAccount}
  alias MyApp.Events.{AccountOpened, FundsDeposited, FundsWithdrawn, AccountClosed}

  describe "OpenAccount" do
    test "creates account when none exists" do
      result = Account.execute(%Account{}, %OpenAccount{
        account_id: "acc-1", email: "user@example.com", name: "Test", initial_balance: 100
      })

      assert %AccountOpened{account_id: "acc-1", initial_balance: 100} = result
    end

    test "rejects when account already exists" do
      state = %Account{account_id: "acc-1", status: :open}

      assert {:error, :account_already_exists} =
               Account.execute(state, %OpenAccount{
                 account_id: "acc-1", email: "x@x.com", name: "X"
               })
    end
  end

  describe "WithdrawFunds" do
    test "withdraws with sufficient balance" do
      state = open_account(balance: 100)

      assert %FundsWithdrawn{amount: 30, new_balance: 70} =
               Account.execute(state, %WithdrawFunds{account_id: "acc-1", amount: 30})
    end

    test "rejects insufficient funds" do
      state = open_account(balance: 20)

      assert {:error, :insufficient_funds} =
               Account.execute(state, %WithdrawFunds{account_id: "acc-1", amount: 50})
    end
  end

  describe "complete lifecycle" do
    test "open -> deposit -> withdraw -> close" do
      state = %Account{}

      # Open
      event = Account.execute(state, %OpenAccount{
        account_id: "acc-1", email: "t@t.com", name: "T", initial_balance: 0
      })
      state = Account.apply(state, event)

      # Deposit
      event = Account.execute(state, %DepositFunds{account_id: "acc-1", amount: 100})
      assert %FundsDeposited{new_balance: 100} = event
      state = Account.apply(state, event)

      # Withdraw all
      event = Account.execute(state, %WithdrawFunds{account_id: "acc-1", amount: 100})
      assert %FundsWithdrawn{new_balance: 0} = event
      state = Account.apply(state, event)

      # Close
      assert %AccountClosed{} = Account.execute(state, %CloseAccount{account_id: "acc-1"})
    end
  end

  defp open_account(opts \\ []) do
    %Account{
      account_id: Keyword.get(opts, :account_id, "acc-1"),
      email: "test@example.com",
      name: "Test",
      balance: Keyword.get(opts, :balance, 0),
      status: :open
    }
  end
end
```

---

## 9. Testing Process Managers

From Commanded's `process_manager_routing_test.exs` — test `interested?/1` routing and `handle/2` command emission.

```elixir
defmodule MyApp.ProcessManagers.OrderFulfillmentTest do
  use ExUnit.Case, async: true

  alias MyApp.ProcessManagers.OrderFulfillment
  alias MyApp.Events.{OrderPlaced, PaymentReceived, PaymentFailed, InventoryReserved}
  alias MyApp.Commands.{ProcessPayment, ReserveInventory, ShipOrder, CancelOrder}

  describe "interested?/1" do
    test "starts on OrderPlaced" do
      assert {:start, "order-1"} =
               OrderFulfillment.interested?(%OrderPlaced{order_id: "order-1"})
    end

    test "continues on PaymentReceived" do
      assert {:continue, "order-1"} =
               OrderFulfillment.interested?(%PaymentReceived{order_id: "order-1"})
    end

    test "ignores unrelated events" do
      assert false == OrderFulfillment.interested?(%{})
    end
  end

  describe "handle/2 — happy path" do
    test "OrderPlaced emits payment and inventory commands" do
      event = %OrderPlaced{order_id: "o-1", customer_id: "c-1", items: ["item"], total: 100}

      commands = OrderFulfillment.handle(%OrderFulfillment{}, event)

      assert [%ProcessPayment{order_id: "o-1"}, %ReserveInventory{order_id: "o-1"}] = commands
    end

    test "payment + inventory ready triggers shipping" do
      state = %OrderFulfillment{
        order_id: "o-1", items: ["item"], inventory_status: :reserved
      }

      assert %ShipOrder{order_id: "o-1"} =
               OrderFulfillment.handle(state, %PaymentReceived{order_id: "o-1"})
    end
  end

  describe "handle/2 — compensation" do
    test "payment failure cancels order" do
      state = %OrderFulfillment{order_id: "o-1", inventory_status: nil}

      assert %CancelOrder{reason: :payment_failed} =
               OrderFulfillment.handle(state, %PaymentFailed{order_id: "o-1"})
    end
  end

  describe "event ordering invariant" do
    test "same result regardless of payment/inventory order" do
      base = %OrderFulfillment{order_id: "o-1", items: ["item"]}

      # Payment first, then inventory
      s1 = OrderFulfillment.apply(base, %PaymentReceived{order_id: "o-1"})
      cmd1 = OrderFulfillment.handle(s1, %InventoryReserved{order_id: "o-1"})

      # Inventory first, then payment
      s2 = OrderFulfillment.apply(base, %InventoryReserved{order_id: "o-1"})
      cmd2 = OrderFulfillment.handle(s2, %PaymentReceived{order_id: "o-1"})

      assert %ShipOrder{} = cmd1
      assert %ShipOrder{} = cmd2
    end
  end
end
```

---

## 10. Integration Testing

From Commanded's `process_manager_integration_test.exs` — full dispatch through aggregate and verify projections.

```elixir
defmodule MyApp.AccountIntegrationTest do
  use MyApp.DataCase

  setup do
    start_supervised!(MyApp.CommandedApp)
    :ok
  end

  describe "account lifecycle" do
    test "creates account and updates projection" do
      account_id = UUID.uuid4()

      # Dispatch with strong consistency — waits for projections
      :ok = MyApp.CommandedApp.dispatch(
        %MyApp.Commands.OpenAccount{
          account_id: account_id,
          email: "test@example.com",
          name: "Test User",
          initial_balance: 0
        },
        consistency: :strong
      )

      # Verify projection
      account = MyApp.Accounts.get_account(account_id)
      assert account.email == "test@example.com"
      assert account.balance == 0

      # Deposit
      :ok = MyApp.CommandedApp.dispatch(
        %MyApp.Commands.DepositFunds{account_id: account_id, amount: 100},
        consistency: :strong
      )

      account = MyApp.Accounts.get_account(account_id)
      assert account.balance == 100
    end

    test "rejects invalid commands" do
      :ok = MyApp.CommandedApp.dispatch(%MyApp.Commands.OpenAccount{
        account_id: "acc-1", email: "t@t.com", name: "T", initial_balance: 50
      })

      assert {:error, :insufficient_funds} =
               MyApp.CommandedApp.dispatch(%MyApp.Commands.WithdrawFunds{
                 account_id: "acc-1", amount: 100
               })
    end
  end
end
```

---

## 11. Event Upcasting

From Commanded's `upcaster_test.exs` — transform old event schemas during deserialization.

```elixir
# Event versions
defmodule MyApp.Events.AccountOpened do
  @derive Inspect
  defstruct [:account_id, :email, :name]
end

defmodule MyApp.Events.AccountOpened.V2 do
  @derive Inspect
  defstruct [:account_id, :email, :name, :initial_balance, :subscription_tier]
end

# Upcaster — transforms V1 events to V2 on read
defmodule MyApp.EventUpcaster do
  @behaviour Commanded.Event.Upcaster

  def upcast(%{"event_type" => "Elixir.MyApp.Events.AccountOpened"} = event, _metadata) do
    data =
      event["data"]
      |> Map.put_new("initial_balance", 0)
      |> Map.put_new("subscription_tier", "free")

    %{event |
      "event_type" => "Elixir.MyApp.Events.AccountOpened.V2",
      "data" => data
    }
  end

  def upcast(event, _metadata), do: event
end

# Aggregate handles both versions during rehydration
defmodule MyApp.Aggregates.Account do
  # V1 events (legacy)
  def apply(%__MODULE__{} = acct, %MyApp.Events.AccountOpened{} = e) do
    %__MODULE__{acct |
      account_id: e.account_id, email: e.email, name: e.name,
      balance: 0, subscription_tier: "free", status: :open
    }
  end

  # V2 events (current)
  def apply(%__MODULE__{} = acct, %MyApp.Events.AccountOpened.V2{} = e) do
    %__MODULE__{acct |
      account_id: e.account_id, email: e.email, name: e.name,
      balance: e.initial_balance, subscription_tier: e.subscription_tier, status: :open
    }
  end
end

# Test upcasting
defmodule MyApp.EventUpcasterTest do
  use ExUnit.Case, async: true

  test "upcasts V1 AccountOpened to V2" do
    v1 = %{
      "event_type" => "Elixir.MyApp.Events.AccountOpened",
      "data" => %{"account_id" => "1", "email" => "t@t.com", "name" => "T"}
    }

    result = MyApp.EventUpcaster.upcast(v1, %{})

    assert result["event_type"] == "Elixir.MyApp.Events.AccountOpened.V2"
    assert result["data"]["initial_balance"] == 0
    assert result["data"]["subscription_tier"] == "free"
  end

  test "passes through unknown events unchanged" do
    event = %{"event_type" => "Elixir.SomeOther", "data" => %{}}
    assert ^event = MyApp.EventUpcaster.upcast(event, %{})
  end
end
```

---

## 12. GDPR Crypto-Shredding

```elixir
# Events store encrypted PII with a key reference
defmodule MyApp.Events.UserRegistered do
  @derive Inspect
  defstruct [:user_id, :pii_key_id, :encrypted_email, :encrypted_name, :role]
end

# Encryption module
defmodule MyApp.Crypto do
  @aad "myapp_pii_v1"

  def encrypt(plaintext, key) do
    iv = :crypto.strong_rand_bytes(12)
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, @aad, true)
    iv <> tag <> ciphertext
  end

  def decrypt(<<iv::binary-12, tag::binary-16, ciphertext::binary>>, key) do
    :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, @aad, tag, false)
  end
end

# To "forget" a user: delete their encryption key
# The event remains but PII becomes permanently unreadable
defmodule MyApp.GDPR do
  def forget_user(user_id) do
    MyApp.Repo.delete_all(
      from(k in MyApp.EncryptionKey, where: k.user_id == ^user_id)
    )
  end
end
```

---

## 13. Projection Rebuilding

```elixir
defmodule MyApp.ProjectionManager do
  alias MyApp.Repo
  alias MyApp.Projections.AccountSummary

  def rebuild_account_summaries do
    # 1. Clear existing projection data
    Repo.delete_all(AccountSummary)

    # 2. Reset projector subscription to replay from origin
    Commanded.reset(MyApp.CommandedApp, MyApp.Projectors.AccountSummary)

    :ok
  end
end

# Idempotent projection — safe for replays
project(%AccountOpened{} = e, _metadata, fn multi ->
  Ecto.Multi.insert(multi, :account, %AccountSummary{
    account_id: e.account_id,
    email: e.email,
    balance: e.initial_balance,
    status: :open
  },
    on_conflict: :nothing,      # Skip if already exists
    conflict_target: :account_id
  )
end)
```

---

## Related Files

- **[eventsourcing-reference.md](eventsourcing-reference.md)** — Rules, Commanded API tables, router DSL, dispatch options, Aggregate.Multi, Phoenix integration, middleware, snapshotting, upcasting, troubleshooting
- **[SKILL.md](SKILL.md)** — Core Elixir skill with Event Sourcing & CQRS overview and "When to Use" decision guide
- **[ecto-reference.md](ecto-reference.md)** — Ecto schemas, changesets, queries, Multi — used in projections and command validation
- **[testing-reference.md](testing-reference.md)** — ExUnit patterns, Mox, process testing — applies to aggregate and process manager tests
