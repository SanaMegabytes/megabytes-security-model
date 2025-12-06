#!/usr/bin/env bash

set -euo pipefail

# === CONFIGURATION ===

CLI="./src/megabytes-cli"

# Honest node
DATADIR1="/tmp/mgb-node1"
RPCPORT1=8332

# Attacker node
DATADIR2="/tmp/mgb-node3"
RPCPORT2=8334

RPCUSER="megabytesrpc"
RPCPASS="pass"

# P2P port of node2 as seen from node1
P2P_NODE2="127.0.0.1:30000"

# Reward address (can be reused from your other tests)
ADDR="mgbrt1qpmqssrmres0rtzdw7y2wkwfv49hru396gcuyux"

# Target reorg depth (shallow, to stay in the "semi-honest" zone)
FORK_DEPTH=2

# Total honest blocks mined on node1 before the attack
TOTAL_HONEST_BLOCKS=80

# Shared blocks mined by node2 while connected (helps keep DAG non-isolated)
SHARED_BLOCKS=6

# Number of attack blocks mined privately on node2 (mono-algo)
ITER_ATTACK=10

# Attack mode:
#   mono  = 100% one algorithm (R_algo very negative)
ATTACK_MODE="mono"

# === HELPERS ===

cli1() {
    $CLI -regtest -datadir="$DATADIR1" -rpcport="$RPCPORT1" -rpcuser="$RPCUSER" -rpcpassword="$RPCPASS" "$@"
}

cli2() {
    $CLI -regtest -datadir="$DATADIR2" -rpcport="$RPCPORT2" -rpcuser="$RPCUSER" -rpcpassword="$RPCPASS" "$@"
}

echo_header() {
    echo
    echo "============================================================"
    echo "$@"
    echo "============================================================"
}

rand_between() {
    local max="$1"
    echo $(( (RANDOM % max) + 1 ))
}

# Honest chain algo rotation: round-robin across 3 algorithms
pick_honest_algo() {
    local idx=$1
    case $(( idx % 3 )) in
        0) echo "scrypt" ;;
        1) echo "sha256d" ;;
        2) echo "kheavy80" ;;
    esac
}

# Attacker algo selection (mono-only here)
pick_attack_algo() {
    case "$ATTACK_MODE" in
        mono|*)
            # Simple mono-algo attack: 100% sha256d
            echo "sha256d"
            ;;
    esac
}

# Robust generator for node2 that retries on "duplicate" errors
safe_generate_attack() {
    local algo="$1"
    for attempt in 1 2 3 4 5; do
        if cli2 generatetoaddress 1 "$ADDR" 100 "$algo" >/tmp/mgb-attack.log 2>&1; then
            return 0
        fi

        if grep -q "duplicate" /tmp/mgb-attack.log; then
            echo "[WARN] duplicate block on node2 → retrying in 2s..."
            sleep 2
            continue
        fi

        echo "[ERROR] attack block generation failed:"
        cat /tmp/mgb-attack.log
        exit 1
    done

    echo "[ERROR] unable to mine a non-duplicate attack block on node2."
    exit 1
}

# === PHASE 0: Basic checks ===

echo_header "[PHASE 0] Basic checks"

echo "[*] Checking that megabytesd is running on both nodes."
echo "[*] Node1 datadir=$DATADIR1 rpcport=$RPCPORT1"
echo "[*] Node2 datadir=$DATADIR2 rpcport=$RPCPORT2"
echo

cli1 getblockcount >/dev/null
cli2 getblockcount >/dev/null
echo "[OK] RPC for node1 + node2 is working."

# === PHASE 1: Honest multi-algo chain on node1 ===

echo_header "[PHASE 1] Connecting nodes + mining honest multi-algo chain on node1"

echo "[NODE1] addnode → node2 ($P2P_NODE2)"
cli1 addnode "$P2P_NODE2" "onetry" || true

echo "[NODE1] Mining $TOTAL_HONEST_BLOCKS honest blocks (scrypt / sha256d / kheavy80)"

for ((i=1; i<=TOTAL_HONEST_BLOCKS; i++)); do
    algo=$(pick_honest_algo "$i")
    echo "[NODE1] HONEST block $i / $TOTAL_HONEST_BLOCKS algo=$algo"
    cli1 generatetoaddress 1 "$ADDR" 100 "$algo"
done

sleep 3

