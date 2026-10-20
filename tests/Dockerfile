FROM ubuntu:24.04

ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl clang python3 bash zsh fish \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
    arm64) checksum=99c43e9670a285901d6cfee5f56197b74c7d6f7c537b35ecba0c1b44ac2e4df8 ;; \
    amd64) checksum=c3c8b095621fd0c75f7f73e3a0829f1b4d45324225f20ba11ed8dc4da310a8ab ;; \
    *) exit 1 ;; \
    esac \
    && curl -fsSL "https://github.com/odin-lang/Odin/releases/download/dev-2026-10/odin-linux-${TARGETARCH}-dev-2026-10.tar.gz" -o /tmp/odin.tar.gz \
    && echo "$checksum  /tmp/odin.tar.gz" | sha256sum -c - \
    && mkdir /opt/odin \
    && tar -xzf /tmp/odin.tar.gz -C /opt/odin --strip-components=1 \
    && rm /tmp/odin.tar.gz

ENV PATH="/opt/odin:${PATH}"
WORKDIR /work
COPY main.odin README.md ./
COPY completions ./completions
COPY tests/integration.py ./tests/integration.py
COPY tests/fixtures ./tests/fixtures
RUN odin build . -out:jog -o:speed
CMD ["python3", "tests/integration.py", "-v"]
