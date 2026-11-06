#!/bin/busybox sh

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
/bin/busybox --install -s /bin
/bin/busybox --install -s /sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
exec > /dev/console 2>&1
mkdir -p /dev/pts /dev/shm /tmp/ace_cache /mnt/rosetta /runtime /var/log
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
mkdir -p /tmp/ace_cache

for module in virtio_pci virtio_net virtio_console virtiofs vhost_vsock vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport binfmt_misc; do
  modprobe "$module" 2>/dev/null || true
done

if ! mount -t virtiofs -o ro mace-runtime /runtime; then
  printf 'Could not mount the MaceStream runtime.\n'
  while true; do sleep 3600; done
fi
hostname macestream
printf '127.0.0.1 localhost\n127.0.1.1 macestream\n' > /etc/hosts
ip link set lo up
ip link set eth0 up
ip addr flush dev eth0
ip addr add 192.168.64.23/24 dev eth0
ip route add default via 192.168.64.1 2>/dev/null || true
printf 'nameserver 192.168.64.1\nnameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf

if [ "$(uname -m)" = "aarch64" ]; then
  if ! mount -t virtiofs mace-rosetta /mnt/rosetta; then
    printf 'Could not mount the Rosetta runtime.\n'
    while true; do sleep 3600; done
  fi
  mkdir -p /proc/sys/fs/binfmt_misc
  mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
  if [ ! -e /proc/sys/fs/binfmt_misc/rosetta ]; then
    printf '%s\n' ':rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/rosetta/rosetta:F' > /proc/sys/fs/binfmt_misc/register
  fi
fi

export HOME=/tmp
export PYTHONHOME=/usr
export PYTHONPATH=/opt/acestream/lib:/usr/local/lib/python3.10/dist-packages
export LD_LIBRARY_PATH=/opt/acestream/lib:/usr/lib/x86_64-linux-gnu:/lib/x86_64-linux-gnu

(
  while true; do
    python3 -u /opt/macestream/vsock_proxy.py >> /var/log/vsock-proxy.log 2>&1
    sleep 1
  done
) &

printf 'MaceStream Linux environment is ready.\n'
while true; do
  cd /tmp/ace_cache
  : > /var/log/acestream.log
  /opt/acestream/acestreamengine \
    --client-console \
    --live-cache-type memory \
    --bind-all \
    >> /var/log/acestream.log 2>&1
  status=$?
  printf 'AceStream engine stopped (code: %s); restarting in two seconds.\n' "$status"
  tail -n 80 /var/log/acestream.log
  sleep 2
done
