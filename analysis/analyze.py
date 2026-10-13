import json
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import pandas as pd

USAGE = "uso: analyze.py <pasta_de_resultados> [pasta_de_saida]"

SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300"]
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"

def read_env(path):
    out = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out

def window(df, ts_col, warmup, duration):
    if df.empty:
        return df
    t0 = df[ts_col].min()
    return df[(df[ts_col] >= t0 + warmup) & (df[ts_col] <= t0 + warmup + duration)]

def rate(df, ts_col, col):
    if len(df) < 2:
        return float("nan")
    df = df.sort_values(ts_col)
    dt = df[ts_col].iloc[-1] - df[ts_col].iloc[0]
    return (df[col].iloc[-1] - df[col].iloc[0]) / dt if dt > 0 else float("nan")

def app_metrics(path, warmup, duration):
    if not path.exists():
        return {}
    df = pd.read_csv(path)
    df = window(df, "ts", warmup, duration)
    if df.empty:
        return {}

    def series(name):
        s = df[df["series"] == name][["ts", "value"]]
        return s.groupby("ts", as_index=False)["value"].sum()

    def prefixed(prefix):
        s = df[df["series"].str.startswith(prefix)][["ts", "value"]]
        return s.groupby("ts", as_index=False)["value"].sum()

    out = {}
    cpu = series("process_cpu_seconds_total")
    if not cpu.empty:
        out["app_cpu_cores"] = rate(cpu, "ts", "value")
    rss = series("process_resident_memory_bytes")
    if not rss.empty:
        out["app_rss_mb"] = rss["value"].mean() / 2**20
        out["app_rss_max_mb"] = rss["value"].max() / 2**20
    heap = series("go_memstats_heap_inuse_bytes")
    if not heap.empty:
        out["app_heap_mb"] = heap["value"].mean() / 2**20
    inflight = series("http_requests_in_flight")
    if not inflight.empty:
        out["app_in_flight"] = inflight["value"].mean()
    dsum = prefixed("http_request_duration_seconds_sum")
    dcount = prefixed("http_request_duration_seconds_count")
    if len(dsum) >= 2 and len(dcount) >= 2:
        n = dcount["value"].iloc[-1] - dcount["value"].iloc[0]
        s = dsum["value"].iloc[-1] - dsum["value"].iloc[0]
        if n > 0:
            out["server_latency_avg_ms"] = s / n * 1000
    return out

def cgroup_metrics(path, warmup, duration, cpus):
    if not path.exists():
        return {}
    df = pd.read_csv(path).dropna()
    df = window(df, "ts", warmup, duration)
    if len(df) < 2:
        return {}
    cores = rate(df, "ts", "cpu_usage_usec") / 1e6
    return {
        "cpu_cores": cores,
        "cpu_pct": cores / cpus * 100,
        "mem_used_mb": df["mem_anon_bytes"].mean() / 2**20,
        "mem_total_mb": float("nan"),
    }

def guest_mem_total_mb(scenario_dir):
    p = scenario_dir / "guest.txt"
    if not p.exists():
        return float("nan")
    for line in p.read_text().splitlines():
        if line.startswith("Mem:"):
            return float(line.split()[1])
    return float("nan")

def vmstat_metrics(path, warmup, duration, mem_total_mb):
    if not path.exists():
        return {}
    lines = path.read_text().splitlines()
    if len(lines) < 4:
        return {}
    names = lines[1].split()[:-1]
    rows = [ln.split()[: len(names)] for ln in lines[3:] if ln.strip()]
    df = pd.DataFrame(rows, columns=names).apply(pd.to_numeric, errors="coerce").dropna()
    df = df.iloc[int(warmup) : int(warmup + duration)]
    if df.empty:
        return {}
    used_kb = mem_total_mb * 1024 - df["free"] - df["buff"] - df["cache"]
    return {
        "cpu_pct": (df["us"] + df["sy"]).mean(),
        "cpu_user_pct": df["us"].mean(),
        "cpu_sys_pct": df["sy"].mean(),
        "cpu_iowait_pct": df["wa"].mean(),
        "cpu_steal_pct": df["st"].mean() if "st" in df else float("nan"),
        "run_queue": df["r"].mean(),
        "mem_used_mb": used_kb.mean() / 1024,
        "mem_total_mb": mem_total_mb,
        "swap_used_mb": df["swpd"].mean() / 1024,
        "swap_in_kbs": df["si"].mean(),
        "swap_out_kbs": df["so"].mean(),
    }

