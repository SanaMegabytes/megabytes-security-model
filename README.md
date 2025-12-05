# megabytes-security-model
Security model, finality rules, and reorg-resistance simulations for the Megabytes multi-algo PoW blockchain.

Megabytes is a multi-algorithm Proof-of-Work blockchain integrating a layered
security architecture designed to make deep chain reorganizations (≥ 3 blocks)
practically impossible unless an attacker controls a very large portion of the
global hashrate *across multiple algorithms simultaneously*.

**Simulations indicate that an attacker without ~80–90% of multi-algo hashrate cannot reliably perform reorgs ≥ 3 blocks.**

---

```mermaid
%%{init: {'theme':'default'}}%%
flowchart TD


    A[New competing chain detected] --> M{MHIS check}
    M -->|fail| R1[Reject: bad-reorg-mhis]
    M -->|pass| B{Reorg depth d}
    B -->|d < 3| F[No V2 veto → Evaluate with Finality V1]
    B -->|d ≥ 3| C{DAG isolation check}

    C -->|isolated| Z[Reject: bad-reorg-isolated-dag]
    C -->|not isolated| D{d ≥ MinDepthScore?}

    D -->|no| F
    D -->|yes| E[Compute R_work, R_blue, R_dac, R_algo and Score]

    E -->|Score < MinScore| Y[Reject: bad-reorg-low-score]
    E -->|Score ≥ MinScore| F

    F --> H{Finality V1 checks}
    H -->|fail| R2[Reject: bad-reorg-finalized]
    H -->|pass| G[Reorg accepted]


    %% === COLORS ===
    classDef danger fill:#ffcccc,stroke:#cc0000,stroke-width:2px;
    classDef warn fill:#fff3cd,stroke:#d39e00,stroke-width:1px;
    classDef safe fill:#d4edda,stroke:#155724,stroke-width:1px;
    classDef step fill:#cce5ff,stroke:#004085,stroke-width:1px;

    %% Apply colors
    class M,C,D,E,H step;
    class R1,R2,Y,Z danger;
    class G safe;
    class F warn;

```

---

This repository documents:

- The **threat model**;
- The **security layers** involved (PoW + DAG + MHIS + Finality V1 + Finality V2);
- The **parameters** and their rationale;
- The **attacker window** (≈ 2 blocks under realistic conditions);
- **Reproducible regtest simulations**.

It also provides reference shell scripts demonstrating how Megabytes responds to:

- Honest small reorgs,
- Deep private forks,
- Mono-algo attacks,
- Multi-algo biased attacks,
- DAG-isolated branches.

---

## 1. Repository description

This repository accompanies the Megabytes Core consensus engine by providing a
**transparent specification** of how chain finality is enforced, how reorgs are
evaluated, and how an attacker’s capabilities are bounded.

It is intended for:

- Protocol auditors
- Researchers studying reorg resistance
- Exchange integrators
- Node operators
- Contributors interested in network security

---

## 2. Threat model

This documentation focuses on **consensus-level safety**: preventing attackers from
rewriting history or performing deep double-spend attacks.

### The attacker is allowed to:

- Control a fraction `f` of global hashrate (possibly large);
- Concentrate effort on **one PoW algorithm** or distribute across many;
- Mine privately and publish a competing chain later;
- Attempt reorganizations of arbitrary depth;
- Stay connected or disconnected from the public DAG.

### Out of scope (for now)

The following are *not* addressed directly by this repository (though they may be
addressed in future Megabytes improvements):

- Network-layer attacks (eclipse attacks, BGP hijacking, ISP-level filtering);
- Very short-term mempool censorship or MEV competition (1–2 block horizon);
- Social attacks (sybil governance, bribery attacks, coordination failures).

These limitations **do not reduce reorg protection**; they merely specify the
boundary of what the consensus engine is responsible for.

---

## 3. Security layers

Megabytes uses a **multi-layer defense model**, where each layer protects against
attacks that slip past the previous one:

1. **Multi-Algorithm Proof-of-Work**

   - Several PoW algorithms contribute to total work.
   - DAG scoring penalizes unnatural multi-algo distributions (e.g. mono-algo attacks).

2. **GHOSTDAG-light (Blue Score)**

   - Provides a DAG-based “honest backbone”.
   - Helps detect branches inconsistent with the global mining graph.

3. **MHIS (Minimum Honest Intersection Set)**

   - Ensures any reorg must overlap significantly with the recent honest mining history.
   - Prevents long-range reorganizations even if they appear DAG-consistent.

4. **Finality V1: Blue Finality + Work Finality**

   - Rejects reorganizations that do not present sufficiently more accumulated work.
   - Blocks reorgs beyond finalized blue blocks.

