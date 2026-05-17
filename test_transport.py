#!/usr/bin/env python3
"""
Test transport forwarding through the XIAO ESP32-S3 transport node.

This script forces a path through the transport node by injecting a
path table entry, then sends a link request to the T-Deck destination.

Watch the transport node's serial output (tio) to see if the packet
is received as HEADER_2 and forwarded.

Usage:
    python3 test_transport.py

Prerequisites:
    - pip install rns
    - RNode connected via USB in HOST mode
    - Reticulum config (~/.reticulum/config) with RNode interface defined
    - Transport node (XIAO) and T-Deck both on air at 868.8 MHz
"""

import time
import sys
import threading
import RNS

# ─── Configuration ───────────────────────────────────
# Transport node identity hash (from boot log)
TRANSPORT_HASH = bytes.fromhex("aedb501fdb371b212b4392f2d91afad3")

# T-Deck probe destination hash (from announce)
TDECK_DEST_HASH = bytes.fromhex("3c0ffe733b5375dee4c5595cdbc66ad1")


def find_interface():
    """Find the first outbound-capable interface."""
    for iface in RNS.Transport.interfaces:
        if hasattr(iface, 'OUT') and iface.OUT:
            return iface
    return None


def show_path(dest_hash, label=""):
    """Print path info for a destination."""
    if RNS.Transport.has_path(dest_hash):
        hops = RNS.Transport.hops_to(dest_hash)
        nh = RNS.Transport.next_hop(dest_hash)
        print(f"  {label} path: {hops} hops, next_hop={nh.hex() if nh else 'None'}")
    else:
        print(f"  {label} path: NONE")


def inject_transport_path(dest_hash, transport_hash, interface, hops=2):
    """Force a path through a specific transport node."""
    entry = [
        time.time(),                    # 0: timestamp
        transport_hash,                 # 1: next_hop (transport node hash)
        hops,                           # 2: hops (>1 triggers HEADER_2)
        time.time() + 86400,            # 3: expires
        None,                           # 4: random blobs
        interface,                      # 5: outbound interface
        None,                           # 6: announce packet hash
    ]
    RNS.Transport.path_table[dest_hash] = entry
    print(f"  Injected: {dest_hash.hex()} -> via {transport_hash.hex()} ({hops} hops)")


def main():
    print("=" * 50)
    print("Transport Forwarding Test")
    print("=" * 50)

    # Start Reticulum
    print("\n[1] Starting Reticulum...")
    reticulum = RNS.Reticulum(loglevel=RNS.LOG_DEBUG)
    time.sleep(3)

    # Find interface
    iface = find_interface()
    if not iface:
        print("ERROR: No outbound interface found!")
        sys.exit(1)
    print(f"  Interface: {iface}")

    # Check current path state
    print("\n[2] Current paths:")
    show_path(TDECK_DEST_HASH, "T-Deck")

    # Wait for T-Deck announce if no identity known
    print("\n[3] Checking T-Deck identity...")
    identity = RNS.Identity.recall(TDECK_DEST_HASH)
    if identity is None:
        print("  No identity cached. Requesting path & waiting for announce...")
        RNS.Transport.request_path(TDECK_DEST_HASH)
        for i in range(30):
            identity = RNS.Identity.recall(TDECK_DEST_HASH)
            if identity:
                break
            time.sleep(1)
            if i % 5 == 4:
                print(f"  Waiting... ({i+1}/30)")

    if identity is None:
        print("  ERROR: Cannot recall T-Deck identity.")
        print("  The T-Deck must have announced at least once.")
        print("  Make sure T-Deck is on and has been running for a few minutes.")
        sys.exit(1)

    print(f"  Identity found: {identity}")

    # Expire any existing direct path
    print("\n[4] Forcing path through transport node...")
    if RNS.Transport.has_path(TDECK_DEST_HASH):
        print("  Expiring existing direct path...")
        RNS.Transport.expire_path(TDECK_DEST_HASH)
        if TDECK_DEST_HASH in RNS.Transport.path_table:
            del RNS.Transport.path_table[TDECK_DEST_HASH]
        time.sleep(0.5)

    # Inject forced path through transport node
    inject_transport_path(TDECK_DEST_HASH, TRANSPORT_HASH, iface, hops=2)
    show_path(TDECK_DEST_HASH, "T-Deck (forced)")

    # Send a link request - this will create a HEADER_2 packet
    print("\n[5] Sending link request to T-Deck via transport node...")
    print("  >>> WATCH THE TRANSPORT NODE SERIAL OUTPUT <<<")
    print("  You should see:")
    print("    [RX] with ht=1 (HEADER_2) and ti=aaacd99f...")
    print("    'We are designated next-hop'")
    print("    [TX] forwarding the packet")
    print()

    # We need to construct a destination with the right hash
    # Try common app_name/aspects combinations
    dest = RNS.Destination(
        identity,
        RNS.Destination.OUT,
        RNS.Destination.SINGLE,
        "lxmf",
        "delivery"
    )

    if dest.hash != TDECK_DEST_HASH:
        print(f"  Note: Constructed hash {dest.hash.hex()} != expected {TDECK_DEST_HASH.hex()}")
        print(f"  The T-Deck destination may use different app/aspects.")
        print(f"  Sending to constructed destination anyway (transport test still valid)...")

        # Re-inject path for the actual constructed destination hash
        inject_transport_path(dest.hash, TRANSPORT_HASH, iface, hops=2)

    # Create link
    link_result = {"established": False, "failed": False}

    def on_established(link):
        print(f"\n  LINK ESTABLISHED! RTT={link.rtt:.3f}s")
        link_result["established"] = True

    def on_closed(link):
        if not link_result["established"]:
            print(f"\n  Link failed: {link.teardown_reason}")
            link_result["failed"] = True

    link = RNS.Link(dest, established_callback=on_established, closed_callback=on_closed)
    print(f"  Link request sent to {dest.hash.hex()}")

    # Wait for result
    for i in range(30):
        if link_result["established"] or link_result["failed"]:
            break
        time.sleep(1)
        if i % 5 == 4:
            print(f"  Waiting for link... ({i+1}/30s)")

    if not link_result["established"] and not link_result["failed"]:
        print("  TIMEOUT - no response after 30s")
        print("  Check the transport node serial output to see what happened")

    # Show final state
    print("\n[6] Final path state:")
    show_path(TDECK_DEST_HASH, "T-Deck")

    # Keep alive briefly
    print("\nWaiting 10s for any delayed responses...")
    time.sleep(10)

    if link_result["established"]:
        link.teardown()

    print("\nDone.")


if __name__ == "__main__":
    main()