def host_metrics(level_dir, warmup, duration, cpus):
    out = {}
    proc = level_dir / "host-proc.csv"
    if proc.exists():
        df = window(pd.read_csv(proc), "ts", warmup, duration)
        if len(df) >= 2:
            clk = df["clk_tck"].iloc[0]
            cores = rate(df, "ts", "cpu_ticks") / clk
            out["host_vm_cpu_cores"] = cores
            out["host_vm_cpu_pct"] = cores / cpus * 100
            out["host_vm_rss_mb"] = df["rss_kb"].mean() / 1024
    vb = level_dir / "host-vbox.csv"
    if vb.exists():
        df = window(pd.read_csv(vb), "ts", warmup, duration)
        df = df[pd.to_numeric(df["value"], errors="coerce").notna()]
        for metric, g in df.groupby("metric"):
            key = "vbox_" + re.sub(r"[^A-Za-z0-9]+", "_", metric).strip("_").lower()
            out[key] = pd.to_numeric(g["value"]).mean()
    return out

def parse_seconds(s):
    m = re.fullmatch(r"(\d+(?:\.\d+)?)(ms|s|m)", s)
    v = float(m.group(1))
    return v / 1000 if m.group(2) == "ms" else v * 60 if m.group(2) == "m" else v

def load(results):
    rows = []
    for sdir in sorted(p for p in results.iterdir() if (p / "scenario.env").exists()):
        meta = read_env(sdir / "scenario.env")
        cpus = float(meta["cpus"])
        mem_total = guest_mem_total_mb(sdir)
        for ldir in sorted(sdir.glob("vus-*")):
            k6p = ldir / "k6.json"
            if not k6p.exists():
                continue
            k6 = json.loads(k6p.read_text())
            warmup = k6.get("warmup_s", parse_seconds(meta["warmup"]))
            duration = k6["duration_s"]
            lat = {k: (float("nan") if v is None else v) for k, v in k6["latency_ms"].items()}
            row = {
                "scenario": meta["scenario"],
                "app": meta.get("app", ""),
                "think_time_s": float(k6.get("think_time_s", meta.get("think_time", 0))),
                "cpus": cpus,
                "mem_mb": int(meta["mem_mb"]),
                "vus": k6["vus"],
                "rps": k6.get("rps_ok", k6["rps"]),
                "rps_total": k6["rps"],
                "lat_avg_ms": lat["avg"],
                "lat_p50_ms": lat["p50"],
                "lat_p95_ms": lat["p95"],
                "lat_p99_ms": lat["p99"],
                "error_rate": k6["error_rate"],
                "requests": k6["requests"],
            }
            row.update(app_metrics(ldir / "metrics.csv", warmup, duration))
            row.update(cgroup_metrics(ldir / "cgroup.csv", warmup, duration, cpus))
            row.update(vmstat_metrics(ldir / "vmstat.txt", warmup, duration, mem_total))
            row.update(host_metrics(ldir, warmup, duration, cpus))
            if pd.notna(row.get("app_cpu_cores")) and row["rps"] > 0:
                row["cpu_per_req_ms"] = row["app_cpu_cores"] / row["rps"] * 1000
            rows.append(row)
    return pd.DataFrame(rows).sort_values(["scenario", "vus"]).reset_index(drop=True)

