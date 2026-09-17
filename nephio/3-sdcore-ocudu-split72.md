# SD-Core × OCUDU-RAN on Nephio — Split-7.2 Deployment (real O-RU over Open Fronthaul)

Intent-driven bring-up of the **sdcore-ocudu** stack with an **OCUDU-RAN** gNB reaching a real
**O-RU** over **split 7.2** (Open Fronthaul / eCPRI), on a bare server, via **Nephio** and
**Cluster API**. A real UE attaches over the air.

---

## Architecture

**Under the hood** — Nephio Core's CRDs (Resources, Inventory, Infrastructure, Config, Workload) and controllers reconcile the intent and actuate it onto the targets: the network functions, the workload clusters, the network fabric and Git.

_(diagram — drag and drop the **Split-7.2 architecture** image here)_

## 1. Bring up the stack (Nephio)

```bash
git clone https://github.com/TOSSI-Foundation/Nephio-Stack.git
cd Nephio-Stack

make prereqs                                     # pinned toolchain (go, kustomize, clusterctl, kpt)
make mgmt                                         # Canonical K8s + CAPI + BYOH + Nephio + Gitea
make publish                                      # operator + blueprints + auto-approver + IPAM
make gnb-image OCUDU_SRC=<path-to-ocudu-clone>    # OCUDU gNB image (any ran: site needs it)
```

## 2. Split-7.2 config (`fleet.yaml` / `intent/mgmtcore.yaml`)

The gNB runs **split 7.2** when the site's `ran.split: "7.2"`. Add an `ofh:` block describing the
Open Fronthaul transport to **your** O-RU.

**O-RU over Open Fronthaul** — in `fleet.yaml`:
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
        split: "7.2"
        device: <o-ru-model>
        # cell: { band: 78, dlArfcn: 620736, bandwidthMHz: 100, commonScs: 30, pci: 1 }
        ofh:
          interface: "<fronthaul-vf-pci>"     # PCI addr of the DPDK fronthaul VF (vfio-pci)
          ruMac:  "<o-ru-mac>"                # the O-RU's MAC
          duMac:  "<du-vf-mac>"               # the DU (fronthaul VF) MAC
          vlanTag: <fronthaul-vlan>           # the O-RU's fronthaul VLAN (host VF must match)
```

**Colocated core on the mgmt server** — the same `ran:` block in `intent/mgmtcore.yaml`
(then deploy with `make mgmt-core` in step 3).

### Adapt to your O-RU

| Knob | Set to |
|---|---|
| `device` | your O-RU model |
| `ofh.interface` | PCI address of the fronthaul VF bound to `vfio-pci` |
| `ofh.ruMac` / `ofh.duMac` | the O-RU MAC / the DU (fronthaul VF) MAC |
| `ofh.vlanTag` | the O-RU's fronthaul VLAN |
| `cell.band` / `cell.dlArfcn` / `cell.bandwidthMHz` / `cell.commonScs` / `cell.pci` | your RF cell / band plan |

The operator does not own the fronthaul physics — on the edge host, prep the VF, VLAN and PTP
(placeholders below — substitute your own):
```bash
echo <n> | sudo tee /sys/class/net/<fronthaul-nic>/device/sriov_numvfs   # create the fronthaul VF(s)
sudo dpdk-devbind.py --bind=vfio-pci <fronthaul-vf-pci>                   # bind the VF to vfio-pci
sudo ip link set <fronthaul-nic> vf <vf-index> vlan <fronthaul-vlan>     # VF on the O-RU's fronthaul VLAN
sudo ptp4l -i <fronthaul-nic> -f <ptp.cfg> & sudo phc2sys -a -r          # lock PTP to the O-RU clock
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
# on the edge host — fronthaul up, gNB cell up, N2 connected, core + UPF running:
sudo k8s kubectl get pods -n default | grep -E 'gnb|upf|amf'
sudo k8s kubectl logs -n default deploy/gnb-<site>     # eCPRI fronthaul up, "cell started", N2 to AMF completed
```

Insert the provisioned SIM in a COTS phone → it registers on the gNB, establishes a PDU
session, and reaches the internet (verify with a ping from the UE).

## 5. Teardown

```bash
make down                # delete fleet → CAPI deprovisions the cluster → hosts wiped pristine
```
