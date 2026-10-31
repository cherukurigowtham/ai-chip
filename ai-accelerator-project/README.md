# Memory-Efficient Systolic Array Accelerator

An engineering research project designing and benchmarking a memory-efficient AI accelerator architecture to overcome the **Memory Bandwidth Bottleneck** in Deep Learning workloads.

---

## 1. Problem Statement
In conventional AI accelerators, Multiply-Accumulate (MAC) units repeatedly access operands (weights, activations, and partial sums) from memory. Because external data movement consumes hundreds of times more energy and suffers from restricted bus bandwidth compared to on-chip arithmetic, MAC units frequently stall, reducing computational efficiency and wasting energy.

## 2. Architectures Under Comparison

### Architecture A — Baseline (Naive Shared-Memory MAC)
* Flat computation with $N_{\text{mac}}$ parallel units.
* No Processing-Element (PE) level data reuse.
* Every scalar MAC operation fetches activation $A[i, k]$, weight $B[k, j]$, and reads/writes partial sum $C[i, j]$ directly from/to shared memory.
* High memory bandwidth pressure, low operational intensity.

### Architecture B — Optimized (Tiled Systolic Array with Local Data Reuse)
* 2D spatial grid of Processing Elements ($R \times C$).
* **Weight-Stationary (WS)** dataflow: Weights are pinned in local flip-flop registers inside each PE for repeated reuse across batches.
* **Systolic Activation Forwarding**: Activations stream horizontally from neighbor to neighbor without re-reading from memory.
* **Local In-PE Accumulation**: Partial sums accumulate in dedicated output registers and are only written out to memory once the entire reduction is complete.
* External memory accesses reduced by a factor proportional to the array tile dimensions.

---

## 3. Evaluation Metrics
1. **Total Memory Accesses**: Count of scalar reads and writes to external memory.
2. **Data Reuse Factor**: $\frac{\text{Total MAC Operations}}{\text{Unique External Memory Words Loaded}}$.
3. **Execution Cycles**: Total clock cycles required to complete matrix multiplication ($C = A \times B$).
4. **MAC Utilization (%)**: $\frac{\text{Active MAC Cycles}}{\text{Total Available MAC Capacity Cycles}} \times 100\%$.
5. **Estimated Energy (pJ / $\mu$J)**: Modelled using validated standard CMOS energy metrics (Horowitz, ISSCC 2014).

---

## 4. Project Structure
```
ai-accelerator-project/
│
├── baseline/
│   └── baseline.py          # Cycle-accurate baseline simulator (Architecture A)
│
├── optimized/
│   └── systolic_array.py    # Cycle-accurate systolic array simulator (Architecture B)
│
├── experiments/
│   └── benchmark.py         # Comparative benchmarking and evaluation harness
│
├── results/                 # Metrics CSVs, comparison logs, and generated plots
│
└── README.md
```
