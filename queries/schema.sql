-- queries/schema.sql
-- Defines persistent DuckDB views for each indicator layer.
-- Run once after ingest_prices.py to register all views in trading.duckdb.
-- Views are then referenced directly in backtest.py and plot_dashboard.py.

-- ── Layer 1: Raw price changes ────────────────────────────────────────────────

CREATE OR REPLACE VIEW v_price_changes AS
SELECT
    date,
    ticker,
    open,
    high,
    low,
    close,
    volume,
    close - LAG(close) OVER (PARTITION BY ticker ORDER BY date) AS daily_change,
    (close - LAG(close) OVER (PARTITION BY ticker ORDER BY date))
        / NULLIF(LAG(close) OVER (PARTITION BY ticker ORDER BY date), 0)
        * 100                                                          AS daily_return_pct
FROM prices;


-- ── Layer 2: Moving averages ──────────────────────────────────────────────────

CREATE OR REPLACE VIEW v_moving_averages AS
SELECT
    date,
    ticker,
    close,
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 9  PRECEDING AND CURRENT ROW
    ) AS sma_10,
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
    ) AS sma_20,
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 49 PRECEDING AND CURRENT ROW
    ) AS sma_50,
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 199 PRECEDING AND CURRENT ROW
    ) AS sma_200,
    -- Exponential approximation via cumulative weighted mean
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
    ) AS ema_12_approx,
    AVG(close) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 25 PRECEDING AND CURRENT ROW
    ) AS ema_26_approx
FROM prices;


-- ── Layer 3: Volatility (Bollinger Bands + ATR) ───────────────────────────────