# === PHASE 2: Node2 participates with shared blocks (still honest) ===

echo_header "[PHASE 2] Node2 mines $SHARED_BLOCKS shared blocks while connected (to avoid isolated-DAG)"

for ((i=1; i<=SHARED_BLOCKS; i++)); do
    algo=$(pick_honest_algo "$i")
    echo "[NODE2] SHARED block $i algo=$algo"
    safe_generate_attack "$algo"
    sleep 1
done

sleep 3

h1=$(cli1 getblockcount)
h2=$(cli2 getblockcount)
echo "[INFO] After shared blocks: node1 height=$h1, node2 height=$h2"

if (( h1 != h2 )); then
    echo "[WARN] node1 and node2 are not perfectly in sync (h1=$h1, h2=$h2)."
    echo "      Wait a bit more or check P2P connectivity if needed."
fi

if (( h1 <= FORK_DEPTH + 2 )); then
    echo "[ERROR] Height too low ($h1) to perform a reorg of depth $FORK_DEPTH."
    exit 1
fi

# Use the common honest tip as starting point
tip_h=$h1
fork_h=$(( tip_h - FORK_DEPTH ))
bad_h=$(( fork_h + 1 ))

fork_hash=$(cli2 getblockhash "$fork_h")
bad_hash=$(cli2 getblockhash "$bad_h")

echo "[INFO] tip_h=$tip_h, fork_h=$fork_h, bad_h=$bad_h"
echo "[INFO] fork_hash=$fork_hash"
echo "[INFO] bad_hash (will be invalidated on node2)=$bad_hash"

# === PHASE 3: Disconnect node2 and roll back to fork point ===

echo_header "[PHASE 3] Disconnect node2 + rollback to fork point"

echo "[NODE1] disconnectnode $P2P_NODE2"
cli1 disconnectnode "$P2P_NODE2" || true

sleep 3

echo "[NODE2] invalidateblock $bad_hash (reset to fork_h=$fork_h)"
cli2 invalidateblock "$bad_hash"

sleep 2

h2_after_inv=$(cli2 getblockcount)
best2=$(cli2 getbestblockhash)
echo "[INFO] Node2 after invalidate: height=$h2_after_inv best=$best2"

# === PHASE 4: Short private mono-algo attack chain on node2 ===

echo_header "[PHASE 4] Node2 mines short private mono-algo attack chain (R_algo penalty target)"

echo "[ATTACK] ATTACK_MODE=$ATTACK_MODE (mono: 100% sha256d)"

for ((i=1; i<=ITER_ATTACK; i++)); do
    algo=$(pick_attack_algo)
    echo "[ATTACK] attack block $i algo=$algo"
    safe_generate_attack "$algo"
    sleep "0.$(rand_between 5)"
done

sleep 2

h2_attack=$(cli2 getblockcount)
best2_attack=$(cli2 getbestblockhash)
echo "[INFO] Node2 after private attack mining: height=$h2_attack best=$best2_attack"

# === PHASE 5: Reconnect and observe R_algo / score veto ===

echo_header "[PHASE 5] Reconnect node2 → node1 and observe FinalityV2 (R_algo, score veto)"

echo "[NODE1] addnode $P2P_NODE2 onetry"
cli1 addnode "$P2P_NODE2" "onetry" || true

echo
echo ">>> Now, on node1, monitor debug.log with for example:"
echo "    tail -f $DATADIR1/regtest/debug.log | grep -E \"FinalityV2|score|algo|DAG\""
echo
echo "Expected behavior for this scenario (Option B):"
echo "  - Reorg depth ≈ $FORK_DEPTH (shallow, but >= MinDepthScore)."
echo "  - The DAG should NOT be fully isolated (dac_new > 0 in ideal case)."
echo "  - FinalityV2-shadow should log:"
echo "       R_work, R_blue, R_dac, R_algo, and global Score."
echo "  - Because the attack is mono-algo:"
echo "       R_algo should be strongly negative."
echo "  - If Score < MinScore → FinalityV2-score-veto:"
echo "       bad-reorg-low-score (score-veto based on R_algo + others)."
echo
echo "Finality V1 (blue + work) still runs as a secondary safety net:"
echo "  - finality-blue / finality-work / bad-reorg-finalized"
echo
echo "[DONE] Semi-honest mono-algo attack scenario (R_algo-focused) executed."
