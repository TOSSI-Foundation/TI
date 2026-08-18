# IMS on SD-Core with Kamailio, joined by SETU: voice, video and messaging

A working voice service on an open 5G standalone core. Calls, video calls and text messages,
verified on commercial handsets over a real 5G SA radio - with no HSS, no policy server and
no SMS centre anywhere in the deployment.

---

## Why an open core and an open IMS cannot talk to each other

SD-Core is an open 5G standalone core. Kamailio is an open IMS. Both are good software, and
put side by side they still cannot make a phone call.

The reason is not a missing feature on either side. It is that nothing connects them, and
nothing in the 3GPP specifications describes what that connection should look like.

An IMS does not work out who a subscriber is on its own. It asks a database - the **HSS**,
or Home Subscriber Server - for the credentials it needs to challenge the handset and prove
the SIM is genuine. Nor does it decide by itself that a call deserves protected bandwidth:
it asks a **policy server**, which then instructs the network to reserve it. Both of those
conversations happen in Diameter, a protocol considerably older than 5G.

A 5G core holds the same information and makes the same decisions. It simply exposes them
as modern service APIs over HTTP/2 - `Nudr` for subscriber data, `N5` for media policy.

So the IMS asks questions the core can answer, in a language the core does not speak. Both
sides are specified to the byte; the translation between them is specified nowhere. That is
the gap this guide fills.

## How the three parts fit

| Part | What it does | What we changed |
|---|---|---|
| **SD-Core** | the 5G core - registration, sessions, policy, user plane | 25 files, three network functions |
| **Kamailio 6.1** | the IMS - all the SIP handling | nothing, one config line at each end |
| **SETU** | the bridge between them | - |
| **gNB and radio** | the access network | nothing, configuration only |

**SETU** presents the IMS with exactly the interfaces it already expects: an HSS on `Cx`,
a policy server on `Rx`. Kamailio has no idea it is talking to anything unusual, which is
why Kamailio needed no code changes at all.

Behind that familiar face, SETU answers from the 5G core. It reads subscriber key material
over `Nudr` and computes the authentication challenge itself, and it turns a media
authorization request into the service API call the core understands.

The consequence is worth stating plainly: **subscriber keys never leave the core.** There is
no second copy of anyone's credentials to provision, secure, or keep in step with the first.

## The network functions that changed

Three of SD-Core's network functions carry the voice work. Each is published as a branch off
its upstream release, and each repository's README explains its own changes in detail - that
is the place to read them.

