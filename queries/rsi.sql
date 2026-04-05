-- queries/rsi.sql
-- Computes 14-day Relative Strength Index (RSI) and generates signals.
-- Requires: prices table in trading.duckdb

WITH daily_changes AS (
    SELECT
        date,
        ticker,
        close,
        close - LAG(close) OVER (PARTITION BY ticker ORDER BY date) AS change
    FROM prices
),

gains_losses AS (
    SELECT
        date,
        ticker,
        close,
        CASE WHEN change > 0 THEN change ELSE 0 END AS gain,
        CASE WHEN change < 0 THEN ABS(change) ELSE 0 END AS loss
    FROM daily_changes
    WHERE change IS NOT NULL
),

avg_gain_loss AS (
    SELECT
        date,
        ticker,
        close,
        AVG(gain) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_gain,
        AVG(loss) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 13 PRECEDING AND CURRENT ROW
        ) AS avg_loss
    FROM gains_losses
),

rsi_calc AS (
    SELECT
        date,
        ticker,
        close,
        avg_gain,
        avg_loss,
        CASE
            WHEN avg_loss = 0 THEN 100
            ELSE 100 - (100 / (1 + avg_gain / avg_loss))
        END AS rsi
    FROM avg_gain_loss
)

SELECT
    date,
    ticker,
    close,
    ROUND(rsi, 2) AS rsi,
    CASE
        WHEN rsi < 30 THEN 'BUY'
        WHEN rsi > 70 THEN 'SELL'
        ELSE NULL
    END AS signal
FROM rsi_calc
WHERE avg_gain IS NOT NULL
ORDER BY ticker, date;