# Offline schema sources

`sources.json` pins each upstream URL and its SHA-256 digest. Kubernetes snapshots
use a specific kubernetes-json-schema commit; CRDs use release URLs plus content
checksums. Run `python scripts/update_common_schemas.py --cache /tmp/common-crds`
from the repository root to reproduce the snapshots. Unexpected upstream bytes
fail the update.

- Kubernetes: 1.31.0 through 1.37.0, complete built-in definitions and exact GVK index.
- Gateway API: 1.5.0, standard APIs plus experimental TCPRoute and UDPRoute.
- cert-manager: 1.21.2 Certificate.
- External Secrets: 2.10.0 ExternalSecret.
- Prometheus Operator: 0.94.0 ServiceMonitor and PodMonitor.

The JSON snapshots remove descriptions, defaults and Kubernetes extensions;
JSON Schema validation does not execute CEL. The cluster suite downloads the
original checksum-verified CRDs, preserving CEL for API-server admission tests.
Input schemas accept partial overlays and null tombstones. Output schemas retain
native required fields and types. Unknown output API versions and kinds fail.

The Kubernetes schema distribution uses Apache-2.0; KUBERNETES-LICENSE preserves
its attribution. Gateway API, cert-manager, External Secrets and Prometheus
Operator also use Apache-2.0; GATEWAY-LICENSE contains the full license text. Source URLs and project provenance are
preserved in sources.json. These development snapshots are excluded from Helm
packages; generated consumer schemas retain their complete offline definitions.