def style():
    plt.rcParams.update(
        {
            "figure.facecolor": SURFACE,
            "axes.facecolor": SURFACE,
            "savefig.facecolor": SURFACE,
            "font.family": ["Helvetica Neue", "Arial", "DejaVu Sans"],
            "font.size": 10,
            "text.color": INK,
            "axes.labelcolor": INK_2,
            "axes.edgecolor": AXIS,
            "axes.linewidth": 1,
            "axes.titlesize": 11,
            "axes.titleweight": "semibold",
            "axes.titlelocation": "left",
            "axes.titlecolor": INK,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "grid.color": GRID,
            "grid.linewidth": 0.8,
            "grid.linestyle": "-",
            "xtick.color": MUTED,
            "ytick.color": MUTED,
            "xtick.labelcolor": INK_2,
            "ytick.labelcolor": INK_2,
            "legend.frameon": False,
            "legend.labelcolor": INK_2,
        }
    )

def scenario_label(df, s):
    r = df[df["scenario"] == s].iloc[0]
    mem = r["mem_mb"] / 1024
    return f"{s}: {r['cpus']:g} vCPU, {mem:g} GB"

def lines(ax, df, x, y, logx=True):
    for i, s in enumerate(sorted(df["scenario"].unique())):
        d = df[df["scenario"] == s].sort_values(x)
        if d[y].isna().all():
            continue
        ax.plot(
            d[x], d[y], color=SERIES[i % len(SERIES)], linewidth=2,
            marker="o", markersize=6, markeredgecolor=SURFACE, markeredgewidth=1.5,
            solid_capstyle="round", solid_joinstyle="round",
            label=scenario_label(df, s),
        )
    if logx:
        ax.set_xscale("log", base=2)
        ticks = sorted(df[x].unique())
        ax.set_xticks(ticks)
        ax.set_xticklabels([f"{t:g}" for t in ticks])
        ax.minorticks_off()

def legend_below(ax, n):
    handles, labels = ax.get_legend_handles_labels()
    ax.figure.legend(handles, labels, loc="lower center", ncol=min(n, 4),
                     handlelength=1.6, columnspacing=1.6, bbox_to_anchor=(0.5, -0.02))

def headroom(ax, values):
    top = values.max()
    if pd.notna(top) and top > 0:
        ax.set_ylim(0, top * 1.12)

def save(fig, out, name):
    fig.tight_layout(rect=(0, 0.07, 1, 1))
    fig.savefig(out / name, dpi=160, bbox_inches="tight", pad_inches=0.15)
    plt.close(fig)

