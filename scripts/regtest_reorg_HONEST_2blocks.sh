#!/usr/bin/env bash
set -euo pipefail

CLI="./src/megabytes-cli"

DATADIR1="/tmp/mgb-node1"
DATADIR2="/tmp/mgb-node3"

RPCPORT1=8332
RPCPORT2=8334

RPCUSER="megabytesrpc"
RPCPASS="pass"

P2P_NODE2="127.0.0.1:30000"

ADDR="mgbrt1qpmqssrmres0rtzdw7y2wkwfv49hru396gcuyux"

# Target reorg depth
FORK_DEPTH=2

# Initial blocks mined by node1
TOTAL_HONEST_BLOCKS=60

# Number of “shared” blocks mined by Node2 (to avoid isolated-DAG)
SHARED_BLOCKS=8

# Size of the new honest branch mined by Node2
ITER_HONEST_BRANCH=12


cli1() { $CLI -regtest -datadir="$DATADIR1" -rpcport="$RPCPORT1" -rpcuser="$RPCUSER" -rpcpassword="$RPCPASS" "$@"; }
cli2() { $CLI -regtest -datadir="$DATADIR2" -rpcport="$RPCPORT2" -rpcuser="$RPCUSER" -rpcpassword="$RPCPASS" "$@"; }

echo_header() {
    echo
    echo "============================================================"
    echo "$@"
    echo "============================================================"
}

pick_algo() {
    local i=$1
    case $((i % 3)) in
        0) echo "scrypt" ;;
        1) echo "sha256d" ;;
        2) echo "kheavy80" ;;
    esac
}

safe_generate_node2() {
    local algo="$1"
    for attempt in 1 2 3 4 5; do
        if cli2 generatetoaddress 1 "$ADDR" 100 "$algo" >/tmp/mgb-gen2.log 2>&1; then
            return 0
        fi

        if grep -q "duplicate" /tmp/mgb-gen2.log; then
            echo "[WARN] duplicate block → retrying in 2s..."
            sleep 2
            continue
        fi

        echo "[ERROR] block generation failed:"
        cat /tmp/mgb-gen2.log
        exit 1
    done

    echo "[ERROR] unable to mine a non-duplicate block."
    exit 1
}


# === PHASE 1: Honest blockchain from Node1 ===
echo_header "[PHASE 1] Node1 mines the main honest chain"

cli1 getblockcount >/dev/null
cli2 getblockcount >/dev/null

for ((i=1; i<=TOTAL_HONEST_BLOCKS; i++)); do
    algo=$(pick_algo "$i")
    echo "[NODE1] block $i algo=$algo"
    cli1 generatetoaddress 1 "$ADDR" 100 "$algo"
done

sleep 2

# Connect Node2 to Node1
cli1 addnode "$P2P_NODE2" "onetry" || true
sleep 2

# === PHASE 2: Node2 mines shared blocks ===
echo_header "[PHASE 2] Node2 mines $SHARED_BLOCKS shared blocks while connected"

for ((i=1; i<=SHARED_BLOCKS; i++)); do
    algo=$(pick_algo "$i")
    echo "[NODE2] SHARED block $i algo=$algo"
    safe_generate_node2 "$algo"
    sleep 1
done

sleep 2

# At this stage Node1 and Node2 share a DAG base
h1=$(cli1 getblockcount)
h2=$(cli2 getblockcount)
echo "[INFO] After shared blocks: node1=$h1 node2=$h2"

# === PHASE 3: Fork preparation ===
tip=$h2
fork_h=$((tip - FORK_DEPTH))
bad_h=$((fork_h + 1))

fork_hash=$(cli2 getblockhash "$fork_h")
bad_hash=$(cli2 getblockhash "$bad_h")

echo_header "[PHASE 3] Disconnect and prepare the fork"

cli1 disconnectnode "$P2P_NODE2" || true
sleep 2

cli2 invalidateblock "$bad_hash"
sleep 2  # required to avoid duplicate block errors

# === PHASE 4: Node2 produces an honest alternative chain ===
echo_header "[PHASE 4] Node2 mines the honest alternative branch"

for ((i=1; i<=ITER_HONEST_BRANCH; i++)); do
    algo=$(pick_algo "$i")
    echo "[NODE2] HONEST alt block $i algo=$algo"
    safe_generate_node2 "$algo"
done

sleep 2

# === PHASE 5: Reconnection & V2 validation ===
echo_header "[PHASE 5] Reconnect → Node1 should ACCEPT the honest reorg"

cli1 addnode "$P2P_NODE2" "onetry" || true

echo
echo "Monitor node1's debug.log:"
echo "    tail -f $DATADIR1/regtest/debug.log | grep -E \"Finality|shadow|DAG\""
echo
echo "You should see:"
echo "  - NO isolated-DAG detection"
echo "  - R_algo ≈ 0"
echo "  - R_work > 0"
echo "  - Score >= MinScore → honest reorg ACCEPTED"
