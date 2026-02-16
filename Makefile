# openstack-ironic-operator - Ironic + Krateo integration
.PHONY: help apply-oas apply-restdef deploy-chart package-chart template-chart deploy-ironic validate-chart

HELM_NAMESPACE ?= default
IRONIC_NS ?= openstack

help:
	@echo "Targets:"
	@echo "  apply-oas      - Create ConfigMap with OAS in cluster"
	@echo "  apply-restdef  - Apply RestDefinition (requires apply-oas first)"
	@echo "  deploy-chart   - Helm install baremetal-lifecycle chart"
	@echo "  package-chart  - Package chart to .tgz for publishing"
	@echo "  template-chart - Dry-run helm template (requires nodeName in values)"
	@echo "  validate-chart - Verify Node CR and Job templates render"
	@echo "  deploy-ironic  - Helm install Ironic with overrides (req: openstack-helm repo, backends)"

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
