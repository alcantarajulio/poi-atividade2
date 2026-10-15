import json
import re
import sys
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

USAGE = "uso: analyze.py <pasta_de_resultados> [pasta_de_saida]"

# Avisos coletados durante a leitura (níveis faltando, janela estimada etc.).
# Vão para o stderr e para o topo do summary.md.
WARNINGS = []

def warn(msg):
    WARNINGS.append(msg)
    print(f"ATENÇÃO: {msg}", file=sys.stderr)

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

def read_env_float(meta, key):
    try:
        return float(meta.get(key, ""))
    except ValueError:
        return None

def measure_window(k6, ldir):
    """Janela de medição em epoch (t0, t1) e de onde ela veio.

    Preferência: o que o próprio k6 gravou (measure_start_epoch). Reserva: o horário em que
    o run.sh lançou o k6, mais o aquecimento. Sem nenhum dos dois (resultados antigos), None:
    a janela é estimada pela primeira amostra de cada coletor, que pode desalinhar os
    coletores em alguns segundos.
    """
    t0, t1 = k6.get("measure_start_epoch"), k6.get("measure_end_epoch")
    if t0 is not None and t1 is not None:
        return (float(t0), float(t1)), "k6"
    run_env = ldir / "run.env"
    if run_env.exists():
        launch = read_env_float(read_env(run_env), "k6_launch_epoch")
        if launch is not None:
            t0 = launch + k6["warmup_s"]
            return (t0, t0 + k6["duration_s"]), "launch"
    return None, "legacy"

def window(df, ts_col, warmup, duration, win=None):
    if df.empty:
        return df
    if win is not None:
        return df[(df[ts_col] >= win[0]) & (df[ts_col] <= win[1])]
    t0 = df[ts_col].min()
    return df[(df[ts_col] >= t0 + warmup) & (df[ts_col] <= t0 + warmup + duration)]

def span(ts, win):
    """Trecho da janela [t0, t1] coberto pelas amostras. Se os coletores pararam um pouco antes
    do fim da janela (ou começaram um pouco depois), usa só o trecho coberto, desde que seja
    pelo menos 80% da janela. Devolve None quando a cobertura é pior que isso."""
    a, b = max(win[0], ts.iloc[0]), min(win[1], ts.iloc[-1])
    if b - a < 0.8 * (win[1] - win[0]):
        return None
    return a, b

def rate(df, ts_col, col, win=None):
    """Taxa de um contador. Com janela absoluta, interpola o contador nas pontas do trecho
    coberto (sem erro de quantização das amostras); sem ela, usa a primeira e a última
    amostra recebidas."""
    if win is not None:
        d = df.sort_values(ts_col)
        if len(d) < 2:
            return float("nan")
        sp = span(d[ts_col], win)
        if sp is None:
            return float("nan")
        v0, v1 = np.interp(list(sp), d[ts_col], d[col])
        return (v1 - v0) / (sp[1] - sp[0])
    if len(df) < 2:
        return float("nan")
    df = df.sort_values(ts_col)
    dt = df[ts_col].iloc[-1] - df[ts_col].iloc[0]
    return (df[col].iloc[-1] - df[col].iloc[0]) / dt if dt > 0 else float("nan")

def app_metrics(path, warmup, duration, win=None):
    if not path.exists():
        return {}
    full = pd.read_csv(path)
    df = window(full, "ts", warmup, duration, win)
    if df.empty:
        return {}

    def series(name, src=df):
        s = src[src["series"] == name][["ts", "value"]]
        return s.groupby("ts", as_index=False)["value"].sum()

    def prefixed(prefix, src=df):
        s = src[src["series"].str.startswith(prefix)][["ts", "value"]]
        return s.groupby("ts", as_index=False)["value"].sum()

    def delta(s):
        """Variação de um contador na janela (interpolada quando há janela absoluta)."""
        if win is not None:
            if len(s) < 2:
                return float("nan")
            sp = span(s["ts"], win)
            if sp is None:
                return float("nan")
            v0, v1 = np.interp(list(sp), s["ts"], s["value"])
            return v1 - v0
        return s["value"].iloc[-1] - s["value"].iloc[0]

    out = {}
    cpu = series("process_cpu_seconds_total", full if win is not None else df)
    if not cpu.empty:
        out["app_cpu_cores"] = rate(cpu, "ts", "value", win)
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
    src = full if win is not None else df
    dsum = prefixed("http_request_duration_seconds_sum", src)
    dcount = prefixed("http_request_duration_seconds_count", src)
    if len(dsum) >= 2 and len(dcount) >= 2:
        n = delta(dcount)
        s = delta(dsum)
        if pd.notna(n) and n > 0:
            out["server_latency_avg_ms"] = s / n * 1000
    return out

