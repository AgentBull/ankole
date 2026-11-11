"""Exercise the Bull Backtesting service and its real ClickHouse adapter."""

from decimal import Decimal
from pathlib import Path

from bull_backtesting.api.app import create_service
from bull_backtesting.core.trade_backtest.models import BacktestRequest


request = BacktestRequest.model_validate(
    {
        "initial_cash": "100000",
        "predict_to": "2024-01-04",
        "trades": [
            {
                "symbol": "000001.SZ",
                "trade_time": "2024-01-02T10:00:00",
                "volume": 1000,
                "price": "10.00",
                "side": "buy",
                "order_type": "market",
            },
            {
                "symbol": "000001.SZ",
                "trade_time": "2024-01-03T10:00:00",
                "volume": 1000,
                "price": "10.50",
                "side": "sell",
                "order_type": "market",
            },
        ],
    }
)
result = create_service().run(request, use_cache=False)

assert [trade.filled_time.date().isoformat() for trade in result.executions] == [
    "2024-01-03",
    "2024-01-04",
]
assert [trade.filled_price for trade in result.executions] == [
    Decimal("10.50"),
    Decimal("11.00"),
]
assert [trade.filled_volume for trade in result.executions] == [1000, 1000]
assert result.equity_curve[-1].equity == Decimal("100477.40")
assert result.metrics.cumulative_return > 0

Path("backtest-result.json").write_text(
    result.model_dump_json(indent=2) + "\n", encoding="utf-8"
)
print("BULL_BACKTEST_OK 2 fills, equity 100477.40")