CREATE OR REPLACE VIEW v_volatility AS
WITH true_range AS (
    SELECT
        p.date,
        p.ticker,
        p.close,
        p.high,
        p.low,
        m.sma_20,
        STDDEV_SAMP(p.close) OVER (
            PARTITION BY p.ticker ORDER BY p.date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS stddev_20,
        GREATEST(
            p.high - p.low,
            ABS(p.high - LAG(p.close) OVER (PARTITION BY p.ticker ORDER BY p.date)),
            ABS(p.low  - LAG(p.close) OVER (PARTITION BY p.ticker ORDER BY p.date))
        ) AS tr
    FROM prices p
    JOIN v_moving_averages m
      ON p.date = m.date AND p.ticker = m.ticker
)
SELECT
    date,
    ticker,
    close,
    high,
    low,
    sma_20,
    stddev_20,
    sma_20 + 2 * stddev_20                    AS bb_upper,
    sma_20 - 2 * stddev_20                    AS bb_lower,
    (4 * stddev_20) / NULLIF(sma_20, 0)       AS bb_bandwidth,
    AVG(tr) OVER (
        PARTITION BY ticker ORDER BY date
        ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
    )                                         AS atr_14
FROM true_range;

-- ── Layer 4: Momentum (RSI + MACD approximation) ─────────────────────────────

CREATE OR REPLACE VIEW v_momentum AS
WITH changes AS (
    SELECT
        date,
        ticker,
        close,
        daily_change,
        CASE WHEN daily_change > 0 THEN daily_change ELSE 0 END AS gain,
        CASE WHEN daily_change < 0 THEN ABS(daily_change) ELSE 0 END AS loss
    FROM v_price_changes
    WHERE daily_change IS NOT NULL
),
rsi_avg AS (
    SELECT
        date,
        ticker,
        close,
        AVG(gain) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_gain_14,
        AVG(loss) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_loss_14
    FROM changes
)
SELECT
    r.date,
    r.ticker,
    r.close,
    -- RSI
    CASE
        WHEN avg_loss_14 = 0 THEN 100
        ELSE 100 - (100 / (1 + avg_gain_14 / avg_loss_14))
    END                                         AS rsi_14,
    -- MACD approximation (EMA12 - EMA26)
    m.ema_12_approx - m.ema_26_approx           AS macd_approx,
    -- MACD signal line (9-day SMA of MACD)
    AVG(m.ema_12_approx - m.ema_26_approx) OVER (
        PARTITION BY r.ticker ORDER BY r.date
        ROWS BETWEEN 8 PRECEDING AND CURRENT ROW
    )                                           AS macd_signal_approx
FROM rsi_avg r
JOIN v_moving_averages m
  ON r.date = m.date AND r.ticker = m.ticker;


-- ── Layer 5: Unified signal scoring ──────────────────────────────────────────

CREATE OR REPLACE VIEW v_signals AS
WITH sma_lagged AS (
    SELECT
        date,
        ticker,
        close,
        sma_20,
        sma_50,
        LAG(sma_20) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_20,
        LAG(sma_50) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_50
    FROM v_moving_averages
    WHERE sma_50 IS NOT NULL
),
scored AS (
    SELECT
        s.date,
        s.ticker,
        s.close,
        -- SMA crossover signal
        CASE
            WHEN s.prev_sma_20 < s.prev_sma_50 AND s.sma_20 >= s.sma_50 THEN 'BUY'
            WHEN s.prev_sma_20 > s.prev_sma_50 AND s.sma_20 <= s.sma_50 THEN 'SELL'
            ELSE NULL
        END AS sma_signal,
        -- RSI signal
        CASE
            WHEN m.rsi_14 < 30 THEN 'BUY'
            WHEN m.rsi_14 > 70 THEN 'SELL'
            ELSE NULL
        END AS rsi_signal,
        -- Bollinger Band signal
        CASE
            WHEN s.close <= v.bb_lower THEN 'BUY'
            WHEN s.close >= v.bb_upper THEN 'SELL'
            ELSE NULL
        END AS bb_signal,
        -- MACD signal
        CASE
            WHEN m.macd_approx > m.macd_signal_approx
             AND LAG(m.macd_approx) OVER (PARTITION BY s.ticker ORDER BY s.date)
              <= LAG(m.macd_signal_approx) OVER (PARTITION BY s.ticker ORDER BY s.date)
            THEN 'BUY'
            WHEN m.macd_approx < m.macd_signal_approx
             AND LAG(m.macd_approx) OVER (PARTITION BY s.ticker ORDER BY s.date)
              >= LAG(m.macd_signal_approx) OVER (PARTITION BY s.ticker ORDER BY s.date)
            THEN 'SELL'
            ELSE NULL
        END AS macd_signal,
        ROUND(m.rsi_14, 2)       AS rsi,
        ROUND(v.bb_upper, 4)     AS bb_upper,
        ROUND(v.bb_lower, 4)     AS bb_lower,
        ROUND(m.macd_approx, 4)  AS macd
    FROM sma_lagged s
    JOIN v_momentum  m ON s.date = m.date AND s.ticker = m.ticker
    JOIN v_volatility v ON s.date = v.date AND s.ticker = v.ticker
)
SELECT
    date,
    ticker,
    close,
    rsi,
    bb_upper,
    bb_lower,
    macd,
    sma_signal,
    rsi_signal,
    bb_signal,
    macd_signal,
    -- Score across 4 indicators now
    (CASE WHEN sma_signal  = 'BUY'  THEN 1
          WHEN sma_signal  = 'SELL' THEN -1 ELSE 0 END +
     CASE WHEN rsi_signal  = 'BUY'  THEN 1
          WHEN rsi_signal  = 'SELL' THEN -1 ELSE 0 END +
     CASE WHEN bb_signal   = 'BUY'  THEN 1
          WHEN bb_signal   = 'SELL' THEN -1 ELSE 0 END +
     CASE WHEN macd_signal = 'BUY'  THEN 1
          WHEN macd_signal = 'SELL' THEN -1 ELSE 0 END
    ) AS signal_score,
    CASE
        WHEN (CASE WHEN sma_signal  = 'BUY'  THEN 1
                   WHEN sma_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN rsi_signal  = 'BUY'  THEN 1
                   WHEN rsi_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN bb_signal   = 'BUY'  THEN 1
                   WHEN bb_signal   = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN macd_signal = 'BUY'  THEN 1
                   WHEN macd_signal = 'SELL' THEN -1 ELSE 0 END
             ) >=  3 THEN 'STRONG BUY'
        WHEN (CASE WHEN sma_signal  = 'BUY'  THEN 1
                   WHEN sma_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN rsi_signal  = 'BUY'  THEN 1
                   WHEN rsi_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN bb_signal   = 'BUY'  THEN 1
                   WHEN bb_signal   = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN macd_signal = 'BUY'  THEN 1
                   WHEN macd_signal = 'SELL' THEN -1 ELSE 0 END
             ) =   2 THEN 'WEAK BUY'
        WHEN (CASE WHEN sma_signal  = 'BUY'  THEN 1
                   WHEN sma_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN rsi_signal  = 'BUY'  THEN 1
                   WHEN rsi_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN bb_signal   = 'BUY'  THEN 1
                   WHEN bb_signal   = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN macd_signal = 'BUY'  THEN 1
                   WHEN macd_signal = 'SELL' THEN -1 ELSE 0 END
             ) =  -2 THEN 'WEAK SELL'
        WHEN (CASE WHEN sma_signal  = 'BUY'  THEN 1
                   WHEN sma_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN rsi_signal  = 'BUY'  THEN 1
                   WHEN rsi_signal  = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN bb_signal   = 'BUY'  THEN 1
                   WHEN bb_signal   = 'SELL' THEN -1 ELSE 0 END +
              CASE WHEN macd_signal = 'BUY'  THEN 1
                   WHEN macd_signal = 'SELL' THEN -1 ELSE 0 END
             ) <= -3 THEN 'STRONG SELL'
        ELSE 'NEUTRAL'
    END AS consensus
FROM scored
ORDER BY ticker, date;