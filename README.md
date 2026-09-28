# CXL Operator for Kubernetes

This is a Kubernetes Operator (built with the Ansible Operator SDK) that manages **secondary ENI attachments for EKS worker nodes** and **synchronizes external `EndpointSlices`** to enable cross-VPC routing without VPC peering.

The operator runs decoupled reconciliation loops around source-node provisioning and proxy exposure state:

1. **`eni_provisioner`** — watches `CiliumNode` resources (`cilium.io/v2`). For every node labeled `cxl.io/vpc-type=proxy` it:
   * extracts the EC2 instance ID from the node's `spec['instance-id']`,
   * reads the nodepool-injected subnet selector labels `cxl.io/subnet-tag-key` + `cxl.io/subnet-key-value` or `cxl.io/subnet-iids`,
   * resolves candidate remote subnets from those labels and picks the subnet matching the node's own subnet / availability zone,
   * attaches a secondary ENI from that remote subnet (idempotent via tags),
   * annotates the Kubernetes Node with `network.infrastructure.io/secondary-eni-ip: <eth1 private IP>`,
   * creates a one-shot **Bottlerocket** node initializer Job on that node which waits for `eth1`, assigns its address via AWS IMDSv2, and applies policy-based routing:
     ```bash
     ip route add default via <ETH1_GW> dev eth1 table 100
     ip rule add from <ETH1_IP> lookup 100
     echo 1 > /proc/sys/net/ipv4/conf/eth1/arp_ignore
     echo 2 > /proc/sys/net/ipv4/conf/eth1/arp_announce
     ```
2. **`service_sync`** — watches source `Service` objects labeled `cxl.io/service=proxy`. This is the source-of-truth reconciliation for naming and port intent: it derives the managed selectorless resource names as `<source-service>-cxl`, mirrors the watched Service port configuration, and ensures the managed selectorless EndpointSlice uses `kubernetes.io/service-name: <source-service>-cxl`.

3. **`endpoint_slice_sync`** — watches the original workload `EndpointSlice` objects behind the source Service so backend churn is reflected immediately. As HAProxy or other proxy pods come and go, this reconciliation resolves the owning source Service, keeps only ready backends, looks up the backing Nodes, reads their `network.infrastructure.io/secondary-eni-ip` annotation, and overwrites the managed selectorless EndpointSlice with those ENI IPs. When no pod is ready anymore the endpoints array is cleared so the AWS Load Balancer Controller drains traffic.

The result: an NLB in front of a selectorless Service named `<source-service>-cxl` routes traffic through secondary ENIs into the remote VPC — no VPC peering required, and L7 (pod) readiness directly drives L4 target registration.

### Architecture

```
EKS cluster                         Remote VPC
┌──────────────────────────────┐    ┌───────────────────────────┐
│ proxy pods (ready)           │    │  remote subnet            │
│   on nodes with a secondary  │◄───│  (secondary ENI subnet)   │
│   ENI (eth1)                 │    │  NLB target group (ip)    │
└──────────────────────────────┘    └───────────────────────────┘
        ▲                                    ▲
  │ service_sync + endpoint_slice_sync │ TargetGroupBinding (ip mode)
┌───────┴────────────────────────────────────┴────────────────┐
│ cxl-operator  (watches proxy CiliumNodes + Services +       │
│                 source EndpointSlices)                       │
│  eni_provisioner: EC2 ENI attach + node initializer Job     │
└─────────────────────────────────────────────────────────────┘
```

## Installation

The operator is packaged as an OCI Helm chart (plus the multi-arch container image).

```bash
helm upgrade --install cxl-operator oci://ghcr.io/k8stooling/charts/cxl-operator \
  --set awsRegion=us-east-1
```

(Optional) To restrict the operator to a single namespace:

```bash
helm upgrade --install cxl-operator oci://ghcr.io/k8stooling/charts/cxl-operator \
  --set watchNamespace="haproxy-remote"
```

Subnet selection is not a global operator setting in this version. The nodepool must inject one of these label forms onto the reconciled nodes:

| Labels | Meaning |
|-------|---------|
| `cxl.io/subnet-tag-key` + `cxl.io/subnet-key-value` | Select candidate secondary subnets by AWS tag. |
| `cxl.io/subnet-iids` | Comma-separated list of candidate subnet IDs. |

The operator uses those labels to discover candidate remote subnets and then picks the one matching the node's primary subnet / availability zone.

### Key values

| Value | Description |
|-------|-------------|
| `awsRegion` | AWS region of the EKS cluster / ENI subnet. |
| `aws.secretName` | *(optional)* Secret with static AWS credentials; otherwise the operator relies on the node's IAM role / instance profile. |
| `nodeInitializerImage` | Image for the node initializer Job (needs `iproute2` + `curl`). |
| `nodeInitializerJobNamespace` | Namespace for the initializer Jobs. Defaults to the operator namespace. |
| `kyvernoPolicyException.*` | Controls the Helm-managed Kyverno `PolicyException` allowing the initializer Jobs to bypass `psp-restricted` in policy `kyverno-policies-3.8.2`. |
| `targetSliceNamespace` | Namespace of the selectorless slice. Defaults to the triggered slice's namespace. |
| `watchNamespace` | Restrict the operator to one namespace. Empty = all. |

### Supporting manifests

The code path is not HAProxy-specific. Any Service using this pattern can be the source Service as long as it is labeled `cxl.io/service=proxy`.

The example manifests keep HAProxy-flavored names because that is the primary demonstration use case. Treat them as templates: the selectorless Service and managed EndpointSlice should use the source Service name with a `-cxl` suffix, and the selectorless Service port should stay aligned with the watched source Service port or `nodePort`.

Because backend churn happens on the original workload `EndpointSlice` objects rather than on the source Service itself, the full design uses both the `service_sync` role and the `endpoint_slice_sync` role against a shared reconciliation path.

## Development

```bash
# Build the image
make docker-build IMG=ghcr.io/k8stooling/cxl-operator:dev

# Multi-arch build & push (amd64 + arm64)
make docker-buildx
```

The GitHub Actions workflow publishes the image and Helm chart to GHCR on tags (`v*`) or manual dispatch.

## Testing

Molecule scenarios are provided under `molecule/`. The `default` scenario expects a kubeconfig and the `OPERATOR_IMAGE` environment variable:

```bash
export OPERATOR_IMAGE=ghcr.io/k8stooling/cxl-operator:dev
molecule test -s default   # or -s kind
```

> Note: reconciling `CiliumNode` objects requires Cilium to be installed in the
> test cluster; the ENI provisioning path additionally requires AWS credentials
> and nodepool-injected subnet selector labels on the reconciled nodes.