NAME:=tss-injector
VERSION?=latest

IMAGE_TAG=$(NAME):$(VERSION)

DOCKER=docker
# Podman also works but it assumes that the registry is HTTPS...
#DOCKER=podman
#DOCKER_PUSH_ARGS=--tls-verify=false

# Use the Minikube built-in kubectl by default
KUBECTL=minikube kubectl --
REGISTRY_ENABLE=minikube addons enable registry
REGISTRY_SCHEME?=http
REGISTRY_NAMESPACE?=kube-system
REGISTRY_PORT?=port
IMAGE_PULL_REGISTRY_PORT?=$(REGISTRY_PORT)
CA_CRT?=${HOME}/.minikube/ca.crt

# Microk8s
#KUBECTL=/snap/bin/microk8s.kubectl
#REGISTRY_ENABLE=microk8s enable registry
#REGISTRY_NAMESPACE?=container-registry
#REGISTRY_PORT?=port
#REGISTRY_SCHEME?=registry
#IMAGE_PULL_REGISTRY_PORT?=nodePort
#CA_CRT?=/var/snap/microk8s/current/certs/ca.crt

all: image

registry:
	@$(REGISTRY_ENABLE)
REGISTRY=$(shell $(KUBECTL) get -n $(REGISTRY_NAMESPACE) service registry\
	-o jsonpath="{.spec.clusterIP}{':'}{.spec.ports[?(@.name == '$(REGISTRY_SCHEME)')].$(REGISTRY_PORT)}")

ifneq ($(IMAGE_PULL_REGISTRY_PORT),$(REGISTRY_PORT))
IMAGE_PULL_REGISTRY=$(shell $(KUBECTL) get -n $(REGISTRY_NAMESPACE) service registry -o\
  jsonpath="{'localhost:'}{.spec.ports[?(@.name == '$(REGISTRY_SCHEME)')].$(IMAGE_PULL_REGISTRY_PORT)}")
else
IMAGE_PULL_REGISTRY=$(REGISTRY)
endif

# Build, tag and push the tss-injector service 📦
image: registry
	$(DOCKER) build . -t $(IMAGE_TAG) -f build/Dockerfile $(DOCKER_BUILD_ARGS)
	$(DOCKER) tag $(DOCKER_TAG_ARGS) $(IMAGE_TAG) $(REGISTRY)/$(IMAGE_TAG)
	$(DOCKER) push $(DOCKER_PUSH_ARGS) $(REGISTRY)/$(IMAGE_TAG)

### The remainder builds and deploys a test injector-svc ☑️

# See the "CA certificate" section of README.md 🔐📖
CA_BUNDLE?=$(shell base64 -w0 $(CA_CRT))

# The Kubernetes Namespace in which to deploy 📁
NAMESPACE?=default

# The JSON file containing a mapping of TSS role names to tenant/credentials 🔑
ROLES_FILE?=configs/roles.json

# The IP address of the host running the tss-injector service 🖥️
SERVICE_IP?=$(shell ip route get 1.1.1.1 | grep -oP 'src \K\S+')

# The TCP port on which the service will listen 🌐
SERVICE_PORT?=8543

TEST_IMAGE_TAG?=$(NAME)-test:$(VERSION)

IMAGE_PULL_POLICY=Always

BUILD_DIR=target

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

deploy_webhook: $(BUILD_DIR)
	sed -e "s| namespace: .*$$| namespace: $(NAMESPACE)|" \
		-e "s| port: [0-9]*.*$$| port: $(SERVICE_PORT)|" \
		-e "s|caBundle:.*$$|caBundle: $(CA_BUNDLE)|" \
		deployments/webhook.yml >| $(BUILD_DIR)/webhook.yml
	$(KUBECTL) apply -f $(BUILD_DIR)/webhook.yml

# Get a certificate from the Kubernetes cluster CA
$(BUILD_DIR)/$(NAME).key $(BUILD_DIR)/$(NAME).pem: $(BUILD_DIR)
	sh scripts/get_cert.sh -n "$(NAME)" -N "$(NAMESPACE)" -d "$(BUILD_DIR)" -k "$(KUBECTL)"

tss-injector-svc: cmd/tss-injector-svc.go
	go build $<

# Deploy the service that the webhook uses as a pointer to the host
deploy_host: deploy_webhook $(BUILD_DIR)/$(NAME).key $(BUILD_DIR)/$(NAME).pem tss-injector-svc
	sed -e "s| namespace: .*$$| namespace: $(NAMESPACE)|" \
		-e "s|- port: [0-9]*.*$$|- port: $(SERVICE_PORT)|" \
		-e "s|- ip: *\"[0-9].*$$|- ip: \"$(SERVICE_IP)\"|" \
		deployments/host.yml >| $(BUILD_DIR)/host.yml
	$(KUBECTL) apply -f $(BUILD_DIR)/host.yml

# Create the test image Dockerfile
$(BUILD_DIR)/Dockerfile: registry test/Dockerfile $(BUILD_DIR)
	sed -e "s|^FROM $(NAME):.*|FROM $(REGISTRY)/$(IMAGE_TAG)|" \
		test/Dockerfile >| $(BUILD_DIR)/Dockerfile

# Build the test image 🥼🥽🧪
test_image: registry image $(BUILD_DIR)/$(NAME).key $(BUILD_DIR)/$(NAME).pem $(BUILD_DIR)/Dockerfile
	$(DOCKER) build . -t $(TEST_IMAGE_TAG) -f $(BUILD_DIR)/Dockerfile $(DOCKER_BUILD_ARGS) \
		--build-arg cert_file="$(BUILD_DIR)/$(NAME).pem" \
		--build-arg key_file="$(BUILD_DIR)/$(NAME).key" \
		--build-arg roles_file="$(ROLES_FILE)"
	$(DOCKER) tag $(DOCKER_TAG_ARGS) $(TEST_IMAGE_TAG) $(REGISTRY)/$(TEST_IMAGE_TAG)
	$(DOCKER) push $(DOCKER_PUSH_ARGS) $(REGISTRY)/$(TEST_IMAGE_TAG)

# Deploy the test image that includes the certficate and roles.json ⚠️🔓😧
deploy: deploy_webhook test_image
	sed -e "s| namespace: .*$$| namespace: $(NAMESPACE)|" \
		-e "s|- port: [0-9]*.*$$|- port: $(SERVICE_PORT)|" \
		-e "s|imagePullPolicy:.*$$|imagePullPolicy: $(IMAGE_PULL_POLICY)|" \
		-e "s|image:.*$$|image: $(IMAGE_PULL_REGISTRY)/$(TEST_IMAGE_TAG)|" \
		deployments/pod.yml >| $(BUILD_DIR)/pod.yml
	$(KUBECTL) apply -f $(BUILD_DIR)/pod.yml

deploy_clean:
	$(KUBECTL) delete --ignore-not-found deployments $(NAME)
	$(KUBECTL) delete --ignore-not-found service $(NAME)
	$(KUBECTL) delete --ignore-not-found mutatingwebhookconfigurations.admissionregistration.k8s.io $(NAME)

clean: deploy_clean
	rm -rf $(BUILD_DIR) tss-injector-svc
