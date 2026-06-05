"""
GPU Admission Webhook — ValidatingWebhook + MutatingWebhook in one server.

ValidatingWebhook (POST /validate):
  - Rejects any pod requesting nvidia.com/gpu or nvidia.com/mig-* WITHOUT a 'team' label
  - Returns a clear error message pointing to documentation

MutatingWebhook (POST /mutate):
  - If pod requests GPU but has no toleration for nvidia.com/gpu → injects it
  - Copies the namespace's 'cost-center' label onto the pod as an annotation

How it works:
  1. API server sends AdmissionReview JSON (contains the pod spec being created)
  2. This server inspects the pod
  3. Returns AdmissionResponse: allowed=true/false (validate) or patches (mutate)
  4. API server applies the decision before the pod is persisted to etcd
"""
import base64
import copy
import json
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
import ssl

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)


def pod_requests_gpu(pod_spec):
    """Check if any container in the pod requests GPU resources."""
    for container in pod_spec.get("containers", []):
        resources = container.get("resources", {})
        for section in ["requests", "limits"]:
            for resource_name in resources.get(section, {}):
                if "nvidia.com" in resource_name:
                    return True
    return False


def has_gpu_toleration(pod_spec):
    """Check if pod already has toleration for nvidia.com/gpu taint."""
    for toleration in pod_spec.get("tolerations", []):
        if toleration.get("key") == "nvidia.com/gpu":
            return True
    return False


def handle_validate(admission_review):
    """
    Validating webhook: reject GPU pods without 'team' label.
    This ensures all GPU cost is attributable to a team.
    """
    request = admission_review["request"]
    pod = request["object"]
    pod_name = pod.get("metadata", {}).get("name") or pod.get("metadata", {}).get("generateName", "unknown")

    if not pod_requests_gpu(pod.get("spec", {})):
        return {"allowed": True}

    labels = pod.get("metadata", {}).get("labels", {})
    if "team" not in labels:
        logger.warning(f"REJECTED pod {pod_name}: requests GPU but missing 'team' label")
        return {
            "allowed": False,
            "status": {
                "code": 403,
                "message": (
                    f"Pod '{pod_name}' requests nvidia.com GPU resources but is missing "
                    f"the 'team' label. All GPU pods must have a 'team' label for cost "
                    f"attribution. Add: metadata.labels.team: <your-team-name>"
                ),
            },
        }

    logger.info(f"ALLOWED pod {pod_name}: team={labels['team']}")
    return {"allowed": True}


def handle_mutate(admission_review):
    """
    Mutating webhook: auto-inject GPU toleration if missing.
    This saves teams from having to remember the toleration boilerplate.
    """
    request = admission_review["request"]
    pod = request["object"]
    pod_name = pod.get("metadata", {}).get("name") or pod.get("metadata", {}).get("generateName", "unknown")
    patches = []

    if not pod_requests_gpu(pod.get("spec", {})):
        return {"allowed": True}

    # Patch 1: inject GPU toleration if missing
    if not has_gpu_toleration(pod.get("spec", {})):
        tolerations = pod.get("spec", {}).get("tolerations", [])
        if not tolerations:
            patches.append({
                "op": "add",
                "path": "/spec/tolerations",
                "value": [{"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"}],
            })
        else:
            patches.append({
                "op": "add",
                "path": "/spec/tolerations/-",
                "value": {"key": "nvidia.com/gpu", "operator": "Exists", "effect": "NoSchedule"},
            })
        logger.info(f"MUTATED pod {pod_name}: injected GPU toleration")

    # Patch 2: add cost-attribution annotation with team name
    labels = pod.get("metadata", {}).get("labels", {})
    team = labels.get("team", "unknown")
    annotations = pod.get("metadata", {}).get("annotations", {})
    if "cost-attribution/team" not in annotations:
        if not annotations and not pod.get("metadata", {}).get("annotations"):
            patches.append({"op": "add", "path": "/metadata/annotations", "value": {}})
        patches.append({
            "op": "add",
            "path": "/metadata/annotations/cost-attribution~1team",
            "value": team,
        })

    response = {"allowed": True}
    if patches:
        response["patchType"] = "JSONPatch"
        response["patch"] = base64.b64encode(json.dumps(patches).encode()).decode()
    return response


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        admission_review = json.loads(body)

        if self.path == "/validate":
            response = handle_validate(admission_review)
        elif self.path == "/mutate":
            response = handle_mutate(admission_review)
        elif self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
            return
        else:
            self.send_response(404)
            self.end_headers()
            return

        admission_response = {
            "apiVersion": "admission.k8s.io/v1",
            "kind": "AdmissionReview",
            "response": {
                "uid": admission_review["request"]["uid"],
                **response,
            },
        }

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(admission_response).encode())

    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == "__main__":
    port = 8443
    server = HTTPServer(("0.0.0.0", port), WebhookHandler)

    # TLS — cert and key mounted from Secret (created by cert-manager or init Job)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain("/certs/tls.crt", "/certs/tls.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)

    logger.info(f"GPU Admission Webhook serving on :{port}")
    logger.info(f"  POST /validate — rejects GPU pods without 'team' label")
    logger.info(f"  POST /mutate  — injects GPU toleration + cost annotation")
    server.serve_forever()
