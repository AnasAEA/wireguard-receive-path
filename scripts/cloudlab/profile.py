"""WireGuard receive-path measurement testbed (Inria KrakOS / project WG).

Two bare-metal x86 nodes joined by a private 10 GbE link:

    gen  ----[ 10G link, 192.168.1.0/24 ]----  dut

  * dut  -- Device Under Test. Runs the patched (or stock) WireGuard module,
            bpftrace / perf instrumentation, and is where every per-step cost
            on the receive path is measured.
  * gen  -- Load generator. Pushes encrypted UDP toward the dut so its receive
            softirq / decrypt workqueue actually runs (unlike M1 loopback,
            which never saturates NET_RX_SOFTIRQ).

Multi-peer scaling is layered on top with Linux network namespaces on the gen
node (same method as the M1 harness), so we do not need N physical clients.

Hardware: c220g2 (Wisconsin) -- 2x E5-2660 v3, 160 GB RAM, Intel X520 10GbE.
Edit HW_TYPE / DISK_IMAGE below if c220g2 is unavailable when you instantiate.

Paste this into CloudLab "Create Profile -> Edit Code", name it
wg-recv-measure, Project = WG, then Create.
"""

import geni.portal as portal
import geni.rspec.pg as rspec

HW_TYPE    = "c220g2"
DISK_IMAGE = "urn:publicid:IDN+emulab.net+image+emulab-ops//UBUNTU22-64-STD"
LINK_SUBNET = "192.168.1.0"
LINK_MASK   = "255.255.255.0"

pc = portal.Context()
pc.defineParameter("hwtype", "Hardware type",
                   portal.ParameterType.NODETYPE, HW_TYPE)
params = pc.bindParameters()

request = pc.makeRequestRSpec()

# Private experiment LAN between the two nodes.
link = request.LAN("recvlan")
link.bandwidth = 10000000  # 10 Gbps, in Kbps

for i, name in enumerate(["dut", "gen"]):
    node = request.RawPC(name)
    node.hardware_type = params.hwtype
    node.disk_image = DISK_IMAGE

    iface = node.addInterface("eth1")
    iface.addAddress(rspec.IPv4Address("192.168.1.%d" % (i + 1), LINK_MASK))
    link.addInterface(iface)

    # Common toolchain for building the module + instrumenting the path.
    node.addService(rspec.Execute(shell="bash",
        command="sudo apt-get update && "
                "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "
                "build-essential bpftrace linux-tools-common linux-tools-$(uname -r) "
                "linux-headers-$(uname -r) wireguard-tools git python3-pip"))

pc.printRequestRSpec(request)
