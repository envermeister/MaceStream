# MaceStream Privacy

MaceStream does not include analytics, advertising, account systems, remote channel catalogs, or content-search services.

## Data stored on your Mac

- AceStream links you play, optional custom names, favorites, timestamps and play counts.
- Player preferences such as volume, aspect mode and buffer profile.
- Engine and virtual-machine diagnostic logs.

History is limited to 60 entries and can be cleared from the sidebar or Settings. Settings and history are stored under `~/Library/Application Support/MaceStream`. The engine cache is under `~/Library/Caches/MaceStream` and can be cleared independently.

## Network access

MaceStream contacts its embedded engine through a loopback-only (`127.0.0.1`) listener bridged over virtio-vsock. The engine must access the AceStream peer-to-peer network to play a stream. As with other peer-to-peer software, your IP address and transfer activity can be visible to peers and your network provider.

The app does not send your history to the developer. A diagnostic report is copied to the clipboard only when you click **Copy Diagnostics**. It does not include your link history; engine logs may contain technical stream identifiers, so review logs before sharing them.

## Third-party content

You choose every link. MaceStream does not recommend, catalog or verify content and cannot determine whether you have permission to access it.
