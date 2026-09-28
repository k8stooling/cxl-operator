# Makefile
VERSION ?= latest
IMG ?= ghcr.io/k8stooling/cxl-operator:$(VERSION)

docker-build:
	docker build -t ${IMG} .

docker-push:
	docker push ${IMG}

docker-buildx:
	docker buildx build --push --platform linux/arm64,linux/amd64 -t ${IMG} .
