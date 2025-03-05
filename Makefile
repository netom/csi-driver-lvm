GO111MODULE := on
#KUBECONFIG := $(shell pwd)/.kubeconfig
HELM_REPO := "https://helm.metal-stack.io"
TAG := $(shell date +%Y%m%d%H%M%S)

ifeq ($(CI),true)
  DOCKER_TTY_ARG=
else
  DOCKER_TTY_ARG=t
endif

all: provisioner lvmplugin

.PHONY: lvmplugin
lvmplugin:
	go mod tidy
	CGO_ENABLED=0 GOOS=linux go build -a -ldflags '-extldflags "-static"' -o ./bin/lvmplugin ./cmd/lvmplugin
	strip ./bin/lvmplugin

.PHONY: provisioner
provisioner:
	go mod tidy
	go build -tags netgo -o bin/csi-lvmplugin-provisioner cmd/provisioner/*.go
	strip bin/csi-lvmplugin-provisioner

.PHONY: build-plugin
build-plugin:
	docker build -t netom/csi-driver-lvm:${TAG} .

.PHONY: build-provisioner
build-provisioner:
	docker build -t netom/csi-driver-lvm-provisioner:${TAG} . -f cmd/provisioner/Dockerfile

build-images: build-plugin build-provisioner

push-images: build-images
	docker push netom/csi-driver-lvm:${TAG}
	docker push netom/csi-driver-lvm-provisioner:${TAG}

helm-install: push-images
	helm -n csi-driver-lvm  upgrade --install --create-namespace \
		csi-driver-lvm chart/csi-driver-lvm \
	  --set pluginImage.tag=${TAG} \
	  --set provisionerImage.tag=${TAG}

/dev/loop%:
	@fallocate --length 2G loop$*.img
ifndef GITHUB_ACTIONS
	@sudo mknod $@ b 7 $*
endif
	@sudo losetup $@ loop$*.img
	@sudo losetup $@

rm-loop%:
	@sudo losetup -d /dev/loop$* || true
	@! losetup /dev/loop$*
	@sudo rm -f /dev/loop$*
	@rm -f loop$*.img
# If removing this loop device fails, you may need to:
# 	sudo dmsetup info
# 	sudo dmsetup remove <DEVICE_NAME>

.PHONY: kind
kind:
	@if ! which kind > /dev/null; then echo "kind needs to be installed"; exit 1; fi
	@if ! kind get clusters | grep csi-driver-lvm > /dev/null; then \
		kind create cluster \
		  --name csi-driver-lvm \
			--config tests/kind.yaml \
			--kubeconfig $(KUBECONFIG); fi
	@kind --name csi-driver-lvm load docker-image csi-driver-lvm
	@kind --name csi-driver-lvm load docker-image csi-driver-lvm-provisioner

.PHONY: rm-kind
rm-kind:
	@kind delete cluster --name csi-driver-lvm

RERUN ?= 1
.PHONY: test
test: build-plugin build-provisioner /dev/loop100 /dev/loop101 kind
	@cd tests && docker build -t csi-bats . && cd -
	@touch $(KUBECONFIG)
	@for i in {1..$(RERUN)}; do \
	docker run -i$(DOCKER_TTY_ARG) \
		-e HELM_REPO=$(HELM_REPO) \
		-v "$(KUBECONFIG):/root/.kube/config" \
		-v "$(PWD)/tests:/code" \
		--network host \
		csi-bats \
		--verbose-run --trace --timing bats/test.bats ; \
	done

.PHONY: test-cleanup
test-cleanup: rm-kind
