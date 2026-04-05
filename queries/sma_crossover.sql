-- queries/sma_crossover.sql
-- Computes 20/50-day SMA crossover buy/sell signals.
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

crossover AS (
    SELECT
        date,
        ticker,
        close,
        sma_20,
        sma_50,
        LAG(sma_20) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_20,
        LAG(sma_50) OVER (PARTITION BY ticker ORDER BY date) AS prev_sma_50
    FROM sma
)

SELECT
    date,
    ticker,
    close,
    ROUND(sma_20, 4) AS sma_20,
    ROUND(sma_50, 4) AS sma_50,
    CASE
        WHEN prev_sma_20 <  prev_sma_50 AND sma_20 >= sma_50 THEN 'BUY'
        WHEN prev_sma_20 >  prev_sma_50 AND sma_20 <= sma_50 THEN 'SELL'
        ELSE NULL
    END AS signal
FROM crossover
WHERE sma_50 IS NOT NULL   -- exclude warm-up period (first 49 rows per ticker)
ORDER BY ticker, date;