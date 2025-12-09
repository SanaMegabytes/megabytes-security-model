# Megabytes — Eclipse-Resistant P2P Design

Megabytes is designed to reduce the risk of network-level isolation (“eclipse attacks”).  
The P2P layer is largely inherited from Bitcoin Core / DigiByte (addrman, netgroups, feelers, anchors, extra block-relay peers, etc.), and we add a small, explicit rule on top for extra protection.

---

## 1. Outbound Peer Diversity (Inherited Behavior)

Megabytes keeps the same core ideas as Bitcoin to make outbound connections harder to monopolize:

- The node maintains a limited set of:
  - **Full-relay outbound peers**
  - **Block-relay-only outbound peers**
- Outbound peers are selected using **addrman** and **netgroups**:
  - IPv4/IPv6 addresses are grouped into network groups (roughly `/16` for IPv4).
  - The node avoids opening several outbound connections in the same group.
- **Feeler connections** and **extra block-relay connections** are used periodically to:
  - Probe new peers and refresh addrman.
  - Detect better / more up-to-date chains.
  - Make long-term eclipse attacks harder.

This gives Megabytes the same class of eclipse resistance as modern Bitcoin Core by default.

---

## 2. Megabytes Addition: Inbound IPv4 `/24` Limit

On top of the inherited protections, Megabytes adds a simple inbound rule:

Implementation excerpt:

```cpp
static constexpr int MAX_INBOUND_PER_SUBNET = 4;

if (TooManyInboundInSubnet(addr, MAX_INBOUND_PER_SUBNET)) {
    LogPrintf("Megabytes anti-eclipse: rejecting inbound peer from %s (subnet over limit)\n", addr.ToString());
    sock->Close();
    return;
}
```


> **Megabytes limits inbound IPv4 peers to a maximum of 4 connections per `/24` subnet.**

**What it means**

- All addresses in `A.B.C.X` belong to the same `/24` subnet.
  - Example: `203.0.113.1`, `203.0.113.42`, `203.0.113.250` → same `/24`
- At most **4** inbound peers from that entire range can be connected at the same time.

**Goal**

- Prevent a single provider or attacker from filling all inbound slots using many IPs inside the same hosting block.
- Make large Sybil floods more expensive and more visible.

**High-level behavior**

- When a new inbound connection arrives:
  - The node counts how many existing **inbound** peers are already in the same IPv4 `/24`.
  - If count **≥ 4**, the new connection is **rejected immediately**.
- This rule:
  - Applies only to **inbound IPv4** peers.
  - Does **not** limit outbound connections (they already use netgroup-based diversity).

In the code, this is documented as:

> Megabytes anti-eclipse: limit inbound peers per IPv4 /24 subnet.

---

## 3. Tor / I2P / CJDNS Handling

Megabytes keeps Bitcoin’s philosophy for privacy networks:

- Tor, I2P and CJDNS peers are **not** grouped using IPv4/IPv6 subnet logic.
- Their **addrman groups are randomized** by design.
- The `/24` inbound limit is currently applied only to **IPv4**.

**Reason**

- For privacy networks, IP subnet structure is not meaningful in the same way as public IPv4.
- Randomized addrman groups already avoid “all peers from the same origin” patterns.

---

## 4. Summary: What Is Inherited vs Added

**Inherited from Bitcoin Core / DigiByte**

- Addrman + netgroup-based outbound diversity.
- Feeler connections.
- Extra block-relay-only connections for stale-tip detection.
- Anchor peers.
- General connection limits, eviction rules, and misbehavior logic.

**Added by Megabytes**

- A targeted inbound rule:

  - **Max 4 inbound IPv4 peers per `/24` subnet.**

This rule is intentionally:

- Simple to audit and document.
- Safe for a young network.
- Complementary to the existing Bitcoin-style protections rather than replacing them.