5. **Finality V2: Isolation Detection + Score Veto**

   Applied for reorgs deeper than a configurable threshold.

   - **Isolated-DAG Veto**  
     If the new branch is DAG-isolated (dac_new ≈ 0), the reorg is rejected immediately.

   - **Score-based Veto**  
     For depth ≥ `nFinalityV2MinDepthScore`, the new chain must achieve

     ```
     Score >= MinScore
     ```

     where:

     ```
     Score = K_Work * R_work
           + K_Blue * R_blue
           + K_DAC  * R_dac
           + K_Algo * R_algo
     ```

     The score incorporates:

     - Work advantage (R_work),
     - DAG quality (R_dac),
     - Blue score consistency (R_blue),
     - Algorithm distribution similarity (R_algo).

   A branch that is too isolated, too mono-algo, or too poorly connected
   to the honest DAG cannot override history.

---

### Finality V1 vs Finality V2 (Practical Role)

Megabytes still includes the traditional Finality V1 layer  
(blue-finality + work-finality), inherited from the underlying chain.

In practice, however, deep reorg attempts never reach Finality V1 anymore,  
because **Finality V2 blocks them first**:

- **Depth ≥ 3** → isolated-DAG check (**hard veto**)  
- **Depth ≥ 5** → score threshold (**bad-reorg-low-score**)  

Finality V1 therefore acts as a **secondary safety net**,  
but **Finality V2 is the effective mechanism preventing deep reorganizations** under realistic assumptions.

---


## 4. Parameters (example configuration)

```cpp
nFinalityV2MaxDepth       = 100;
nFinalityV2MaxWindow      = 400;

dFinalityV2KWork          = 0.10;
dFinalityV2KBlue          = 0.20;
dFinalityV2UnitWork       = 1.0;

dFinalityV2KDAC           = 2.0;
nFinalityV2DACMinDepth    = 3;
dFinalityV2DACEps         = 1e-6;

dFinalityV2KAlgo          = 3.0;
dFinalityV2AlgoEps        = 1e-3;

nFinalityV2MinDepthScore  = 5;
dFinalityV2MinScore       = 0.5;
 ```

## Interpretation of parameters

- Reorgs deeper than 2 blocks are treated as suspicious.  
- For depth ≥ 3, DAG isolation may immediately veto the reorg.  
- For depth ≥ 5, the score threshold must be met.  
- A deep reorg must therefore be:
  - DAG-connected  
  - Work-dominant  
  - Realistic in algorithm distribution  
  - High-quality in all R_* metrics  

Without these, the reorg is rejected by V2.

---

### 5. Attacker window (≈ 2 blocks)

With these parameters:

#### ✔️ Honest reorgs (1–2 blocks)

These remain possible and represent normal PoW behavior:

- Two blocks found simultaneously,  
- Network delay,  
- Miner desynchronization.

#### ❌ Deep reorgs (≥ 3 blocks)

These face multiple barriers:

- If mined privately → **isolated-DAG ⇒ reject**
- If mined publicly:
  - Must **outwork** the honest chain,
  - Must maintain **DAG quality**,
  - Must preserve **realistic multi-algo ratios**,
  - Must pass **Finality V1 + Finality V2** scoring.

This provides **early practical finality** while preserving PoW decentralization.






---

## 7. Conditions of Veto

| Reorg depth | V2 checks                 | Outcome                                   | Notes |
|-------------|---------------------------|--------------------------------------------|-------|
| MHIS          | Always evaluated (all depths)    | Reject if MHIS window not satisfied         | Prevents long-range or history-divergent chains |
| d < 3       | No V2 veto                | Decided by PoW + Finality V1              | Honest reorg window |
| 3 ≤ d < 5   | DAG isolation only        | Reject if isolated                         | Blocks private forks |
| d ≥ 5       | Isolation + score checks  | Reject if isolated or Score < MinScore     | Requires strong attacker |

---



### 6. Regtest simulations (reproducible)

Scripts in the `scripts/` directory allow anyone to verify Megabytes’ security assumptions:

- **regtest_reorg_honest_2blocks.sh**  
  Simulates a small honest 1–2 block reorg.  
  **Expected:** *ACCEPTED by FinalityV1 + FinalityV2.*

- **regtest_attack_mono_algo_25blocks.sh**  
  Simulates a deep mono-algo attack.  
  **Expected:**  
  - **Isolated-DAG veto**, or  
  - **Score < MinScore**, leading to `bad-reorg-low-score`.

- **regtest_attack_multi_algo_biased.sh**  
  A subtle attack using an unrealistic algorithm distribution.  
  **Expected:** rejected unless the attacker controls overwhelming multi-algo hashrate.

- **regtest_reorg_isolated_dag_example.sh**  
  Demonstrates how a branch mined even partially offline becomes **isolated**  
  and is correctly rejected.

Each script prints **FinalityV2-\*** log lines and explains how to interpret them.

---

### 7. Future improvements

Areas under active research:

- Network-layer hardening (anti-eclipse mechanisms);
- Adaptive **MHIS** thresholds for stronger long-range protection;
- Advanced multi-algo anomaly detection (machine-learning assisted?);
- Optional stake-weighted finality overlays.

Megabytes’ philosophy is **progressive hardening**: transparent, incremental and empirically validated.