| Function | Repository | Branch | What it learned to do |
|---|---|---|---|
| **SMF** (sessions) | [sdcore-smf](https://github.com/TOSSI-Foundation/sdcore-smf) | `setu-ims-rel1` | tell the handset where the IMS is; turn a policy decision into a real reserved-bandwidth channel a handset will accept |
| **PCF** (policy) | [sdcore-pcf](https://github.com/TOSSI-Foundation/sdcore-pcf) | `setu-ims-rel1` | match a call to the right subscriber's session; treat voice and video as guaranteed rather than best effort; release what it reserved |
| **AMF** (mobility) | [sdcore-amf](https://github.com/TOSSI-Foundation/sdcore-amf) | `setu-ims-rel1` | resilience only, no voice logic - one bad message must not take down every subscriber |

One rule held throughout: every change stays inside the network function it belongs to. No
forked shared libraries, and `go.mod` byte-identical to the upstream tag. That decides
whether this work survives - upgrading to a newer SD-Core release is a rebase, not a fresh
start.

Each branch begins with the untouched upstream tree as its first commit, so the difference
between upstream and ours is one `git diff` away.

**SETU** lives separately at [coranlabs/SETU](https://github.com/coranlabs/SETU), Apache-2.0.

## Building the images

You do not need to clone anything, check out a branch, or run four builds by hand.
[`build-nf-images.sh`](build-nf-images.sh) does all of it:

```bash
./build-nf-images.sh
```

That fetches the three network functions at `setu-ims-rel1` and SETU at `main`, then builds
`5gc-smf`, `5gc-pcf`, `5gc-amf` and `setu` - everything you need except Kamailio, which runs
stock from its own published image.

Useful variations:

```bash
./build-nf-images.sh --verify                 # confirm the voice changes are really in the binaries
./build-nf-images.sh --load-containerd        # load straight into k3s/rke2, no registry needed
./build-nf-images.sh -r ghcr.io/acme/ --push  # build and publish
./build-nf-images.sh --nf setu                # just the bridge
./build-nf-images.sh --nf smf --tag mytest    # one component, custom tag
./build-nf-images.sh --dry-run                # show the plan, change nothing
```

**It needs only `git` and `docker`.** The upstream Makefile vendors dependencies with Go
before building; if Go is not installed here, that step runs inside a `golang:1.25` container
instead, so the upstream build path is still what executes rather than something
reimplemented in this script.

`--verify` is worth running at least once. It reaches into each finished image, pulls the
binary back out, and checks that code which only exists because of the voice work is
actually present. That is the difference between "an image built" and "the right image
built", and it catches the most common mistake - building from the wrong branch.

Sources land in `.nf-build/` next to the script, which `.gitignore` excludes. Nothing the
build produces is ever committed.

## Deploying the stack

### The 5G core

Install SD-Core via aether-onramp as usual, then point the three deployments at your new
images. With `--load-containerd` they are already in the node's containerd:

```bash
for nf in smf pcf amf; do
  kubectl -n $CORE_NS set image deploy/$nf $nf=5gc-$nf:setu-ims-rel1
done
```

Three settings enable voice:

- **SMF** - `pcscfInfos.ipv4` set to the P-CSCF address, so it reaches the handset when the
  data session is set up. Without it a phone attaches happily and never registers for voice.
  Point the PFCP node-id at the UPF's Service ClusterIP so a UPF restart does not break the
  association.
- **UPF** (`upf.jsonc`) - `gtppsc: true`. Real base stations add a small header to user
  traffic; without this the forwarding element discards every packet from the handset.
- **PCF** - enable the SelfHeal orphan purge, so a call that ends badly does not leave
  reservations behind.

Restart the UPF adapter before the SMF, so the PFCP association re-forms in the right order:

```bash
kubectl -n $CORE_NS rollout restart deploy/upf-adapter deploy/smf
```

Provision subscribers through the omec `sub-provision` simapp with
`provision-network-slice: true` - key material, an MSISDN, a device group tied to the slice,
the `ims` data network for voice and `internet` for data.

### The IMS

Stock Kamailio 6.1 P-CSCF, I-CSCF and S-CSCF on host networking, with rtpengine anchoring
media and MySQL behind the S-CSCF. Ordinary IMS configuration throughout, with `av_mode=0`
on the S-CSCF so it takes real authentication vectors over `Cx` rather than computing them
locally.

The only change on this side is at the seam: point the **P-CSCF's Rx peer** at SETU on
`:3868`, and the **I-CSCF and S-CSCF Cx peers** at SETU on `:3869`. Nothing else.

### The bridge

```bash
git clone https://github.com/coranlabs/SETU.git && cd SETU
docker build -f deploy/Dockerfile.build -t setu:1.0 .
```

Configure it with the PCF and UDR addresses and the S-CSCF, then run it on host networking - 
it binds the Diameter ports and the SMS ingest. Give it a real stop timeout: SETU releases
what it holds when asked to shut down, and killing it too quickly leaves reservations
stranded on the core. Full configuration reference is in the SETU repository.

### The radio

Any 5G SA base station, no code changes. Point it at the AMF's N2 address, set the network
identity and slice to match, and bind the user-plane interface toward the UPF. Confirm the
setup handshake succeeds, then attach a provisioned SIM.

## Checking it works

| | Result |
|---|---|
| Registration | full challenge-and-response, no HSS on the network |
| Voice | dedicated reserved channel per call, released on hangup |
| Video | second reserved channel alongside voice |
| Messaging | both directions, plain text and emoji, with delivery reports |
| Teardown | clean across repeated calls, nothing accumulating |

```bash
kubectl -n $CORE_NS logs -f deploy/pcf   # media authorized and released, per call
kubectl -n $CORE_NS logs -f deploy/smf   # the reserved channel being set up
docker logs -f setu                      # REGISTER , AUDIO/VIDEO , SMS , CALL-END
docker logs -f pcscf 2>&1                # the SIP exchange
```

The single check that separates a working call from one that merely looks right: the
reserved channel must appear when the call starts **and disappear when it ends**. A channel
that comes up and stays is a call that never really hung up, and the residue builds until
calls start failing for reasons that look unrelated.

## Failures worth knowing about

Each of these cost us about a day.

**Reserving bandwidth of zero.** A reserved channel with no bandwidth figure attached is
still a reserved channel - the network sets it up, reports success, and the handset then
refuses the call because the guarantee it was promised never materialised.

**Two systems sharing one counter.** IMS and 5G authentication draw on the same anti-replay
counter. Use it without advancing it and the next attempt is rejected as a replay.
Registration then fails in a way that looks exactly like poor radio coverage.

**A user plane that fails in silence.** With `gtppsc` off, every packet from the handset is
discarded while the call setup, the reserved channel and every log you would think to check
all report success. A reserved channel carrying no audio looks precisely like a working call
that nobody can hear.

**Benign noise from Kamailio.** The P-CSCF logs to stderr and emits a steady stream of
timeouts from idle connections to sleeping handsets. These are not faults; filter them at
the viewing layer rather than chasing them.

**Locally-built images can be garbage-collected.** An eviction under disk pressure takes
voice down while data keeps working - a confusing failure. Keep images in a registry you
control.

## Reference

- **Bridge:** [coranlabs/SETU](https://github.com/coranlabs/SETU)
- **Network functions:** [sdcore-smf](https://github.com/TOSSI-Foundation/sdcore-smf)
  [sdcore-pcf](https://github.com/TOSSI-Foundation/sdcore-pcf)
  [sdcore-amf](https://github.com/TOSSI-Foundation/sdcore-amf) - all on `setu-ims-rel1`
- **Standards:** TS 29.214 (Rx), TS 29.228/29.229 (Cx), TS 29.514 (N5), TS 29.505 (Nudr),
  TS 24.501 (NAS/PCO), TS 24.011 / 23.040 (SMS), TS 38.413 (NGAP)

Built on SD-Core from the OMEC project and the Open Networking Foundation, deployed with
aether-onramp, and on Kamailio and rtpengine. Thanks to their maintainers.