def cgroup_metrics(path, warmup, duration, cpus, win=None):
    if not path.exists():
        return {}
    full = pd.read_csv(path).dropna()
    df = window(full, "ts", warmup, duration, win)
    if len(df) < 2:
        return {}
    cores = rate(full if win is not None else df, "ts", "cpu_usage_usec", win) / 1e6
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

def tz_hours(label):
    """Deslocamento em horas do rótulo de fuso que o vmstat imprime (UTC, -03, +0530...)."""
    if label in ("UTC", "GMT"):
        return 0.0
    m = re.fullmatch(r"([+-])(\d{2})(\d{2})?", label)
    if not m:
        return None
    sign = -1.0 if m.group(1) == "-" else 1.0
    return sign * (int(m.group(2)) + int(m.group(3) or 0) / 60)

def vmstat_metrics(path, warmup, duration, mem_total_mb, win=None, clock_offset=0.0):
    """Lê a saída de `vmstat -n -t 1`. A primeira linha de dados é a média desde o boot e é
    descartada. Com janela absoluta, cada linha é posicionada pelo seu carimbo de hora (do
    relógio do convidado, corrigido pelo desvio medido contra o hospedeiro); sem ele (ou se o
    fuso do vmstat não for UTC), cai para a contagem de linhas a partir do início."""
    if not path.exists():
        return {}
    lines = path.read_text().splitlines()
    if len(lines) < 4:
        return {}
    header = lines[1].split()
    tz_label = header[-1]
    names = header[:-1]
    n = len(names)
    rows, stamps = [], []
    for ln in lines[3:]:
        tok = ln.split()
        if len(tok) < n:
            continue
        rows.append(tok[:n])
        stamps.append(" ".join(tok[n : n + 2]))
    df = pd.DataFrame(rows, columns=names).apply(pd.to_numeric, errors="coerce")
    tz_h = tz_hours(tz_label)
    use_time = win is not None and tz_h is not None
    if use_time:
        ts = pd.to_datetime(pd.Series(stamps), format="%Y-%m-%d %H:%M:%S", errors="coerce", utc=True)
        epoch = (ts - pd.Timestamp("1970-01-01", tz="UTC")).dt.total_seconds()
        df["ts"] = (epoch - tz_h * 3600 - clock_offset).to_numpy()
    df = df.dropna()
    if use_time:
        df = df[(df["ts"] >= win[0]) & (df["ts"] <= win[1])]
    else:
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

