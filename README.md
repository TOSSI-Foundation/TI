# TI - TOSSI integration guides

What happens when you take open 5G software and make it do something it could not do before.

Each guide here is a complete account of one integration: what stood in the way, what we
changed, and how to reproduce it.

## Guides

### IMS on SD-Core with Kamailio, joined by SETU

**[`CORE/sdcore-ims/`](CORE/sdcore-ims/)**

SD-Core is an open 5G standalone core. Kamailio is an open IMS. Side by side they still
cannot make a phone call, because nothing connects them and nothing in 3GPP describes what
that connection should look like. This guide builds it.

The result is a working voice service - calls, video calls and text messages on commercial
handsets over a real radio, with no HSS, policy server or SMS centre anywhere in the
deployment. Subscriber keys never leave the core.

Includes [`build-nf-images.sh`](CORE/sdcore-ims/build-nf-images.sh), which builds all four
components - the three modified network functions and the SETU bridge - in one command. You
do not clone or check out anything yourself.

→ **[Read the guide](CORE/sdcore-ims/1-sdcore+kamailio-ims_readme.md)**

### An eBPF user plane for SD-Core - metering and quota in the kernel

**[`CORE/ebpf/`](CORE/ebpf/)**

Replacing SD-Core's default userspace user plane with eUPF, an eBPF/XDP datapath, and adding
usage reporting: subscriber traffic is measured and capped inside the Linux kernel, with the
cap set from the SMF and enforced per subscriber.

→ **[Read the guide](CORE/ebpf/1-sdcore+eupf_readme.md)**

### Deploying SD-Core + OCUDU-RAN with Nephio

**[`nephio/`](nephio/)**

Standing up a private 5G network by hand is a long chain of coupled, drift-prone steps. This
turns the whole stack — SD-Core control plane, BESS UPF and an OCUDU-RAN gNB — into a single
declarative intent. A management cluster runs Nephio; you apply one `EdgeSite`/`Fleet` object
and the operator provisions the cluster (Cluster API + BYOH), renders the packages (Porch) and
reconciles them onto the edge (Config Sync). Addressing, the slice, subscribers and the
N2/N3/N4/N6 datapath are derived from intent — no per-site scripting.

- → **[RF-sim deployment - hardware-free, 50-UE scale](nephio/1-sdcore-ocudu-rfsim.md)**
- → **[Split-8 deployment - real USRP SDR](nephio/2-sdcore-ocudu-split8.md)**

## Component repositories

**IMS on SD-Core**

| Component | Repository | Branch |
|---|---|---|
| SMF - sessions and bearers | https://github.com/TOSSI-Foundation/sdcore-smf | `setu-ims-rel1` |
| PCF - policy and media authorization | https://github.com/TOSSI-Foundation/sdcore-pcf | `setu-ims-rel1` |
| AMF - mobility, hardened | https://github.com/TOSSI-Foundation/sdcore-amf | `setu-ims-rel1` |
| SETU - the signalling bridge | https://github.com/coranlabs/SETU | `main` |

Each `setu-ims-rel1` branch begins with the untouched upstream tree as its first commit, so
the difference between upstream and ours is one `git diff` away.

**eBPF user plane**

| Component | Repository | Branch |
|---|---|---|
| SMF with usage reporting and per-subscriber accounting | https://github.com/TOSSI-Foundation/sdcore-smf | `ebpf-urr` |
| eUPF with XDP metering and a live dashboard | https://github.com/TOSSI-Foundation/eUPF | `urr` |

The SMF carries both integrations as sibling branches off the same repository: `setu-ims-rel1`
for IMS, `ebpf-urr` for the eBPF user plane.

**Nephio deployment**

| Component | Repository | Branch |
|---|---|---|
| Nephio-Stack - operator, blueprints, bootstrap | https://github.com/TOSSI-Foundation/Nephio-Stack | `main` |

One stack (`sdcore-ocudu`) shipped as versioned releases; the core and RAN are Nephio
blueprints, so further 5G-core + RAN combinations follow as their own release lines.
