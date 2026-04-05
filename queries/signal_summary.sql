-- queries/signal_summary.sql
-- Combines SMA crossover, RSI, and Bollinger Band signals into a unified
-- signal score. +1 per BUY indicator, -1 per SELL indicator.
-- Score >= 2 → strong BUY, Score <= -2 → strong SELL.
-- Requires: prices table in trading.duckdb

WITH sma AS (
    SELECT
        date,
        ticker,
        close,
        AVG(close) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 49 PRECEDING AND CURRENT ROW
        ) AS sma_50,
        AVG(close) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS sma_20
    FROM prices
),

sma_lagged AS (
    SELECT
        date,
        ticker,
        close,
        sma_20,
        sma_50,
        LAG(sma_20) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_20,
        LAG(sma_50) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_50
    FROM sma
    WHERE sma_50 IS NOT NULL
),

sma_signals AS (
    SELECT
        date,
        ticker,
        close,
        sma_20,
        sma_50,
        CASE
            WHEN prev_sma_20 <  prev_sma_50 AND sma_20 >= sma_50 THEN 'BUY'
            WHEN prev_sma_20 >  prev_sma_50 AND sma_20 <= sma_50 THEN 'SELL'
            ELSE NULL
        END AS sma_signal
    FROM sma_lagged
),

rsi_base AS (
    SELECT
        date,
        ticker,
        close - LAG(close) OVER (PARTITION BY ticker ORDER BY date) AS change
    FROM prices
),

rsi_gains AS (
    SELECT
        date,
        ticker,
        CASE WHEN change > 0 THEN change ELSE 0 END AS gain,
        CASE WHEN change < 0 THEN ABS(change) ELSE 0 END AS loss
    FROM rsi_base
    WHERE change IS NOT NULL
),

rsi_avg AS (
    SELECT
        date,
        ticker,
        AVG(gain) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_gain,
        AVG(loss) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_loss
    FROM rsi_gains
),

rsi_signals AS (
    SELECT
        date,
        ticker,
        CASE
            WHEN avg_loss = 0 THEN 100
            ELSE 100 - (100 / (1 + avg_gain / avg_loss))
        END AS rsi,
        CASE
            WHEN avg_loss = 0                                      THEN 'BUY'
            WHEN (100 - (100 / (1 + avg_gain / avg_loss))) < 30   THEN 'BUY'
            WHEN (100 - (100 / (1 + avg_gain / avg_loss))) > 70   THEN 'SELL'
            ELSE NULL
        END AS rsi_signal
    FROM rsi_avg
),

bb_base AS (
    SELECT
        date,
        ticker,
        close,
        AVG(close) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS sma_20,
        STDDEV_SAMP(close) OVER (
            PARTITION BY ticker ORDER BY date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS stddev_20
    FROM prices
),

bb_signals AS (
    SELECT
        date,
        ticker,
        close,
        sma_20 + (2 * stddev_20) AS upper_band,
        sma_20 - (2 * stddev_20) AS lower_band,
        CASE
            WHEN close <= sma_20 - (2 * stddev_20) THEN 'BUY'
            WHEN close >= sma_20 + (2 * stddev_20) THEN 'SELL'
            ELSE NULL
        END AS bb_signal
    FROM bb_base
    WHERE stddev_20 IS NOT NULL
),

combined AS (
    SELECT
        s.date,
        s.ticker,
        s.close,
        s.sma_signal,
        r.rsi_signal,
        r.rsi,
        b.bb_signal,
        -- Score: +1 per BUY, -1 per SELL, 0 for NULL
        (CASE WHEN s.sma_signal = 'BUY'  THEN 1
              WHEN s.sma_signal = 'SELL' THEN -1 ELSE 0 END +
         CASE WHEN r.rsi_signal = 'BUY'  THEN 1
              WHEN r.rsi_signal = 'SELL' THEN -1 ELSE 0 END +
         CASE WHEN b.bb_signal  = 'BUY'  THEN 1
              WHEN b.bb_signal  = 'SELL' THEN -1 ELSE 0 END
        ) AS signal_score
    FROM sma_signals s
    JOIN rsi_signals r ON s.date = r.date AND s.ticker = r.ticker
    JOIN bb_signals  b ON s.date = b.date AND s.ticker = b.ticker
)

SELECT
    date,
    ticker,
    close,
    ROUND(rsi, 2)   AS rsi,
    sma_signal,
    rsi_signal,
    bb_signal,
    signal_score,
    CASE
        WHEN signal_score >=  2 THEN 'STRONG BUY'
        WHEN signal_score =   1 THEN 'WEAK BUY'
        WHEN signal_score =  -1 THEN 'WEAK SELL'
        WHEN signal_score <= -2 THEN 'STRONG SELL'
        ELSE 'NEUTRAL'
    END AS consensus
FROM combined
ORDER BY ticker, date;