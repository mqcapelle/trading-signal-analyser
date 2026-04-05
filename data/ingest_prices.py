"""
data/ingest_prices.py
Fetches historical OHLCV data via yfinance and stores it in trading.duckdb.
"""

import duckdb
import yfinance as yf
import pandas as pd

# ── Configuration ────────────────────────────────────────────────────────────
TICKERS     = ["AAPL", "MSFT", "NVDA"]
START_DATE  = "2020-01-01"
END_DATE    = "2024-12-31"
DB_PATH     = "trading.duckdb"
# ─────────────────────────────────────────────────────────────────────────────


def fetch_ohlcv(ticker: str, start: str, end: str) -> pd.DataFrame:
    """Download OHLCV data for one ticker and return a clean DataFrame."""
    print(f"  Fetching {ticker}...")
    raw = yf.download(ticker, start=start, end=end, auto_adjust=True, progress=False)

    if raw.empty:
        raise ValueError(f"No data returned for {ticker}")

    # Flatten MultiIndex columns if present
    if isinstance(raw.columns, pd.MultiIndex):
        raw.columns = raw.columns.get_level_values(0)

    df = raw[["Open", "High", "Low", "Close", "Volume"]].copy()
    df.columns = ["open", "high", "low", "close", "volume"]
    df.index.name = "date"
    df = df.reset_index()
    df["ticker"] = ticker
    df["date"] = pd.to_datetime(df["date"]).dt.date
    return df


def ingest(tickers: list[str], start: str, end: str, db_path: str) -> None:
    """Fetch all tickers and write to DuckDB."""
    frames = []
    print("Downloading price data...")
    for ticker in tickers:
        frames.append(fetch_ohlcv(ticker, start, end))

    prices = pd.concat(frames, ignore_index=True)

    print(f"\nWriting {len(prices):,} rows to {db_path}...")
    con = duckdb.connect(db_path)
    con.register("prices_df", prices)
    con.execute("DROP TABLE IF EXISTS prices")
    con.execute("""
        CREATE TABLE prices AS
        SELECT
            date::DATE       AS date,
            ticker::VARCHAR  AS ticker,
            open::DOUBLE     AS open,
            high::DOUBLE     AS high,
            low::DOUBLE      AS low,
            close::DOUBLE    AS close,
            volume::BIGINT   AS volume
        FROM prices_df
    """)
    
    # Verify
    count = con.execute("SELECT COUNT(*) FROM prices").fetchone()[0]
    print(f"✅ Ingested {count:,} rows across {len(tickers)} tickers.")

    sample = con.execute("""
        SELECT ticker, MIN(date) AS first_date, MAX(date) AS last_date, COUNT(*) AS rows
        FROM prices
        GROUP BY ticker
        ORDER BY ticker
    """).df()
    print("\nSummary:")
    print(sample.to_string(index=False))
    con.close()


if __name__ == "__main__":
    ingest(TICKERS, START_DATE, END_DATE, DB_PATH)