def plots(df, out):
    style()
    vus_label = "Usuários simultâneos (VUs do k6)"
    n = df["scenario"].nunique()

    fig, ax = plt.subplots(figsize=(8, 4.8))
    lines(ax, df, "vus", "rps")
    ax.set_title("Vazão por nível de demanda")
    ax.set_xlabel(vus_label)
    ax.set_ylabel("Respostas bem-sucedidas por segundo")
    headroom(ax, df["rps"])
    legend_below(ax, n)
    save(fig, out, "vazao_vs_demanda.png")

    fig, axes = plt.subplots(1, 2, figsize=(10, 4.6), sharey=True)
    for ax, col, title in zip(axes, ["lat_p50_ms", "lat_p95_ms"], ["Latência p50", "Latência p95"]):
        lines(ax, df, "vus", col)
        ax.set_title(title)
        ax.set_xlabel(vus_label)
        ax.set_yscale("log")
    axes[0].set_ylabel("Tempo de resposta (ms, escala log)")
    legend_below(axes[0], n)
    save(fig, out, "latencia_vs_demanda.png")

    if "cpu_pct" in df and df["cpu_pct"].notna().any():
        fig, ax = plt.subplots(figsize=(8, 4.8))
        lines(ax, df, "vus", "cpu_pct")
        ax.set_title("Utilização de CPU (% das vCPUs provisionadas)")
        ax.set_xlabel(vus_label)
        ax.set_ylabel("CPU ocupada (%)")
        ax.set_ylim(0, 105)
        legend_below(ax, n)
        save(fig, out, "cpu_vs_demanda.png")

    if "mem_used_mb" in df and df["mem_used_mb"].notna().any():
        fig, ax = plt.subplots(figsize=(8, 4.8))
        lines(ax, df, "vus", "mem_used_mb")
        ax.set_title("Memória em uso")
        ax.set_xlabel(vus_label)
        ax.set_ylabel("MB")
        headroom(ax, df["mem_used_mb"])
        legend_below(ax, n)
        save(fig, out, "memoria_vs_demanda.png")

    fig, ax = plt.subplots(figsize=(8, 4.8))
    lines(ax, df, "rps", "lat_p95_ms", logx=False)
    ax.set_title("Latência p95 em função da vazão obtida")
    ax.set_xlabel("Requisições por segundo")
    ax.set_ylabel("Latência p95 (ms, escala log)")
    ax.set_yscale("log")
    ax.set_xlim(left=0)
    legend_below(ax, n)
    save(fig, out, "latencia_vs_vazao.png")

    if df["error_rate"].max() > 0:
        fig, ax = plt.subplots(figsize=(8, 4.8))
        d = df.assign(error_pct=df["error_rate"] * 100)
        lines(ax, d, "vus", "error_pct")
        ax.set_title("Requisições com erro")
        ax.set_xlabel(vus_label)
        ax.set_ylabel("% das requisições")
        ax.set_ylim(0, 105)
        legend_below(ax, n)
        save(fig, out, "erros_vs_demanda.png")


def capacity(df):
    rows = []
    for s, d in df.groupby("scenario"):
        d = d.sort_values("vus")
        first = d.iloc[0]
        if "cpu_per_req_ms" in d and d["cpu_per_req_ms"].notna().any():
            demand = d["cpu_per_req_ms"].median()
        else:
            demand = first["lat_p50_ms"]
        z = first["think_time_s"]
        cpus = first["cpus"]
        x_max = cpus / (demand / 1000)
        best = d.loc[d["rps"].idxmax()]
        base = first["lat_p95_ms"]
        knee = d[d["lat_p95_ms"] > 2 * base]
        rows.append(
            {
                "scenario": s,
                "cpus": cpus,
                "mem_mb": first["mem_mb"],
                "think_time_s": z,
                "demand_ms": demand,
                "x_max_pred": x_max,
                "x_max_obs": best["rps"],
                "vus_at_max": best["vus"],
                "n_star_pred": x_max * (demand / 1000 + z),
                "knee_vus": knee["vus"].iloc[0] if not knee.empty else None,
            }
        )
    return pd.DataFrame(rows)

def write_tables(df, out):
    df.to_csv(out / "summary.csv", index=False)
    cols = [
        c
        for c in [
            "scenario", "vus", "rps", "lat_p50_ms", "lat_p95_ms", "lat_p99_ms", "error_rate",
            "cpu_pct", "cpu_per_req_ms", "run_queue", "mem_used_mb", "app_rss_mb", "app_cpu_cores", "host_vm_cpu_pct",
        ]
        if c in df
    ]
    cap = capacity(df)
    with open(out / "summary.md", "w") as f:
        f.write("## Capacidade por cenário\n\n")
        f.write(cap.to_markdown(index=False, floatfmt=".1f"))
        f.write("\n\n## Todos os níveis\n\n")
        f.write(df[cols].to_markdown(index=False, floatfmt=".1f"))
        f.write("\n")
    return cap

def main():
    if len(sys.argv) < 2:
        sys.exit(USAGE)
    results = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("docs/figuras") / results.name
    out.mkdir(parents=True, exist_ok=True)

    df = load(results)
    if df.empty:
        sys.exit(f"nenhum k6.json encontrado em {results}")
    cap = write_tables(df, out)
    plots(df, out)
    print(cap.to_string(index=False))
    print(f"\n{len(df)} pontos -> {out}")

if __name__ == "__main__":
    main()
