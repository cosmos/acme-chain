# Based on https://github.com/cosmos/gaia/blob/7c59858e697ad96ab432407ebc944edccec6281c/Dockerfile
FROM golang:1.25-alpine AS builder

ARG WASMVM_VERSION=v3.0.2
ADD https://github.com/CosmWasm/wasmvm/releases/download/${WASMVM_VERSION}/libwasmvm_muslc.aarch64.a /lib/libwasmvm_muslc.aarch64.a
ADD https://github.com/CosmWasm/wasmvm/releases/download/${WASMVM_VERSION}/libwasmvm_muslc.x86_64.a /lib/libwasmvm_muslc.x86_64.a
RUN cp "/lib/libwasmvm_muslc.$(uname -m).a" /lib/libwasmvm_muslc.a

RUN apk add --no-cache curl build-base git bash file linux-headers eudev-dev

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN LEDGER_ENABLED=false LINK_STATICALLY=true BUILD_TAGS=muslc make build
RUN echo "Ensuring binary is statically linked ..."  \
    && file ./build/acmed | grep "statically linked"
# Skip version test in cross-compilation to avoid SIGILL in emulated environments
# RUN echo "Ensuring binary is built and linked correctly" \
#     && ./build/acmed version

FROM alpine:3.21
COPY --from=builder /src/build/acmed /bin/acmed
ENTRYPOINT ["acmed"]