def host_metrics(level_dir, warmup, duration, cpus, win=None):
    out = {}
    proc = level_dir / "host-proc.csv"
    if proc.exists():
        full = pd.read_csv(proc)
        df = window(full, "ts", warmup, duration, win)
        if len(df) >= 2:
            clk = df["clk_tck"].iloc[0]
            cores = rate(full if win is not None else df, "ts", "cpu_ticks", win) / clk
            out["host_vm_cpu_cores"] = cores
            out["host_vm_cpu_pct"] = cores / cpus * 100
            out["host_vm_rss_mb"] = df["rss_kb"].mean() / 1024
    vb = level_dir / "host-vbox.csv"
    if vb.exists():
        df = window(pd.read_csv(vb), "ts", warmup, duration, win)
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
        offset = read_env_float(meta, "clock_offset_s") or 0.0
        if abs(offset) > 1.0:
            warn(f"{meta['scenario']}: relógio do convidado difere {offset:+.2f} s do hospedeiro (corrigido na análise)")
        found = set()
        failed = []
        for ldir in sorted(sdir.glob("vus-*")):
            k6p = ldir / "k6.json"
            if not k6p.exists():
                if (ldir / "FAILED").exists():
                    failed.append(int(ldir.name.split("-")[1]))
                continue
            k6 = json.loads(k6p.read_text())
            found.add(int(k6["vus"]))
            warmup = k6.get("warmup_s", parse_seconds(meta["warmup"]))
            duration = k6["duration_s"]
            win, win_src = measure_window(k6, ldir)
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
                "window_src": win_src,
            }
            if k6.get("requests_tail", 0):
                warn(f"{meta['scenario']} vus={k6['vus']}: {k6['requests_tail']} requisições emitidas depois do fim da janela")
            row.update(app_metrics(ldir / "metrics.csv", warmup, duration, win))
            row.update(cgroup_metrics(ldir / "cgroup.csv", warmup, duration, cpus, win))
            row.update(vmstat_metrics(ldir / "vmstat.txt", warmup, duration, mem_total, win, offset))
            row.update(host_metrics(ldir, warmup, duration, cpus, win))
            if pd.notna(row.get("app_cpu_cores")) and row["rps"] > 0:
                row["cpu_per_req_ms"] = row["app_cpu_cores"] / row["rps"] * 1000
            rows.append(row)
        expected = sorted(int(v) for v in meta.get("levels", "").split())
        missing = [v for v in expected if v not in found]
        if missing or failed:
            detail = f" (run.sh marcou falha em {sorted(failed)})" if failed else ""
            warn(f"{meta['scenario']}: níveis sem resultado válido: {missing or sorted(failed)}{detail}; faltam nos gráficos")
    df = pd.DataFrame(rows)
    if df.empty:
        return df
    df = df.sort_values(["scenario", "vus"]).reset_index(drop=True)
    legacy = int((df["window_src"] == "legacy").sum())
    if legacy:
        warn(f"{legacy} ponto(s) sem janela gravada pelo k6/run.sh: janela estimada pela primeira amostra de cada coletor (pode desalinhar alguns segundos)")
    if (df["error_rate"] > 0.01).any():
        bad = df[df["error_rate"] > 0.01][["scenario", "vus"]].apply(lambda r: f"{r['scenario']}/{int(r['vus'])}", axis=1).tolist()
        warn(f"erro > 1% em: {', '.join(bad)}. Latência e vazão consideram só respostas 200")
    return df

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
    """Capacidade por cenário.

    O modelo de previsão (X_max = vCPUs / demanda de CPU por requisição, e N* = X_max (D + Z))
    só faz sentido para a aplicação CPU-bound. Para memória e I/O o gargalo não é a CPU, então
    as colunas previstas ficam vazias: só entram os valores observados (vazão máxima e joelho
    da latência).
    """
    rows = []
    nan = float("nan")
    for s, d in df.groupby("scenario"):
        d = d.sort_values("vus")
        first = d.iloc[0]
        z = first["think_time_s"]
        cpus = first["cpus"]
        best = d.loc[d["rps"].idxmax()]
        base = first["lat_p95_ms"]
        knee = d[d["lat_p95_ms"] > 2 * base]
        demand = x_max = n_star = nan
        if first["app"] == "cpu":
            if "cpu_per_req_ms" in d and d["cpu_per_req_ms"].notna().any():
                demand = d["cpu_per_req_ms"].median()
            else:
                demand = first["lat_p50_ms"]
            x_max = cpus / (demand / 1000)
            n_star = x_max * (demand / 1000 + z)
        rows.append(
            {
                "scenario": s,
                "app": first["app"],
                "cpus": cpus,
                "mem_mb": first["mem_mb"],
                "think_time_s": z,
                "demand_ms": demand,
                "x_max_pred": x_max,
                "x_max_obs": best["rps"],
                "vus_at_max": best["vus"],
                "n_star_pred": n_star,
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
        if WARNINGS:
            f.write("## Avisos\n\n")
            for w in WARNINGS:
                f.write(f"- {w}\n")
            f.write("\n")
        f.write("## Capacidade por cenário\n\n")
        if (df["app"] != "cpu").any():
            f.write(
                "Previsão (`demand_ms`, `x_max_pred`, `n_star_pred`) só existe para a aplicação "
                "CPU-bound; para memória e I/O ficam vazias porque o modelo assume que a CPU é o gargalo.\n\n"
            )
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
