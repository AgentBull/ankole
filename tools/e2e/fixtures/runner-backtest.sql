-- Synthetic daily bars for the Bull Backtesting integration.
CREATE DATABASE datahub;
CREATE DATABASE market_quotes;

CREATE TABLE datahub.mv_instruments
(
    symbol String,
    sw_industry_code String,
    active_at DateTime,
    sub_market String,
    `name_abbr_zh-hans` String
)
ENGINE = Memory;

INSERT INTO datahub.mv_instruments VALUES
    ('000001.SZ', '801780', '2024-01-01 00:00:00', 'cn:main_board', '验收标的');

CREATE TABLE market_quotes.vw_history_daily_bars_with_indicators
(
    symbol String,
    trade_date Date32,
    open Float64,
    high Float64,
    low Float64,
    close Float64,
    open_raw Float64,
    high_raw Float64,
    low_raw Float64,
    close_raw Float64,
    volume UInt64,
    amount Float64 DEFAULT 0,
    turnover_rate Float64 DEFAULT 0,
    volume_ratio Float64 DEFAULT 0,
    pb Float64 DEFAULT 0,
    pe_ttm Float64 DEFAULT 0,
    ps_ttm Float64 DEFAULT 0,
    dv_ttm Float64 DEFAULT 0,
    free_mv Float64 DEFAULT 0
)
ENGINE = Memory;

INSERT INTO market_quotes.vw_history_daily_bars_with_indicators
    (symbol, trade_date, open, high, low, close, open_raw, high_raw, low_raw, close_raw, volume)
VALUES
    ('000001.SZ', '2024-01-02', 10.0, 10.5, 9.9, 10.2, 10.0, 10.5, 9.9, 10.2, 1000000),
    ('000001.SZ', '2024-01-03', 10.5, 10.8, 10.0, 10.7, 10.5, 10.8, 10.0, 10.7, 1000000),
    ('000001.SZ', '2024-01-04', 11.0, 11.2, 10.9, 11.1, 11.0, 11.2, 10.9, 11.1, 1000000);
