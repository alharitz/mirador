# syntax=docker/dockerfile:1

# ---------- builder stage ----------
FROM golang:1.27-alpine AS builder

WORKDIR /src

# Dependencies are fetched before the source is copied in. As long as
# go.mod/go.sum don't change, this layer stays cached -- a rebuild after
# editing code takes seconds instead of waiting on a re-download.
COPY go.mod go.sum* ./
RUN go mod download

COPY . .

# CGO is disabled so the binary is static. That's what lets a build produced
# on alpine (musl) run as-is on the Debian (glibc) runtime below.
ENV CGO_ENABLED=0
RUN go build -trimpath -o /out/mirador ./cmd/mirador

# ---------- runtime stage ----------
FROM python:3.12-slim AS runtime

# dnstwist is invoked as a binary, not reimplemented. The version is pinned so
# the candidates generated today match the ones generated six months from now
# -- if the candidate list drifts silently, transition detection lies.
RUN pip install --no-cache-dir dnstwist==20250130

# This process touches the internet (DNS, CT logs, RDAP). No reason for it to
# run as root.
RUN useradd --create-home --uid 10001 mirador

COPY --from=builder /out/mirador /usr/local/bin/mirador

WORKDIR /app
RUN mkdir -p /app/out && chown -R mirador:mirador /app
USER mirador

# CMD, not ENTRYPOINT -- deliberate. With ENTRYPOINT, the Block 0 DoD command
# (docker compose run --rm app dnstwist --version) would become
# "mirador dnstwist --version" and fail. CMD lets another command replace it
# outright.
CMD ["mirador"]
