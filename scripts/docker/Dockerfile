# syntax=docker/dockerfile:1.7
ARG ALPINE_VERSION=3.22

FROM alpine:${ALPINE_VERSION} AS kernel
RUN apk add --no-cache linux-virt python3 zstd lz4
COPY scripts/docker/extract_vmlinux.py /usr/local/bin/extract_vmlinux.py
RUN python3 /usr/local/bin/extract_vmlinux.py /boot/vmlinuz-virt /vmlinux \
    && test -s /vmlinux

FROM --platform=linux/amd64 ubuntu:22.04 AS acestream
ARG ACESTREAM_URL=https://download.acestream.media/linux/acestream_3.2.11_ubuntu_22.04_x86_64_py3.10.tar.gz
ARG ACESTREAM_SHA256=9b6bbd76a55e5a434641afae3b9cf8e6154ce1cf392152ec3aed5ac265432b2e
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl python3.10 libpython3.10 python3-pip \
      build-essential python3.10-dev \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fL --retry 3 "${ACESTREAM_URL}" -o /tmp/acestream.tar.gz \
    && echo "${ACESTREAM_SHA256}  /tmp/acestream.tar.gz" | sha256sum -c - \
    && mkdir -p /opt/acestream \
    && tar -xzf /tmp/acestream.tar.gz -C /opt/acestream \
    && test -x /opt/acestream/acestreamengine \
    && python3.10 -m pip install --no-cache-dir -r /opt/acestream/requirements.txt setuptools==75.8.0 \
    && LD_LIBRARY_PATH=/opt/acestream/lib /opt/acestream/acestreamengine --version

FROM alpine:${ALPINE_VERSION} AS rootfs
RUN apk add --no-cache ca-certificates
COPY --from=kernel /vmlinux /boot/vmlinuz
COPY --from=kernel /lib/modules /lib/modules
COPY --from=acestream /opt/acestream /opt/acestream
COPY --from=acestream /usr/bin/python3.10 /usr/bin/python3.10
COPY --from=acestream /usr/lib/python3.10 /usr/lib/python3.10
COPY --from=acestream /usr/local/lib/python3.10 /usr/local/lib/python3.10
COPY --from=acestream /lib64 /lib64
COPY --from=acestream /usr/lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu
RUN rm -rf /usr/lib/python3.10/config-3.10-x86_64-linux-gnu \
      /usr/lib/python3.10/test \
      /usr/lib/python3.10/ensurepip \
      /usr/lib/x86_64-linux-gnu/perl \
      /usr/lib/x86_64-linux-gnu/perl-base \
      /usr/lib/x86_64-linux-gnu/ldscripts \
    && find /usr/lib/x86_64-linux-gnu -type f -name '*.a' -delete \
    && find /usr/lib/x86_64-linux-gnu -type l -name '*.a' -delete \
    && rm -f /opt/acestream/data/webui/cert/engine.pem \
      /usr/lib/python3.10/sitecustomize.py \
      /usr/lib/x86_64-linux-gnu/sitecustomize.py \
      /usr/lib/x86_64-linux-gnu/libasan.so* \
      /usr/lib/x86_64-linux-gnu/libtsan.so* \
      /usr/lib/x86_64-linux-gnu/liblsan.so* \
      /usr/lib/x86_64-linux-gnu/libubsan.so* \
      /usr/lib/x86_64-linux-gnu/libperl.so* \
      /usr/lib/x86_64-linux-gnu/libbfd* \
      /usr/lib/x86_64-linux-gnu/libopcodes* \
    && find /opt/acestream /usr/lib/python3.10 /usr/local/lib/python3.10 \
      -type d -name __pycache__ -prune -exec rm -rf '{}' ';'
COPY scripts/docker/init.sh /init
COPY scripts/guest/vsock_proxy.py /opt/macestream/vsock_proxy.py
RUN chmod 0755 /init /opt/acestream/acestreamengine /opt/acestream/start-engine \
    && ln -sfn /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu \
    && ln -sf /bin/busybox /bin/sh \
    && ln -sf /usr/bin/python3.10 /usr/bin/python3 \
    && mkdir -p /dev/pts /proc /sys /run /tmp/ace_cache /mnt/rosetta /etc /var/log \
    && chmod 1777 /tmp /tmp/ace_cache \
    && printf 'macestream\n' > /etc/hostname
