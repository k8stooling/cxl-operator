# CXL Operator Implementation Plan

## Objective
Implement `cxl-operator`, a Kubernetes Operator built with the Ansible Operator SDK. This operator manages secondary ENI attachments for EKS worker nodes and synchronizes external `EndpointSlices` to enable cross-VPC routing without VPC peering. 

## Environment & Boilerplate Constraints
- You are running in a directory containing an existing `cloudflare-operator` repository.
- Read the existing `cloudflare-operator` codebase to understand its structure.
- **Do not overwrite `cloudflare-operator`**. Instead, scaffold a new Ansible Operator named `cxl-operator` adjacent to or within a new directory, utilizing `operator-sdk init --plugins=ansible`.
- Copy and adapt the GitHub Actions CI/CD workflows, Makefile, and Helm chart structure from `cloudflare-operator` to `cxl-operator`.
- Add the `kubernetes.core` and `amazon.aws` Ansible collections to `requirements.yml`.

## Architecture & Logic
The operator requires three decoupled reconciliation loops (Watches) defined in `watches.yaml`:

### 1. Watch: `eni_provisioner` (Hardware & Node Initialization)
- **Trigger:** `CiliumNode` resource (`cilium.io/v2`) filtered by the label `cxl.io/vpc-type=proxy`.
- **Role:** `eni_provisioner`
- **Reconcile Period:** `30s`
- **Tasks:**
  1. Extract the EC2 Instance ID from the `CiliumNode`'s `spec['instance-id']` and record the `nodeName`.
  2. Check the Kubernetes `Node` object. If it already has the annotation `network.infrastructure.io/secondary-eni-ip`, skip provisioning.
  3. Read the nodepool-injected subnet selector labels (`cxl.io/subnet-tag-key` + `cxl.io/subnet-key-value` or `cxl.io/subnet-iids`) from the node.
  4. Resolve candidate remote subnets and select the one matching the node's primary subnet / availability zone.
  5. Use the `amazon.aws.ec2_eni` module to attach a secondary ENI from that subnet to the EC2 instance.
  6. Retrieve the new `eth1` private IP and patch the Kubernetes `Node` object with the annotation: `metadata.annotations["network.infrastructure.io/secondary-eni-ip"] = <ETH1_IP>`.
  7. Deploy a Kubernetes `Job` (Node Initializer) targeted strictly to this `nodeName` via `nodeSelector` or `nodeName`. The Job must use `hostNetwork: true` and `CAP_NET_ADMIN`.
    8. The Bottlerocket-focused Job script must execute the following on the host network namespace:
     - Wait for `eth1` to appear.
      - Use AWS IMDSv2 to assign the secondary ENI IP.
     - Execute Policy-Based Routing:
       ```bash
       ip route add default via <ETH1_GW> dev eth1 table 100
       ip rule add from <ETH1_IP> lookup 100
       echo 1 > /proc/sys/net/ipv4/conf/eth1/arp_ignore
       echo 2 > /proc/sys/net/ipv4/conf/eth1/arp_announce
       ```

### 2. Watch: `service_sync` (Source Service Intent)
- **Trigger:** Kubernetes `Service` (`v1`) filtered by the label `cxl.io/service=proxy`.
- **Role:** `service_sync`
- **Reconcile Period:** `15s`
- **Tasks:**
  1. Reconcile only Services labeled `cxl.io/service=proxy`.
  2. Derive the managed selectorless Service / EndpointSlice names as `<source-service>-cxl` by default.
  3. Mirror the watched Service port, preferring `nodePort` when present.
  4. Reuse the shared reconciliation path that also gathers ready backends from the source Service EndpointSlices.

### 3. Watch: `endpoint_slice_sync` (Backend Churn)
- **Trigger:** Native Kubernetes `EndpointSlice` (`discovery.k8s.io/v1`) for the source workload Service.
- **Role:** `endpoint_slice_sync`
- **Reconcile Period:** `15s`
- **Tasks:**
  1. Skip operator-managed EndpointSlices.
  2. Resolve the owning source Service from `kubernetes.io/service-name`.
  3. Reconcile only when that owning Service is labeled `cxl.io/service=proxy`.
  4. Reuse the same shared reconciliation path as `service_sync` so backend churn is reflected immediately in the managed CXL EndpointSlice.

## Supporting Manifests to Generate
Create a directory (e.g., `examples/` or inside the Helm chart) with these accompanying manifests:
1. **Selectorless Service (`haproxy-remote-eni-svc.yaml`):** A standard Service without a `spec.selector`, typically named `<source-service>-cxl`, exposing the same source port or `nodePort` as the watched Service.
2. **Target Group Binding (`haproxy-remote-tgb.yaml`):** An `elbv2.k8s.aws/v1beta1` resource binding the selectorless service to a target group ARN with `targetType: ip`.
3. **RBAC Updates (`config/rbac/role.yaml`):** Ensure the Operator's ServiceAccount has permissions for:
  - `discovery.k8s.io/endpointslices` (Create/Get/List/Watch/Patch/Update)
  - `services` (Get/List/Watch)
   - `nodes` (Get/List/Watch/Patch)
   - `batch/jobs` (Create/List/Watch/Delete)
   - `cilium.io/ciliumnodes` (Get/List/Watch)

## Execution Steps for Cline
1. Scaffold the `cxl-operator` project structure.
2. Read the `cloudflare-operator` CI/CD and Helm configurations, then copy and adapt them to `cxl-operator`.
3. Configure `watches.yaml` and `requirements.yml`.
4. Implement `roles/eni_provisioner/tasks/main.yml` and create the Jinja2 template for the Node Initializer Job in `roles/eni_provisioner/templates/`.
5. Implement `roles/service_sync/tasks/main.yml` and `roles/endpoint_slice_sync/tasks/main.yml` using a shared reconciliation task file.
6. Generate the supporting manifests and update RBAC.
7. Run tests or validations if applicable.

