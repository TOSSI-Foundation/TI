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

## Component repositories

**IMS on SD-Core**

| Component | Repository | Branch |
|---|---|---|
| SMF - sessions and bearers | https://github.com/TOSSI-Foundation/sdcore-smf | `setu-ims-rel1` |
| PCF - policy and media authorization | https://github.com/TOSSI-Foundation/sdcore-pcf | `setu-ims-rel1` |
| AMF - mobility, hardened | https://github.com/TOSSI-Foundation/sdcore-amf | `setu-ims-rel1` |
| SETU - the signalling bridge | https://github.com/coranlabs/SETU | `main` |

Every network function branch begins with the untouched upstream tree as its first commit,
so the difference between upstream and ours is one `git diff` away.

**eBPF user plane**

| Component | Repository |
|---|---|
| SMF with usage reporting and per-subscriber accounting | https://github.com/Shiva-Marshall/sdcore-smf-urr-implemented |
| eUPF with XDP metering and a live dashboard | https://github.com/Shiva-Marshall/eUPF-enhanced |
