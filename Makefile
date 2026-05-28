# openstack-ironic-operator - Ironic + Krateo integration
.PHONY: help apply-oas apply-restdef deploy-chart package-chart template-chart deploy-ironic validate-chart \
        kind-up kind-down local-up local-down ironic-up ironic-down ironic-forward smoke-test kubeconfig

HELM_NAMESPACE ?= default
IRONIC_NS ?= openstack

# --- Local test environment (isolated kind cluster; never touches ~/.kube/config) ---
KIND_CLUSTER ?= ironic-kog
KUBECONFIG_FILE ?= local/kubeconfig.$(KIND_CLUSTER)
KCTX := kind-$(KIND_CLUSTER)
KUBECTL := kubectl --kubeconfig $(KUBECONFIG_FILE) --context $(KCTX)
HELMK := helm --kubeconfig $(KUBECONFIG_FILE) --kube-context $(KCTX)

help:
	@echo "Targets:"
	@echo "  apply-oas      - Create ConfigMap with OAS in cluster"
	@echo "  apply-restdef  - Apply RestDefinition (requires apply-oas first)"
	@echo "  deploy-chart   - Helm install baremetal-lifecycle chart"
	@echo "  package-chart  - Package chart to .tgz for publishing"
	@echo "  template-chart - Dry-run helm template (requires nodeName in values)"
	@echo "  validate-chart - Verify Node CR and Job templates render"
	@echo "  deploy-ironic  - Helm install Ironic with overrides (req: openstack-helm repo, backends)"
	@echo "Local test env (isolated kind cluster, never touches ~/.kube/config):"
	@echo "  local-up       - Create kind cluster + Ironic + Krateo providers"
	@echo "  krateo-up      - Install Krateo KOG (oasgen) + composition (core) providers"
	@echo "  ironic-up      - (Re)deploy standalone Ironic into the kind cluster"
	@echo "  ironic-forward - Port-forward Ironic API to localhost:6385"
	@echo "  smoke-test     - Drive a fake node enroll->active against local Ironic"
	@echo "  local-down     - Delete the local kind cluster"

apply-oas:
	./scripts/create-ironic-oas-configmap.sh $(IRONIC_NS)

apply-restdef: apply-oas
	kubectl apply -f manifests/restdefinition-node.yaml

deploy-chart:
	helm upgrade --install baremetal-lifecycle ./charts/baremetal-lifecycle \
		-n $(HELM_NAMESPACE) --create-namespace

package-chart:
	@mkdir -p dist
	helm package charts/baremetal-lifecycle -d dist/

template-chart:
	helm template baremetal-lifecycle ./charts/baremetal-lifecycle \
		-n $(HELM_NAMESPACE) \
		--set nodeName=test-node \
		--set driver_info.ipmi_address=172.19.74.202 \
		--set driver_info.ipmi_password=secret

validate-chart:
	@helm template baremetal-lifecycle ./charts/baremetal-lifecycle \
		-n $(HELM_NAMESPACE) \
		--set nodeName=test-node \
		--set driver_info.ipmi_address=172.19.74.202 \
		--set driver_info.ipmi_password=secret \
		--set ports[0].address=9c:b6:54:b2:b0:ca > /dev/null && echo "Chart templates render OK"
	@helm template baremetal-lifecycle ./charts/baremetal-lifecycle -n $(HELM_NAMESPACE) --set nodeName=test-node | grep -q "kind: Node" && echo "Node CR present: OK"

# Deploy Ironic via openstack-helm (requires: helm repo add openstack-helm, rabbitmq/mariadb/memcached/keystone/glance/neutron)
deploy-ironic:
	helm upgrade --install ironic openstack-helm/ironic \
		--namespace=$(IRONIC_NS) \
		-f deploy/values/ironic-overrides.yaml

# --- Local test environment ----------------------------------------------------
# An isolated kind cluster + standalone Ironic (official openstack-helm image, fake
# drivers, noauth). All kubectl/helm calls use --kubeconfig $(KUBECONFIG_FILE) and
# --context $(KCTX), so the default ~/.kube/config is never touched.

kubeconfig:   # (re)write the isolated kubeconfig for the kind cluster
	kind export kubeconfig --name $(KIND_CLUSTER) --kubeconfig $(KUBECONFIG_FILE)

kind-up:      # create the local kind cluster (idempotent; isolated kubeconfig)
	@kind get clusters 2>/dev/null | grep -qx $(KIND_CLUSTER) || \
		kind create cluster --name $(KIND_CLUSTER) --kubeconfig $(KUBECONFIG_FILE) --wait 60s
	@kind export kubeconfig --name $(KIND_CLUSTER) --kubeconfig $(KUBECONFIG_FILE) >/dev/null
	@echo "kubeconfig=$(KUBECONFIG_FILE) context=$(KCTX)"

ironic-up:    # deploy standalone Ironic (fake drivers, noauth) into the kind cluster
	$(KUBECTL) apply -f local/ironic-standalone.yaml
	$(KUBECTL) -n $(IRONIC_NS) create configmap ironic-config \
		--from-file=ironic.conf=local/ironic.conf --dry-run=client -o yaml | $(KUBECTL) apply -f -
	$(KUBECTL) -n $(IRONIC_NS) rollout restart deploy/ironic
	$(KUBECTL) -n $(IRONIC_NS) rollout status deploy/ironic --timeout=240s

ironic-down:  # remove standalone Ironic from the kind cluster
	-$(KUBECTL) delete -f local/ironic-standalone.yaml

ironic-forward: # port-forward the Ironic API to localhost:6385 (run in a separate shell)
	$(KUBECTL) -n $(IRONIC_NS) port-forward svc/ironic 6385:6385

smoke-test:   # drive a fake node enroll->active against the local Ironic (CLEANUP=1 to delete after)
	@$(KUBECTL) -n $(IRONIC_NS) port-forward svc/ironic 6385:6385 >/tmp/ironic-pf.log 2>&1 & \
	pf=$$!; sleep 4; \
	IRONIC_API=http://localhost:6385 CLEANUP=$${CLEANUP:-1} ./scripts/smoke-test-ironic.sh; rc=$$?; \
	kill $$pf 2>/dev/null; exit $$rc

KRATEO_CORE_VERSION ?= 1.0.0
KRATEO_OASGEN_VERSION ?= 0.11.1

krateo-up:    # install Krateo KOG (oasgen-provider) + composition engine (core-provider)
	helm repo add krateo https://charts.krateo.io 2>/dev/null || true
	helm repo update krateo
	$(HELMK) upgrade --install krateo-core-provider krateo/core-provider \
		-n krateo-system --create-namespace --version $(KRATEO_CORE_VERSION) --wait --timeout 6m
	$(HELMK) upgrade --install krateo-oasgen-provider krateo/oasgen-provider \
		-n krateo-system --version $(KRATEO_OASGEN_VERSION) --wait --timeout 6m
	$(KUBECTL) -n krateo-system get pods

local-up: kind-up ironic-up krateo-up   # create kind cluster + Ironic + Krateo providers

local-down:   # delete the whole local kind cluster
	-kind delete cluster --name $(KIND_CLUSTER) --kubeconfig $(KUBECONFIG_FILE)
