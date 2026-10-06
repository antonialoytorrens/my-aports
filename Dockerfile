# Builder for docker-* Makefile targets (make + Docker CLI via host socket).
FROM docker:cli

RUN apk add --no-cache make bash

WORKDIR /workspace
