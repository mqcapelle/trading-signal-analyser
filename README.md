# Trading Signal Analyser

A DuckDB-powered algorithmic trading pipeline that computes technical indicators
entirely in SQL window functions, generates buy/sell signals, and benchmarks
strategy performance against buy-and-hold.

## Tech Stack
- **DuckDB** — embedded analytical database, all indicators computed in SQL
- **yfinance** — real OHLCV market data ingestion
- **pandas** — DataFrame bridge between DuckDB and Python
- **Matplotlib** — multi-panel performance dashboard

## Project Structure
```
trading-signal-analyser/
├── data/
│   └── ingest_prices.py         # Fetches OHLCV data → trading.duckdb
├── queries/
│   ├── sma_crossover.sql        # 20/50-day SMA crossover signals
│   ├── rsi.sql                  # 14-day RSI in pure SQL
│   ├── bollinger_bands.sql      # Bollinger Bands (rolling mean + stddev)
│   └── signal_summary.sql      # Unified buy/sell signal table
├── analysis/
│   └── backtest.py              # P&L, Sharpe ratio, max drawdown
└── dashboard/
    └── plot_dashboard.py        # Strategy vs benchmark + signal overlays
```

## Quickstart
```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

python data/ingest_prices.py         # Fetch data → trading.duckdb
python analysis/backtest.py          # Run signals + compute metrics
python dashboard/plot_dashboard.py   # Render dashboard
```

## Requirements
See `requirements.txt`

## Disclaimer
This project is for educational purposes only. Nothing here constitutes
financial advice or a recommendation to trade any security.

## Development Notes
Built as part of a structured SQL learning track, using Claude as an
interactive coding assistant. All technical decisions, debugging, and
concept validation were done collaboratively — the focus was on
understanding SQL window functions, DuckDB, and quantitative finance
concepts rather than generating code blindly.
