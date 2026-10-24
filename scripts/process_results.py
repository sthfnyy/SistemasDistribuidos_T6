#!/usr/bin/env python3
"""Aggregate raw Locust CSVs into summary tables and charts."""

from __future__ import annotations

import csv
import re
from pathlib import Path
from typing import Iterable

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
RAW_ROOT = ROOT / "results" / "raw"
PROCESSED_ROOT = ROOT / "results" / "processed"
GRAPHS_ROOT = ROOT / "results" / "graphs"

def _read_requests_csv(path: Path) -> dict:
    with path.open("r", newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return {}
    return rows[-1]


def _iter_run_csvs() -> Iterable[Path]:
    for profile_dir in RAW_ROOT.iterdir():
        if not profile_dir.is_dir():
            continue
        if profile_dir.name not in {"validacao", "leitura", "escrita"}:
            continue
        for users_dir in profile_dir.iterdir():
            if not users_dir.is_dir():
                continue
            for csv_path in sorted(users_dir.glob("*_requests.csv")):
                yield csv_path
            for csv_path in sorted(users_dir.glob("*_stats.csv")):
                if csv_path.name.endswith("_stats_history.csv"):
                    continue
                yield csv_path


def _metric_value(row: dict, key: str, default: float = 0.0) -> float:
    value = row.get(key, "")
    if value in (None, ""):
        return default
    try:
        return float(value)
    except ValueError:
        return default


def build_summary() -> pd.DataFrame:
    rows = []
    for csv_path in _iter_run_csvs():
        profile = csv_path.parents[1].name
        users_dir_name = csv_path.parent.name
        users_value = users_dir_name.replace("-users", "")
        users = int(users_value.split("-")[0] if "-" in users_value else users_value)
        run_name = csv_path.stem.replace("_requests", "").replace("_stats", "")
        profile_label = {
            "leitura": "leitura",
            "escrita": "escrita",
            "validacao": "validacao",
        }.get(profile, profile)

        history_path = csv_path.with_name(csv_path.stem.replace("_stats", "_stats_history") + ".csv")
        warmup_seconds = 0
        measurement_seconds = 0.0
        warmup_reset_confirmed = False
        if history_path.exists():
            history = pd.read_csv(history_path)
            aggregate = history[history["Name"] == "Aggregated"].copy()
            aggregate["Total Request Count"] = pd.to_numeric(
                aggregate["Total Request Count"], errors="coerce"
            )
            aggregate["Timestamp"] = pd.to_numeric(aggregate["Timestamp"], errors="coerce")
            aggregate = aggregate.dropna(subset=["Total Request Count", "Timestamp"])
            drops = aggregate["Total Request Count"].diff() < 0
            if drops.any():
                reset_index = drops[drops].index[-1]
                reset_timestamp = float(aggregate.loc[reset_index, "Timestamp"])
                measurement_seconds = float(aggregate["Timestamp"].iloc[-1]) - reset_timestamp
                warmup_seconds = 60
                warmup_reset_confirmed = True

        if profile in {"leitura", "escrita"} and not warmup_reset_confirmed:
            raise RuntimeError(
                f"Warm-up reset not found in {history_path}; refusing to process benchmark data"
            )

        requests_row = _read_requests_csv(csv_path)
        if not requests_row:
            continue

        avg_response_ms = _metric_value(requests_row, "Average Response Time")
        p95_ms = _metric_value(requests_row, "95%ile") or _metric_value(requests_row, "95%")
        reqs_per_second = _metric_value(requests_row, "Requests/s")
        total_requests = _metric_value(requests_row, "Total Requests") or _metric_value(requests_row, "Request Count")
        failure_count = _metric_value(requests_row, "Failure Count")
        failure_rate = _metric_value(requests_row, "Failure Rate")
        if not failure_rate and total_requests:
            failure_rate = 100.0 * failure_count / total_requests
        cpu_row = {
            "profile": profile_label,
            "users": users,
            "run": run_name,
            "avg_response_ms": avg_response_ms,
            "p95_ms": p95_ms,
            "requests_per_second": reqs_per_second,
            "total_requests": total_requests,
            "failure_rate_percent": failure_rate,
            "warmup_discarded_seconds": warmup_seconds,
            "measurement_duration_seconds": measurement_seconds,
            "warmup_reset_confirmed": warmup_reset_confirmed,
        }
        rows.append(cpu_row)

    if not rows:
        return pd.DataFrame(columns=[
            "profile",
            "users",
            "avg_response_ms",
            "p95_ms",
            "requests_per_second",
            "total_requests",
            "failure_rate_percent",
            "cpu_service_1",
            "cpu_service_2",
        ])

    df = pd.DataFrame(rows)
    if "avg_response_ms" in df.columns:
        df["avg_response_ms"] = pd.to_numeric(df["avg_response_ms"], errors="coerce")
    if "p95_ms" in df.columns:
        df["p95_ms"] = pd.to_numeric(df["p95_ms"], errors="coerce")
    if "requests_per_second" in df.columns:
        df["requests_per_second"] = pd.to_numeric(df["requests_per_second"], errors="coerce")
    if "total_requests" in df.columns:
        df["total_requests"] = pd.to_numeric(df["total_requests"], errors="coerce")
    if "failure_rate_percent" in df.columns:
        df["failure_rate_percent"] = pd.to_numeric(df["failure_rate_percent"], errors="coerce")

    return (
        df.groupby(["profile", "users"], as_index=False)
        .agg(
            valid_runs=("run", "nunique"),
            avg_response_ms=("avg_response_ms", "mean"),
            p95_ms=("p95_ms", "mean"),
            requests_per_second=("requests_per_second", "mean"),
            total_requests=("total_requests", "sum"),
            failure_rate_percent=("failure_rate_percent", "mean"),
            warmup_discarded_seconds=("warmup_discarded_seconds", "max"),
            measurement_duration_seconds=("measurement_duration_seconds", "max"),
            warmup_reset_confirmed=("warmup_reset_confirmed", "all"),
        )
    )


CPU_SUMMARY_COLUMNS = [
    "profile",
    "users",
    "cpu_customers_service",
    "cpu_vets_service",
    "cpu_samples_customers_service",
    "cpu_samples_vets_service",
    "valid_cpu_runs",
]


def build_cpu_summary() -> pd.DataFrame:
    cpu_files = sorted(RAW_ROOT.glob("cpu_*.csv"))
    if not cpu_files:
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    frames = []
    for path in cpu_files:
        if not path.exists():
            continue
        frame = pd.read_csv(path)
        if "validation" in path.stem:
            frame["profile"] = "validacao"
            frame["_run"] = pd.to_numeric(frame["run"], errors="coerce")
        else:
            match = re.fullmatch(r"cpu_(read|write)_(\d+)_run(\d+)", path.stem)
            if not match:
                continue
            profile_code, users, run = match.groups()
            profile_dir = "leitura" if profile_code == "read" else "escrita"
            history_path = (
                RAW_ROOT
                / profile_dir
                / f"{users}-users"
                / f"{profile_code}_{users}_run{int(run):02d}_stats_history.csv"
            )
            if not history_path.exists():
                raise RuntimeError(f"Locust history not found for CPU file {path}")

            history = pd.read_csv(history_path)
            aggregate = history[history["Name"] == "Aggregated"].copy()
            aggregate["Total Request Count"] = pd.to_numeric(
                aggregate["Total Request Count"], errors="coerce"
            )
            aggregate["Timestamp"] = pd.to_numeric(aggregate["Timestamp"], errors="coerce")
            aggregate = aggregate.dropna(subset=["Total Request Count", "Timestamp"])
            drops = aggregate["Total Request Count"].diff() < 0
            if not drops.any():
                raise RuntimeError(
                    f"Warm-up reset not found in {history_path}; refusing to process CPU data"
                )

            reset_index = drops[drops].index[-1]
            window_start = pd.to_datetime(
                float(aggregate.loc[reset_index, "Timestamp"]), unit="s", utc=True
            )
            window_end = pd.to_datetime(
                float(aggregate["Timestamp"].iloc[-1]), unit="s", utc=True
            )
            frame["_timestamp_utc"] = pd.to_datetime(frame["timestamp"], utc=True, errors="coerce")
            frame = frame[
                (frame["_timestamp_utc"] >= window_start)
                & (frame["_timestamp_utc"] <= window_end)
            ].copy()
            frame["profile"] = profile_dir
            frame["_run"] = int(run)
        frames.append(frame)
    if not frames:
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    combined = pd.concat(frames, ignore_index=True)
    if combined.empty:
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    required = {"profile", "users", "service", "cpu_percent"}
    if not required.issubset(combined.columns):
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    combined["profile"] = combined["profile"].str.lower().replace({"read": "leitura", "write": "escrita"})
    combined["users"] = pd.to_numeric(combined["users"], errors="coerce")
    combined["cpu_percent"] = pd.to_numeric(combined["cpu_percent"], errors="coerce")
    combined = combined.dropna(subset=["profile", "users", "cpu_percent"])
    if combined.empty:
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    cpu_per_run = combined.groupby(
        ["profile", "users", "_run", "service"], as_index=False
    ).agg(cpu_percent=("cpu_percent", "mean"), sample_count=("cpu_percent", "count"))
    cpu_by_service = cpu_per_run.groupby(
        ["profile", "users", "service"], as_index=False
    ).agg(
        cpu_percent=("cpu_percent", "mean"),
        sample_count=("sample_count", "sum"),
        valid_cpu_runs=("_run", "nunique"),
    )
    service_names = sorted(cpu_by_service["service"].dropna().unique().tolist())
    if not service_names:
        return pd.DataFrame(columns=CPU_SUMMARY_COLUMNS)

    service_names = service_names[:2]
    rows = []
    for (profile, users), group in cpu_by_service.groupby(["profile", "users"]):
        service_values = group.set_index("service")["cpu_percent"].to_dict()
        sample_values = group.set_index("service")["sample_count"].to_dict()
        valid_run_values = group.set_index("service")["valid_cpu_runs"].to_dict()
        rows.append({
            "profile": profile,
            "users": int(users),
            "cpu_customers_service": service_values.get("customers-service", float("nan")),
            "cpu_vets_service": service_values.get("vets-service", float("nan")),
            "cpu_samples_customers_service": sample_values.get("customers-service", 0),
            "cpu_samples_vets_service": sample_values.get("vets-service", 0),
            "valid_cpu_runs": min(valid_run_values.values()) if valid_run_values else 0,
        })

    return pd.DataFrame(rows).sort_values(["profile", "users"]).reset_index(drop=True)


def plot_metrics(summary: pd.DataFrame, cpu_summary: pd.DataFrame) -> None:
    GRAPHS_ROOT.mkdir(parents=True, exist_ok=True)
    if summary.empty:
        return

    benchmark = summary[summary["profile"].isin(["leitura", "escrita"])]
    plots = [
        ("avg_response_ms", "Tempo médio de resposta", "ms", "avg_response_time.png"),
        ("p95_ms", "P95", "ms", "p95_response_time.png"),
        ("requests_per_second", "Vazão", "req/s", "throughput.png"),
        ("failure_rate_percent", "Taxa de falhas", "%", "failure_rate.png"),
    ]
    for metric, title, ylabel, filename in plots:
        fig, ax = plt.subplots(figsize=(8, 5))
        for profile in ["leitura", "escrita"]:
            subset = benchmark[benchmark["profile"] == profile].sort_values("users")
            if not subset.empty:
                ax.plot(subset["users"], subset[metric], marker="o", label=profile)
        ax.set_title(title)
        ax.set_xlabel("Usuários")
        ax.set_ylabel(ylabel)
        ax.grid(True, alpha=0.3)
        ax.legend()
        fig.tight_layout()
        fig.savefig(GRAPHS_ROOT / filename, dpi=150)
        plt.close(fig)

    if not cpu_summary.empty:
        fig, ax = plt.subplots(figsize=(8, 5))
        for profile in sorted(cpu_summary["profile"].dropna().unique()):
            subset = cpu_summary[cpu_summary["profile"] == profile].sort_values("users")
            if subset.empty:
                continue
            ax.plot(subset["users"], subset["cpu_customers_service"], marker="o", label=f"{profile} - customers")
            ax.plot(subset["users"], subset["cpu_vets_service"], marker="s", label=f"{profile} - vets")
        ax.set_title("Uso de CPU por cenário")
        ax.set_xlabel("Usuários")
        ax.set_ylabel("CPU %")
        ax.grid(True, alpha=0.3)
        ax.legend()
        fig.tight_layout()
        fig.savefig(GRAPHS_ROOT / "cpu_usage.png", dpi=150)
        plt.close(fig)


def main() -> None:
    summary = build_summary()
    cpu_summary = build_cpu_summary()
    if not summary.empty:
        summary = summary.drop(columns=CPU_SUMMARY_COLUMNS[2:], errors="ignore")
        if not cpu_summary.empty:
            summary = summary.merge(cpu_summary, on=["profile", "users"], how="left")
        summary = summary[[
            "profile",
            "users",
            "valid_runs",
            "avg_response_ms",
            "p95_ms",
            "requests_per_second",
            "total_requests",
            "failure_rate_percent",
            "warmup_discarded_seconds",
            "measurement_duration_seconds",
            "warmup_reset_confirmed",
            "cpu_customers_service",
            "cpu_vets_service",
            "cpu_samples_customers_service",
            "cpu_samples_vets_service",
            "valid_cpu_runs",
        ]]
    PROCESSED_ROOT.mkdir(parents=True, exist_ok=True)
    summary.to_csv(PROCESSED_ROOT / "resumo.csv", index=False)
    summary.to_csv(PROCESSED_ROOT / "medias.csv", index=False)
    cpu_summary.to_csv(PROCESSED_ROOT / "cpu.csv", index=False)
    plot_metrics(summary, cpu_summary)
    print(f"Processed rows: {len(summary)}")


if __name__ == "__main__":
    main()
