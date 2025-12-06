#!/usr/bin/env bash 

set -euo pipefail

# === BASE CONFIGURATION ===

CLI="./src/megabytes-cli"

# Node 1 (honest)
DATADIR1="/tmp/mgb-node1"
RPCPORT1=8332

# Node 2 (attacker)
DATADIR2="/tmp/mgb-node3"
RPCPORT2=8334

RPCUSER="megabytesrpc"
RPCPASS="pass"

# Node2 P2P port as seen by node1
P2P_NODE2="127.0.0.1:30000"

# Reward address
ADDR="mgbrt1qpmqssrmres0rtzdw7y2wkwfv49hru396gcuyux"

# Depth of the reorg to attempt (honest blocks to override)
FORK_DEPTH=6

# Total honest blocks mined before the attack
TOTAL_HONEST_BLOCKS=80

# Number of iterations for mining the private attack chain on node2
ITER_ATTACK=40

# Attack algo mode:
#   mono  = only one algorithm (R_algo very negative)
#   multi = biased multi-algo distribution (more realistic)
ATTACK_MODE="multi"

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

# Honest chain algo rotation: round-robin across 3 algos
pick_honest_algo() {
    local idx=$1
    case $(( idx % 3 )) in
        0) echo "scrypt" ;;
        1) echo "sha256d" ;;
        2) echo "kheavy80" ;;
    esac
}

# Attacker algo selection
pick_attack_algo() {
    case "$ATTACK_MODE" in
        mono)
            # Ultra-simple attack: 100% sha256d
            echo "sha256d"
            ;;
        multi|*)
            # Biased multi-algo attack:
            #   ~70% sha256d, 20% scrypt, 10% kheavy80
            local r=$(( RANDOM % 100 ))
            if   [ "$r" -lt 70 ]; then
                echo "sha256d"
            elif [ "$r" -lt 90 ]; then
                echo "scrypt"
            else
                echo "kheavy80"
            fi
            ;;
    esac
}

# === PHASE 0: BASIC CHECK ===

echo_header "[PHASE 0] Basic checks"

echo "[*] Checking that megabytesd is running on both nodes."
echo "[*] Node1 datadir=$DATADIR1 rpcport=$RPCPORT1"
echo "[*] Node2 datadir=$DATADIR2 rpcport=$RPCPORT2"
echo

# Simple RPC test
cli1 getblockcount >/dev/null
cli2 getblockcount >/dev/null
echo "[OK] RPC for node1 + node2 is working."

# === PHASE 1: Connect nodes + honest multi-algo chain ===

echo_header "[PHASE 1] Connecting nodes + mining honest multi-algo chain"

echo "[NODE1] addnode to node2 ($P2P_NODE2)"
cli1 addnode "$P2P_NODE2" "onetry" || true

echo "[NODE1] Mining $TOTAL_HONEST_BLOCKS honest blocks (scrypt / sha256d / kheavy80 mix)"

for ((i=1; i<=TOTAL_HONEST_BLOCKS; i++)); do
    algo=$(pick_honest_algo "$i")
    echo "[NODE1] HONEST block $i / $TOTAL_HONEST_BLOCKS algo=$algo"
    cli1 generatetoaddress 1 "$ADDR" 100 "$algo"
done

# Let node2 sync through P2P
sleep 3

h1=$(cli1 getblockcount)
h2=$(cli2 getblockcount)
echo "[INFO] After honest chain: node1=$h1, node2=$h2"

if (( h1 != h2 )); then
    echo "[WARN] node1 and node2 are not perfectly in sync (h1=$h1, h2=$h2)."
    echo "       Wait a bit or check your P2P configuration."
fi

if (( h1 <= FORK_DEPTH + 2 )); then
    echo "[ERROR] Height too low ($h1) to perform reorg of depth $FORK_DEPTH."
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

# === PHASE 2: Disconnect and rollback attacker to fork point ===

echo_header "[PHASE 2] Disconnect node2 + rollback to fork point"

echo "[NODE1] disconnectnode $P2P_NODE2"
cli1 disconnectnode "$P2P_NODE2" || true

sleep 2

echo "[NODE2] invalidateblock $bad_hash (reset to fork_h=$fork_h)"
cli2 invalidateblock "$bad_hash"

sleep 2

h2_after_inv=$(cli2 getblockcount)
best2=$(cli2 getbestblockhash)
echo "[INFO] Node2 after invalidate: height=$h2_after_inv best=$best2"

# === PHASE 3: Private attack chain mining on node2 ===

echo_header "[PHASE 3] Mining private attack chain on node2 (multi-algo for R_algo penalty)"

attack_miner_a() {
    echo "[ATTACK-A] Starting attack mining on node2"
    for ((i=1; i<=ITER_ATTACK; i++)); do
        local blocks
        blocks=$(rand_between 2)  # 1..2 blocks
        for ((b=1; b<=blocks; b++)); do
            algo=$(pick_attack_algo)
            echo "[ATTACK-A] round=$i local_block=$b algo=$algo"
            cli2 generatetoaddress 1 "$ADDR" 100 "$algo"
        done
        sleep "0.$(rand_between 5)"
    done
    echo "[ATTACK-A] Done."
}

attack_miner_b() {
    echo "[ATTACK-B] Starting attack mining on node2"
    for ((i=1; i<=ITER_ATTACK; i++)); do
        local blocks
        blocks=$(rand_between 2)
        for ((b=1; b<=blocks; b++)); do
            algo=$(pick_attack_algo)
            echo "[ATTACK-B] round=$i local_block=$b algo=$algo"
            cli2 generatetoaddress 1 "$ADDR" 100 "$algo"
        done
        sleep "0.$(rand_between 7)"
    done
    echo "[ATTACK-B] Done."
}

attack_miner_a &
PID_ATK_A=$!

attack_miner_b &
PID_ATK_B=$!

wait "$PID_ATK_A" "$PID_ATK_B"

sleep 2

h2_attack=$(cli2 getblockcount)
best2_attack=$(cli2 getbestblockhash)
echo "[INFO] Node2 after private attack mining: height=$h2_attack best=$best2_attack"

# === PHASE 4: Reconnect and observe FinalityV1/V2 behavior ===

echo_header "[PHASE 4] Reconnecting node2 → node1 and observing Finality V1/V2"

echo "[NODE1] addnode $P2P_NODE2 onetry"
cli1 addnode "$P2P_NODE2" "onetry" || true

echo
echo ">>> Watch node1's debug.log:"
echo "      tail -f $DATADIR1/regtest/debug.log | grep -E \"Finality|GhostDAG\""
echo
echo "Expected observations:"
echo "  - FinalityV2-isolation       (if chain is isolated in DAG)"
echo "  - FinalityV2-shadow + R_algo (R_work, R_blue, R_DAC, R_algo, score)"
echo "  - FinalityV2-score-veto      (bad-reorg-low-score if score << threshold)"
echo
echo "  - Finality V1 also logs:"
echo "      finality-blue / finality-work / bad-reorg-finalized"
echo
echo "[DONE] DAG + multi-algo attack scenario executed."
