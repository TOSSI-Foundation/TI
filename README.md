# TI - SD-Core × eUPF Integration

Integration work bringing **SD-Core** (open-source 5G core) onto an **eBPF/XDP** user
plane (**eUPF**), with **URR** usage metering and in-kernel quota enforcement.

## Layout

| Path | Contents |
|---|---|
| [`ebpf/1-sdcore+eupf_readme.md`](ebpf/1-sdcore+eupf_readme.md) | **SD-Core + eUPF integration** - overview, what changed, architecture, deployment guide |

## Component repositories

- **SMF** (URR + per-subscriber accounting): https://github.com/Shiva-Marshall/sdcore-smf-urr-implemented
- **eUPF** (XDP URR datapath + dashboard): https://github.com/Shiva-Marshall/eUPF-enhanced

## Start here
→ **[`ebpf/1-sdcore+eupf_readme.md`](ebpf/1-sdcore+eupf_readme.md)** - the integration write-up and deployment guide.
