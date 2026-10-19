# syntax=docker/dockerfile:1

# ---------- builder stage ----------
FROM rust:1-slim AS builder

WORKDIR /src

# Copy Cargo manifest and lock file to cache dependencies
COPY Cargo.toml Cargo.lock ./
# Create a dummy src directory to fetch dependencies
RUN mkdir src && echo "fn main() {}" > src/main.rs
# Build dependencies to cache them
RUN cargo build --release
# Remove the dummy app
RUN rm -rf src target/release/deps/mirador*

# Copy the actual source code
COPY . .

# Build the actual application in release mode
RUN cargo build --release

# ---------- runtime stage ----------
FROM python:3.12-slim AS runtime

# dnstwist is invoked as a binary, not reimplemented. The version is pinned so
# the candidates generated today match the ones generated six months from now
# -- if the candidate list drifts silently, transition detection lies.
RUN pip install --no-cache-dir dnstwist==20250130

# This process touches the internet (DNS, CT logs, RDAP). No reason for it to
# run as root.
RUN useradd --create-home --uid 10001 mirador

# Copy the binary from the builder stage
COPY --from=builder /src/target/release/mirador /usr/local/bin/mirador

WORKDIR /app
RUN mkdir -p /app/out && chown -R mirador:mirador /app
USER mirador

# CMD, not ENTRYPOINT -- deliberate. With ENTRYPOINT, the Block 0 DoD command
# (docker compose run --rm app dnstwist --version) would become
# "mirador dnstwist --version" and fail. CMD lets another command replace it
# outright.
CMD ["mirador"]