#!/usr/bin/env python3
# =============================================================================
# score_s2b_compare.py
#
# Reads s2b_compare_log.csv produced by tb_s2b_compare.sv and produces:
#   - Numeric summary (mean/max/RMSE per converter)
#   - A side-by-side error plot saved as s2b_compare.png / .pdf
#   - A second plot showing converter output vs. ideal for both DUTs
#
# Usage:
#   python3 score_s2b_compare.py [log_csv]
#   default log_csv = ./s2b_compare_log.csv
# =============================================================================
import sys
import csv
import math
from pathlib import Path

try:
    import numpy as np
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.exit("requires numpy + matplotlib (pip install numpy matplotlib)")


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("s2b_compare_log.csv")
    if not path.exists():
        sys.exit(f"file not found: {path}")

    rows = []
    with open(path) as f:
        r = csv.DictReader(f)
        for row in r:
            rows.append({k: int(v) for k, v in row.items()})

    if not rows:
        sys.exit("empty log file")

    inputs  = np.array([r["input"]       for r in rows])
    sar_out = np.array([r["sar_out"]     for r in rows])
    cnt_out = np.array([r["counter_out"] for r in rows])
    sar_err = np.array([r["sar_err"]     for r in rows])
    cnt_err = np.array([r["counter_err"] for r in rows])

    N = len(inputs)
    width_bits = int(math.ceil(math.log2(inputs.max() + 1))) if inputs.max() > 0 else 8
    full_scale = 2 ** width_bits - 1

    def stats(err, name):
        rmse = float(np.sqrt(np.mean(err ** 2)))
        mae  = float(np.mean(err))
        mx   = int(err.max())
        return {
            "name": name,
            "mae":  mae,
            "rmse": rmse,
            "max":  mx,
            "mae_pct":  100.0 * mae  / full_scale,
            "rmse_pct": 100.0 * rmse / full_scale,
            "max_pct":  100.0 * mx   / full_scale,
        }

    sar_s = stats(sar_err, "SAR")
    cnt_s = stats(cnt_err, "Counter")

    print("=" * 70)
    print(f"  S2B Comparison  ({N} sweep points, WIDTH={width_bits})")
    print("=" * 70)
    fmt = "  {:<8}  MAE={:7.3f}  RMSE={:7.3f}  MAX={:5d}   ({:5.2f}% / {:5.2f}% / {:5.2f}%)"
    print(fmt.format(sar_s["name"], sar_s["mae"], sar_s["rmse"], sar_s["max"],
                     sar_s["mae_pct"], sar_s["rmse_pct"], sar_s["max_pct"]))
    print(fmt.format(cnt_s["name"], cnt_s["mae"], cnt_s["rmse"], cnt_s["max"],
                     cnt_s["mae_pct"], cnt_s["rmse_pct"], cnt_s["max_pct"]))
    print("=" * 70)

    # Verdict
    if sar_s["rmse"] < cnt_s["rmse"]:
        ratio = cnt_s["rmse"] / sar_s["rmse"] if sar_s["rmse"] > 0 else float("inf")
        print(f"  SAR is {ratio:.2f}x more accurate by RMSE")
    else:
        ratio = sar_s["rmse"] / cnt_s["rmse"] if cnt_s["rmse"] > 0 else float("inf")
        print(f"  Counter is {ratio:.2f}x more accurate by RMSE")
    print("=" * 70)

    # ---- Plot 1: absolute error vs input value ---------------------------
    fig, ax = plt.subplots(2, 1, figsize=(10, 9))

    ax[0].plot(inputs, sar_err, label=f"SAR (RMSE {sar_s['rmse']:.2f})",
               alpha=0.8, linewidth=1.2)
    ax[0].plot(inputs, cnt_err, label=f"Counter (RMSE {cnt_s['rmse']:.2f})",
               alpha=0.8, linewidth=1.2)
    ax[0].set_xlabel("input value (binary code)")
    ax[0].set_ylabel("absolute error (LSB)")
    ax[0].set_title(f"S2B converter error sweep -- WIDTH={width_bits}, "
                    f"same total integration time")
    ax[0].legend(loc="upper right")
    ax[0].grid(True, alpha=0.3)

    # ---- Plot 2: converter output vs ideal ------------------------------
    ax[1].plot([0, full_scale], [0, full_scale], "k--",
               alpha=0.4, label="ideal y=x")
    ax[1].plot(inputs, sar_out, ".", markersize=2, alpha=0.6, label="SAR output")
    ax[1].plot(inputs, cnt_out, ".", markersize=2, alpha=0.6, label="Counter output")
    ax[1].set_xlabel("input value")
    ax[1].set_ylabel("converter output")
    ax[1].set_title("Transfer characteristic (closer to dashed line = better)")
    ax[1].legend(loc="lower right")
    ax[1].grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig("s2b_compare.png", dpi=140)
    plt.savefig("s2b_compare.pdf")
    print("  wrote s2b_compare.png and s2b_compare.pdf")

    # ---- Plot 3: error CDF -- shows percentile distribution -------------
    fig2, ax2 = plt.subplots(figsize=(8, 5))
    sar_sorted = np.sort(sar_err)
    cnt_sorted = np.sort(cnt_err)
    pct = np.arange(1, N + 1) / N * 100.0
    ax2.plot(sar_sorted, pct, label="SAR", linewidth=1.5)
    ax2.plot(cnt_sorted, pct, label="Counter", linewidth=1.5)
    ax2.set_xlabel("absolute error (LSB)")
    ax2.set_ylabel("CDF (% of sweep points <= error)")
    ax2.set_title("Error CDF -- higher curve = more accurate converter")
    ax2.legend(loc="lower right")
    ax2.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig("s2b_compare_cdf.png", dpi=140)
    print("  wrote s2b_compare_cdf.png")


if __name__ == "__main__":
    main()
