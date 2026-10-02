# CXL Operator for Kubernetes

This is a Kubernetes Operator built with the Ansible Operator SDK. It manages a strict per-node egress path for proxy workloads: one secondary ENI, one node-local initialization Job, and one `CiliumEgressGatewayPolicy` per proxy node.

The operator currently exposes two steady-state reconciliation loops plus a cleanup finalizer:

1. `node_egress_provisioner` watches `CiliumNode` resources labeled `cxl.io/vpc-type=proxy`. For each matching node it resolves the EC2 instance, chooses the secondary subnet from node labels, creates or reuses a secondary ENI, stores the ENI ID and IP on the Kubernetes Node, stamps a deterministic `cxl.io/egress-gw` hash label, runs the Bottlerocket-compatible initializer Job, waits for Job success, removes the readiness taint, marks the node `cxl.io/egress-ready=true`, and applies a node-local `CiliumEgressGatewayPolicy`.
2. `pod_topology_labeler` watches Pods and patches the ones scheduled onto proxy nodes. Once a Pod is scheduled, it reads the scheduled node's `cxl.io/egress-gw` hash and only patches the Pod when the node is also labeled `cxl.io/egress-ready=true`.
3. `node_egress_cleanup` runs from the `cxl.io/eni-cleanup` finalizer on `CiliumNode` and tears down the ENI and matching egress policy when the node is being removed.

The target model is a strict 1:1 mapping: one proxy node, one secondary ENI, one gateway hash, one egress policy. That avoids cross-node or cross-AZ hops.

### Architecture

```text
proxy Pod --label--> cxl.io/egress-gw=<hash>
  |
  v
CiliumEgressGatewayPolicy cxl-<hash>
  |
  v
gateway Node label cxl.io/egress-gw=<hash>
  |
  v
secondary ENI eth1 + node-local PBR
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

Subnet selection is not a single global operator setting in this version. The proxy nodepool must inject one of these label forms onto the reconciled nodes:

| Labels | Meaning |
|-------|---------|
| `cxl.io/subnet-tag-key` + `cxl.io/subnet-tag-value` | Select candidate secondary subnets by AWS tag. |
| `cxl.io/subnet-ids` | Comma-separated list of candidate subnet IDs. |

The proxy nodepool must also provide `cxl.io/vpc-id` to constrain subnet lookup to the correct VPC and `cxl.io/security-group` to name the security group attached to the secondary ENI.

The operator uses those labels to discover candidate secondary subnets inside the node's VPC and then picks the one matching the node's primary subnet or availability zone.

### Key values

| Value | Description |
|-------|-------------|
| `awsRegion` | AWS region of the EKS cluster / ENI subnet. |
| `aws.secretName` | *(optional)* Secret with static AWS credentials; otherwise the operator relies on the node's IAM role / instance profile. |
| `nodeInitializerImage` | Image for the node initializer Job (needs `iproute2` + `curl`). |
| `nodeInitializerJobNamespace` | Namespace for the initializer Jobs. Defaults to the operator namespace. |
| `kyvernoPolicyException.*` | Controls the pre-install/pre-upgrade Kyverno `PolicyException` allowing the operator Deployment/Pods and initializer Jobs/Pods to bypass `psp-restricted` in policy `kyverno-policies-3.8.2`. |
| `egressPolicyExcludedCidrs` | CIDRs excluded from `0.0.0.0/0` in the generated `CiliumEgressGatewayPolicy`. Defaults to `10.96.0.0/12`; add the cluster VPC CIDR at deploy time. |
| `watchNamespace` | Restrict the operator to one namespace. Empty = all. |

### AWS IAM permissions

The operator's AWS identity is used only for EC2/VPC discovery and secondary
network-interface lifecycle management. It must be available to the operator
Pod through IRSA/workload identity, the node or instance profile, or the
optional static-credentials Secret. The minimum EC2 actions are:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeSubnets",
        "ec2:DescribeRouteTables",
        "ec2:DescribeInternetGateways",
        "ec2:DescribeNetworkInterfaces",
        "ec2:CreateNetworkInterface",
        "ec2:CreateTags",
        "ec2:AttachNetworkInterface",
        "ec2:ModifyNetworkInterfaceAttribute",
        "ec2:DetachNetworkInterface",
        "ec2:DeleteNetworkInterface"
      ],
      "Resource": "*"
    }
  ]
}
```

These permissions support selecting subnets by ID or tag, resolving the
subnet route and internet gateway, finding an existing ENI, creating and
tagging a secondary ENI, attaching it to the node instance, enforcing
`DeleteOnTermination`, and detaching/deleting it during cleanup. The
`DescribeNetworkInterfaces` permission is also required by the cleanup
fallback when the ENI ID is not present on the Kubernetes Node.

The policy can be restricted further with IAM conditions and resource scoping
for the target VPC, subnets, instances, and ENI tags. Keep the describe
actions on `Resource: "*"`, as required by the EC2 API. No IAM permissions are
needed by the node initializer Job: it reads instance metadata locally and
configures routing on the node.

### Supporting manifests

The operator is not tied to one proxy implementation. The pod labeler now watches Pods directly and uses the scheduled node's egress labels to decide whether a Pod should receive `cxl.io/egress-gw`.

The examples in [examples](examples) show the new proxy workload and nodepool label contract rather than the removed selectorless Service pattern.

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