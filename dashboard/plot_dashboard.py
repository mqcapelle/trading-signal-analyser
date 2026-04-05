"""
dashboard/plot_dashboard.py
Renders a 4-panel Matplotlib dashboard per ticker:
  1. Price + SMA 20/50 + buy/sell signal markers
  2. RSI with overbought/oversold bands
  3. Bollinger Bands
  4. Strategy equity curve vs buy-and-hold
"""

import duckdb
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.gridspec as gridspec
from analysis.backtest import load_signals, backtest_ticker

DB_PATH        = "trading.duckdb"
SQL_PATH       = "queries/signal_summary.sql"
INITIAL_CAPITAL = 10_000
TICKERS        = ["AAPL", "MSFT", "NVDA"]

# ── Colour palette ────────────────────────────────────────────────────────────
C_PRICE  = "#1f77b4"
C_SMA20  = "#ff7f0e"
C_SMA50  = "#9467bd"
C_BB     = "#17becf"
C_BUY    = "#2ca02c"
C_SELL   = "#d62728"
C_EQUITY = "#1f77b4"
C_BH     = "#aec7e8"
# ─────────────────────────────────────────────────────────────────────────────


def load_prices(db_path: str) -> pd.DataFrame:
    con = duckdb.connect(db_path)
    df  = con.execute("SELECT * FROM prices ORDER BY ticker, date").df()
    con.close()
    df["date"] = pd.to_datetime(df["date"])
    return df


def plot_ticker(ticker: str, prices: pd.DataFrame,
                signals: pd.DataFrame, result: dict):

    p = prices[prices["ticker"] == ticker].sort_values("date").reset_index(drop=True)
    s = signals[signals["ticker"] == ticker].sort_values("date").reset_index(drop=True)

    # ── Compute bands for plot ────────────────────────────────────────────────
    p["sma_20"]     = p["close"].rolling(20).mean()
    p["sma_50"]     = p["close"].rolling(50).mean()
    p["bb_upper"]   = p["sma_20"] + 2 * p["close"].rolling(20).std()
    p["bb_lower"]   = p["sma_20"] - 2 * p["close"].rolling(20).std()

    buy_rows  = s[s["consensus"] == "STRONG BUY"]
    sell_rows = s[s["consensus"] == "STRONG SELL"]

    # ── Buy-and-hold equity ───────────────────────────────────────────────────
    bh_shares = INITIAL_CAPITAL / p.iloc[0]["close"]
    p["bh_equity"] = bh_shares * p["close"]

    equity_df = result["equity_df"].reset_index()

    fig = plt.figure(figsize=(16, 12))
    fig.suptitle(f"{ticker} — Trading Signal Dashboard", fontsize=15, fontweight="bold")
    gs  = gridspec.GridSpec(4, 1, hspace=0.45)

    # ── Panel 1: Price + SMAs + signals ──────────────────────────────────────
    ax1 = fig.add_subplot(gs[0])
    ax1.plot(p["date"], p["close"],  color=C_PRICE, lw=1.2, label="Close")
    ax1.plot(p["date"], p["sma_20"], color=C_SMA20, lw=1,   label="SMA 20", linestyle="--")
    ax1.plot(p["date"], p["sma_50"], color=C_SMA50, lw=1,   label="SMA 50", linestyle="--")
    ax1.scatter(buy_rows["date"],  buy_rows["close"],
                marker="^", color=C_BUY,  s=80, zorder=5, label="Strong Buy")
    ax1.scatter(sell_rows["date"], sell_rows["close"],
                marker="v", color=C_SELL, s=80, zorder=5, label="Strong Sell")
    ax1.set_title("Price + SMA Crossover + Consensus Signals")
    ax1.legend(fontsize=7, ncol=5)
    ax1.set_ylabel("Price (USD)")

    # ── Panel 2: RSI ──────────────────────────────────────────────────────────
    ax2 = fig.add_subplot(gs[1], sharex=ax1)
    ax2.plot(s["date"], s["rsi"], color=C_PRICE, lw=1)
    ax2.axhline(70, color=C_SELL, linestyle="--", lw=0.8, label="Overbought (70)")
    ax2.axhline(30, color=C_BUY,  linestyle="--", lw=0.8, label="Oversold (30)")
    ax2.fill_between(s["date"], 70, s["rsi"],
                     where=s["rsi"] >= 70, alpha=0.15, color=C_SELL)
    ax2.fill_between(s["date"], 30, s["rsi"],
                     where=s["rsi"] <= 30, alpha=0.15, color=C_BUY)
    ax2.set_title("RSI (14-day)")
    ax2.set_ylabel("RSI")
    ax2.set_ylim(0, 100)
    ax2.legend(fontsize=7)

    # ── Panel 3: Bollinger Bands ──────────────────────────────────────────────
    ax3 = fig.add_subplot(gs[2], sharex=ax1)
    ax3.plot(p["date"], p["close"],    color=C_PRICE, lw=1.2, label="Close")
    ax3.plot(p["date"], p["sma_20"],   color=C_SMA20, lw=1,   linestyle="--", label="SMA 20")
    ax3.plot(p["date"], p["bb_upper"], color=C_BB,    lw=1,   label="Upper Band")
    ax3.plot(p["date"], p["bb_lower"], color=C_BB,    lw=1,   label="Lower Band")
    ax3.fill_between(p["date"], p["bb_lower"], p["bb_upper"],
                     alpha=0.08, color=C_BB)
    ax3.set_title("Bollinger Bands (20-day, ±2σ)")
    ax3.set_ylabel("Price (USD)")
    ax3.legend(fontsize=7, ncol=4)

    # ── Panel 4: Equity curve vs buy-and-hold ─────────────────────────────────
    ax4 = fig.add_subplot(gs[3], sharex=ax1)
    ax4.plot(equity_df["date"], equity_df["equity"],
             color=C_EQUITY, lw=1.5, label="Strategy")
    ax4.plot(p["date"], p["bh_equity"],
             color=C_BH, lw=1.5, linestyle="--", label="Buy & Hold")
    ax4.axhline(INITIAL_CAPITAL, color="grey", linestyle=":", lw=0.8)
    ax4.set_title("Equity Curve vs Buy-and-Hold")
    ax4.set_ylabel("Portfolio Value (USD)")
    ax4.legend(fontsize=7)

    plt.savefig(f"dashboard/{ticker}_dashboard.png", dpi=150, bbox_inches="tight")
    print(f"  Saved dashboard/{ticker}_dashboard.png")
    plt.close()


def main():
    print("Loading data...")
    prices  = load_prices(DB_PATH)
    signals = load_signals(DB_PATH, SQL_PATH)

    print("Running backtests...")
    results = {t: backtest_ticker(signals, t, INITIAL_CAPITAL) for t in TICKERS}

    print("Rendering dashboards...")
    for ticker in TICKERS:
        plot_ticker(ticker, prices, signals, results[ticker])

    print("\n✅ All dashboards saved to dashboard/")


if __name__ == "__main__":
    main()