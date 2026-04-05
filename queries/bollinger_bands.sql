-- queries/bollinger_bands.sql
-- Computes Bollinger Bands (20-day SMA ± 2 std devs) and generates signals.
-- Requires: prices table in trading.duckdb

WITH bands AS (
    SELECT
        date,
        ticker,
        close,
        AVG(close) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS sma_20,
        STDDEV_SAMP(close) OVER (
            PARTITION BY ticker
            ORDER BY date
            ROWS BETWEEN 19 PRECEDING AND CURRENT ROW
        ) AS stddev_20
    FROM prices
),

bollinger AS (
    SELECT
        date,
        ticker,
        close,
        sma_20,
        stddev_20,
        sma_20 + (2 * stddev_20) AS upper_band,
        sma_20 - (2 * stddev_20) AS lower_band
    FROM bands
    WHERE stddev_20 IS NOT NULL
)

SELECT
    date,
    ticker,
    close,
    ROUND(sma_20,     4) AS sma_20,
    ROUND(upper_band, 4) AS upper_band,
    ROUND(lower_band, 4) AS lower_band,
    ROUND((close - lower_band) / NULLIF(upper_band - lower_band, 0), 4) AS pct_b,
    CASE
        WHEN close <= lower_band THEN 'BUY'
        WHEN close >= upper_band THEN 'SELL'
        ELSE NULL
    END AS signal
FROM bollinger
ORDER BY ticker, date;