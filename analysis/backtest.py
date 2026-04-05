"""
analysis/backtest.py
Simulates a trading strategy based on signal_summary.sql consensus signals.
Computes P&L, Sharpe ratio, max drawdown, and win rate vs buy-and-hold.
"""

import duckdb
import pandas as pd
import numpy as np

DB_PATH  = "trading.duckdb"
SQL_PATH = "queries/signal_summary.sql"

# ── Configuration ─────────────────────────────────────────────────────────────
INITIAL_CAPITAL = 10_000        # USD per ticker
TICKERS         = ["AAPL", "MSFT", "NVDA"]
# ─────────────────────────────────────────────────────────────────────────────


def load_signals(db_path: str, sql_path: str) -> pd.DataFrame:
    con = duckdb.connect(db_path)
    sql = open(sql_path).read()
    df  = con.execute(sql).df()
    con.close()
    df["date"] = pd.to_datetime(df["date"])
    return df


def backtest_ticker(df: pd.DataFrame, ticker: str, capital: float) -> dict:
    """
    Simple long-only strategy:
      - STRONG BUY  → buy (go long)
      - STRONG SELL → sell (exit position)
    Returns a dict of performance metrics + daily equity series.
    """
    prices = df[df["ticker"] == ticker].sort_values("date").reset_index(drop=True)

    cash        = capital
    shares      = 0.0
    in_position = False
    trades      = []
    equity      = []

    for _, row in prices.iterrows():
        price     = row["close"]
        consensus = row["consensus"]

        if consensus == "STRONG BUY" and not in_position:
            shares      = cash / price
            cash        = 0.0
            in_position = True
            entry_price = price
            entry_date  = row["date"]

        elif consensus == "STRONG SELL" and in_position:
            cash        = shares * price
            pnl         = cash - capital
            trades.append({
                "entry_date":  entry_date,
                "exit_date":   row["date"],
                "entry_price": entry_price,
                "exit_price":  price,
                "pnl":         pnl,
                "return_pct":  (price - entry_price) / entry_price * 100
            })
            shares      = 0.0
            in_position = False

        # Mark-to-market equity
        equity.append({
            "date":   row["date"],
            "equity": cash + shares * price
        })

    # Close open position at last price
    if in_position:
        last_price = prices.iloc[-1]["close"]
        cash       = shares * last_price

    equity_df = pd.DataFrame(equity).set_index("date")
    trades_df = pd.DataFrame(trades)

    # ── Metrics ──────────────────────────────────────────────────────────────
    final_value   = cash
    total_return  = (final_value - capital) / capital * 100

    daily_returns = equity_df["equity"].pct_change().dropna()
    sharpe        = (daily_returns.mean() / daily_returns.std()
                     * np.sqrt(252)) if daily_returns.std() > 0 else 0

    rolling_max   = equity_df["equity"].cummax()
    drawdown      = (equity_df["equity"] - rolling_max) / rolling_max
    max_drawdown  = drawdown.min() * 100

    win_rate = (
        (trades_df["pnl"] > 0).mean() * 100
        if not trades_df.empty else 0
    )

    # ── Buy-and-hold benchmark ────────────────────────────────────────────────
    bh_shares      = capital / prices.iloc[0]["close"]
    bh_final       = bh_shares * prices.iloc[-1]["close"]
    bh_return      = (bh_final - capital) / capital * 100

    return {
        "ticker":        ticker,
        "total_return":  round(total_return, 2),
        "bh_return":     round(bh_return, 2),
        "sharpe":        round(sharpe, 3),
        "max_drawdown":  round(max_drawdown, 2),
        "win_rate":      round(win_rate, 2),
        "num_trades":    len(trades_df),
        "equity_df":     equity_df,
        "trades_df":     trades_df,
    }


def run_backtest():
    print(f"Loading signals from {SQL_PATH}...")
    signals = load_signals(DB_PATH, SQL_PATH)

    results = []
    for ticker in TICKERS:
        r = backtest_ticker(signals, ticker, INITIAL_CAPITAL)
        results.append(r)
        print(f"\n{'─'*40}")
        print(f"  {ticker}")
        print(f"{'─'*40}")
        print(f"  Strategy return : {r['total_return']:>8.2f}%")
        print(f"  Buy-and-hold    : {r['bh_return']:>8.2f}%")
        print(f"  Sharpe ratio    : {r['sharpe']:>8.3f}")
        print(f"  Max drawdown    : {r['max_drawdown']:>8.2f}%")
        print(f"  Win rate        : {r['win_rate']:>8.2f}%")
        print(f"  Trades executed : {r['num_trades']:>8}")

    return results


if __name__ == "__main__":
    results = run_backtest()

