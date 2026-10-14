FROM cloudflared-ios-builder:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake ninja-build pkg-config libssl-dev zlib1g-dev python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /work
ENV THEOS=/home/builder/theos
ENV PATH="/home/builder/theos/toolchain/linux/iphone/bin:${PATH}"
ENTRYPOINT ["/bin/bash"]
