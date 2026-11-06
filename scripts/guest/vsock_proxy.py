#!/usr/bin/env python3
"""Forward host virtio-vsock connections to the guest's local AceStream API."""

import select
import socket
import threading
import time

VSOCK_PORT = 6878
TCP_PORT = 6878
AF_VSOCK = getattr(socket, "AF_VSOCK", 40)
VMADDR_CID_ANY = getattr(socket, "VMADDR_CID_ANY", 0xFFFFFFFF)


def bridge(vsock: socket.socket) -> None:
    tcp = None
    try:
        tcp = socket.create_connection(("127.0.0.1", TCP_PORT), timeout=5)
        tcp.settimeout(None)
        readable = [vsock, tcp]
        while readable:
            ready, _, failed = select.select(readable, [], readable)
            if failed:
                break
            for source in ready:
                destination = tcp if source is vsock else vsock
                try:
                    data = source.recv(64 * 1024)
                except OSError:
                    return
                if not data:
                    try:
                        destination.shutdown(socket.SHUT_WR)
                    except OSError:
                        pass
                    readable.remove(source)
                    continue
                try:
                    destination.sendall(data)
                except OSError:
                    return
    except OSError:
        pass
    finally:
        for connection in (vsock, tcp):
            if connection is not None:
                try:
                    connection.close()
                except OSError:
                    pass


def serve() -> None:
    while True:
        server = None
        try:
            server = socket.socket(AF_VSOCK, socket.SOCK_STREAM)
            server.bind((VMADDR_CID_ANY, VSOCK_PORT))
            server.listen(128)
            print(f"vsock proxy listening on port {VSOCK_PORT}", flush=True)
            while True:
                connection, _ = server.accept()
                threading.Thread(target=bridge, args=(connection,), daemon=True).start()
        except OSError as error:
            print(f"vsock proxy retrying after error: {error}", flush=True)
            time.sleep(1)
        finally:
            if server is not None:
                try:
                    server.close()
                except OSError:
                    pass


if __name__ == "__main__":
    serve()
