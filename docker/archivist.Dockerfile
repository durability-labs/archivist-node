# Variables
ARG BUILDER=nimlang/nim:2.2.6-ubuntu-regular
ARG IMAGE=ubuntu:24.04
ARG RUST_VERSION=${RUST_VERSION:-1.79.0}
ARG BUILD_HOME=/src
ARG NIMFLAGS="-d:danger -d:release -d:disableMarchNative -d:nimleopard_portable_build -d:chronosFutureTracking -d:chronosFutureId"
ARG APP_HOME=/archivist
ARG NAT_IP_AUTO=${NAT_IP_AUTO:-false}

# Build
FROM ${BUILDER} AS builder
ARG RUST_VERSION
ARG BUILD_HOME
ARG NIMFLAGS

RUN apt-get update && apt-get install -y git cmake curl make bash build-essential
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs/ | sh -s -- --default-toolchain=${RUST_VERSION} -y

SHELL ["/bin/bash", "-c"]
ENV BASH_ENV="/etc/bash_env"
RUN echo "export PATH=$PATH:$HOME/.cargo/bin" >> $BASH_ENV

WORKDIR ${BUILD_HOME}
COPY . .
# Vendor is shipped complete in the build context; submodule update hits lock races
# and is a no-op for checked-out SHAs. Wipe host-built objects so Linux ar/ld work.
RUN find .git -name index.lock -delete 2>/dev/null || true \
 && test -f vendor/nimble/blscurve/vendor/blst/build/assembly.S \
 && find vendor \( -name "*.o" -o -name "*.a" -o -name "*.dylib" \) -delete
RUN sed -i '/exec("make CFLAGS=.*libnatpmp\.a")/a\      exec("ranlib libnatpmp.a")' vendor/nimble/nat_traversal/nat_traversal.nimble \
  && grep -n 'libnatpmp\|ranlib' vendor/nimble/nat_traversal/nat_traversal.nimble
RUN nimble build ${NIMFLAGS}

# Create
FROM ${IMAGE}
ARG BUILD_HOME
ARG APP_HOME
ARG NAT_IP_AUTO

WORKDIR ${APP_HOME}
COPY --from=builder ${BUILD_HOME}/build/archivist /usr/local/bin/
COPY --from=builder ${BUILD_HOME}/build/tools/cirdl/cirdl /usr/local/bin/
COPY --from=builder ${BUILD_HOME}/openapi.yaml .
COPY --from=builder --chmod=0755 ${BUILD_HOME}/docker/docker-entrypoint.sh /
RUN apt-get update && apt-get install -y libgomp1 curl jq && rm -rf /var/lib/apt/lists/*
ENV NAT_IP_AUTO=${NAT_IP_AUTO}
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["archivist"]
