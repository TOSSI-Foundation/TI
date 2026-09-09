# SD-Core × OCUDU-RAN on Nephio — Split-8 Deployment (real USRP SDR)

Intent-driven bring-up of the **sdcore-ocudu** stack with an **OCUDU-RAN** gNB driving a real
**USRP** over **split 8** (SDR driven directly), on a bare server, via **Nephio** and
**Cluster API**. A real UE attaches over the air.

---
## Architecture

**Under the hood** — Nephio Core's CRDs (Resources, Inventory, Infrastructure, Config, Workload) and controllers reconcile the intent and actuate it onto the targets: the network functions, the workload clusters, the network fabric and Git.

<img width="1920" height="1080" alt="43" src="https://github.com/user-attachments/assets/ffc28e5e-b471-40b6-9108-e54b0bef31f8" />


## 1. Bring up the stack (Nephio)

```bash
git clone https://github.com/TOSSI-Foundation/Nephio-Stack.git
cd Nephio-Stack

make prereqs                                     # pinned toolchain (go, kustomize, clusterctl, kpt)
make mgmt                                         # Canonical K8s + CAPI + BYOH + Nephio + Gitea
make publish                                      # operator + blueprints + auto-approver + IPAM
make gnb-image OCUDU_SRC=<path-to-ocudu-clone>    # OCUDU gNB image (any ran: site needs it)
```

## 2. Split-8 config (`fleet.yaml` / `intent/mgmtcore.yaml`)

The gNB runs **split 8** when the site's `ran.split: "8"`. Set `device` + radio addressing to
match **your** USRP.

**Networked SDR (N310)** — in `fleet.yaml`:
```yaml
apiVersion: sdcore.nephio.io/v1alpha1
kind: Fleet
metadata: { name: fleet, namespace: default }
spec:
  sites:
    - server: <edge-ip>
      user: <login>
      role: cp+upf
      ran:
        split: "8"
        device: n310
        radioNic: <host-NIC-on-radio-L2>     # host NIC on the SDR data L2 (brought up jumbo, MTU 9000)
        radioAddr: <SDR-IP>                  # the N310's own address, e.g. 192.168.20.2
        # cell: { band: 78, dlArfcn: 621312, bandwidthMHz: 40, commonScs: 30, pci: 1 }
```

**USB SDR (b210 / x310)** — no `radioNic`/`radioAddr`:
```yaml
      ran:
        split: "8"
        device: b210          # or x310
```

**Colocated core on the mgmt server** — the same `ran:` block in `intent/mgmtcore.yaml`
(then deploy with `make mgmt-core` in step 4).

### Adapt to your radio

| Knob | Set to |
|---|---|
| `device` | `n310` (networked) · `b210` / `x310` (USB) |
| `radioNic` | (N310) host NIC wired to the SDR data plane — the operator builds a jumbo `radio0` macvlan on it |
| `radioAddr` | (N310) the SDR's IP |
| `cell.band` / `cell.dlArfcn` / `cell.bandwidthMHz` / `cell.commonScs` / `cell.pci` | your RF cell / band plan |

(N310 only) on the edge host, bring the radio NIC up and confirm the SDR is reachable:
```bash
sudo ip link set <radioNic> up mtu 9000
ping -c2 <radioAddr>
```

## 3. Deploy

```bash
make sites                       # reconcile the fleet site(s)
# …or a colocated core on the mgmt server itself:
make mgmt-core
kubectl get edgesites,clusters   # wait until the site's cluster is Ready
```

## 4. Verify (real UE)

```bash
# on the edge host — gNB cell up, N2 connected, core + UPF running:
sudo k8s kubectl get pods -n default | grep -E 'gnb|upf|amf'
sudo k8s kubectl logs -n default deploy/gnb-<site>     # "cell started", N2 to AMF completed
```

Insert the provisioned SIM in a COTS phone → it registers on the gNB, establishes a PDU
session, and reaches the internet (verify with a ping from the UE).

## 5. Teardown

```bash
make down                # delete fleet → CAPI deprovisions the cluster → hosts wiped pristine
```
