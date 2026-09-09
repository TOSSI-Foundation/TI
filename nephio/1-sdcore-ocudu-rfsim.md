# SD-Core × OCUDU-RAN on Nephio — RF-Sim Deployment (hardware-free, 50-UE scale)

Intent-driven bring-up of the **sdcore-ocudu** stack — **SD-Core** control plane, **BESS** UPF
and an **OCUDU-RAN** gNB in **RF-simulation** mode — on a bare server via **Nephio** (Porch,
Config Sync) and **Cluster API**, then a **50-UE** RF-sim load against it. No radio hardware.

---

## 1. Bring up the stack (Nephio)

```bash
git clone https://github.com/TOSSI-Foundation/Nephio-Stack.git
cd Nephio-Stack

make prereqs                                     # pinned toolchain (go, kustomize, clusterctl, kpt)
make mgmt                                         # Canonical K8s + CAPI + BYOH + Nephio + Gitea
make publish                                      # operator + blueprints + auto-approver + IPAM
make gnb-image OCUDU_SRC=<path-to-ocudu-clone>    # OCUDU gNB image (needed for the ran: site)
```

Declare the edge site in `fleet.yaml` — `role: cp+upf` with an RF-sim OCUDU gNB (`device: zmq`),
so Nephio deploys the gNB too:

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
        device: zmq          # RF simulator — Nephio deploys the OCUDU gNB, no hardware
```

```bash
make sites                                        # registers host + reconciles the fleet
kubectl get edgesites,clusters                    # wait until the site's cluster is Ready
```

## 2. Provision 50 subscribers (SIMs)

Generate 50 `Subscriber` CRs matching the rfsim UEs (`IMSI_BASE=100000000`, same K/OPc), then apply:

```bash
: > subscribers-50.yaml
for i in $(seq 1 50); do
  imsi=$(printf "00101%010d" $((100000000 + i)))
  cat >> subscribers-50.yaml <<EOF
---
apiVersion: sdcore.nephio.io/v1alpha1
kind: Subscriber
metadata: { name: sub-$imsi, namespace: default }
spec:
  imsi: "$imsi"
  key: "5122250214c33e723a5dd523fc145fc0"
  opc: "981d464c7c52eb6e5036234984ad0bcf"
  sliceRef: <slice-name>          # the site's slice (see: kubectl get networkslices)
EOF
done
kubectl apply -f subscribers-50.yaml
kubectl get subscribers.sdcore.nephio.io -n default
```

## 3. Run the 50-UE RF-sim load

The OCUDU gNB is the one **Nephio deployed** above (`device: zmq`). Only the UE binaries come
from the OCUDU-RAN rfsim testbed — build/setup per
**https://tossi.org/docs/ran-integration/rfsim-testbed/** (`~/rfsim_ocudu/`).

```bash
# 50 RF-sim UEs — IMSI_BASE + K/OPc match the subscribers above; -D = core/gNB LAN IP:
cd ~/rfsim_ocudu/OCUDU-RAN
sudo IMSI_BASE=100000000 UE_KEY=5122250214c33e723a5dd523fc145fc0 UE_OPC=981d464c7c52eb6e5036234984ad0bcf \
     NSSAI_SST=1 NSSAI_SD=0x102030 DNN=internet \
     ./rfsim_multi_ue.sh -a ~/rfsim_ocudu/OAI-RAN/ -n 50 -b 40 -s 12 -t 12 \
     -D <core-lan-ip> -o /tmp/ue50.csv -O /tmp/ue50.txt -F /tmp/ue50_failed.log
```

`-n 50` UEs · `-b 40` MHz. Results: `/tmp/ue50.csv` (per-UE attach/PDU), `/tmp/ue50_failed.log`.

```bash
sudo ./rfsim_multi_ue.sh -k          # stop the UEs
```

### Alternative — cp+upf via Nephio, gNB run standalone

If you brought up **only core + UPF** with Nephio (`role: cp+upf` **without** a `ran:` block —
SD-Core control plane + BESS UPF), start the rfsim gNB standalone **before** launching the UEs:

```bash
# rfsim gNB (points at the SD-Core AMF/N2):
cd ~/rfsim_ocudu/OCUDU-RAN/build/apps/gnb
sudo ./gnb -c ../../../configs/gnb_rfsim_sdcore.yaml
```

## 4. Teardown

```bash
make down                # delete fleet → CAPI deprovisions the cluster → hosts wiped pristine
```
