#!/usr/bin/env python3
"""test_edge_up_sess_real.sh laboratuvar yardımcısı (yalnız Python stdlib, yalnız 127.0.0.1).

  slowsink <dinle_port> <cert> <key> <kayıt> <bekleme_ms> : sahte pCloud. TLS, HTTP/1.1. Her istek için upload_write sorgusundan
        uploadid/uploadoffset okunur; Content-Length kadar gövde tamamen alınır, SONRA uploadid '9' ile başlıyorsa <bekleme_ms>
        kadar yanıt tutulur (yavaş yutan üst akış); diğer uploadid'ler beklemez. Kayıt satırları:
          S <uploadid> <ofs> <o_uploadid_icin_eszamanli> <toplam_eszamanli>   (istek üst akışa ULAŞTI)
          E <uploadid> <ofs>                                                   (istek bitti)
  race    <port> <host> <uid> <saldirgan_bilet|-> <mesru_bilet> <damla_sn> : YETKİSİZ istemci uid'e büyük Content-Length'li PUT açar ve gövdeyi
        <damla_sn> boyunca damla damla yollar (nginx 403'ü hemen verir ama gövdeyi atarken isteği yaşatır); araya MEŞRU biletli küçük PUT'lar
        (her biri yeni HTTP/1.1 bağlantı, ardışık) girer. Çıktı tek satır: "saldirgan=<kod> mesru=<kod,kod,...>".
  spawn   <pidfile> <logfile> <mod> <arg...>              : yukarıdakini AYRIK süreç olarak başlatır, PID'i pidfile'a yazar.
Süreç SIGTERM ile sonlanır (betik PID ile öldürür; harness_safe.sh hs_kill_pidfile).
"""
import asyncio
import re
import socket
import ssl
import sys
import threading
import time

_QS = re.compile(rb"uploadid=([0-9]+)&uploadoffset=([0-9]+)")


async def slowsink_main(lport, cert, key, log, hold_ms):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    active = {}
    total = [0]

    def put(line):
        with open(log, "a") as f:
            f.write(line + "\n")

    async def handle(r, w):
        try:
            while True:
                head = await r.readuntil(b"\r\n\r\n")
                n = 0
                for ln in head.split(b"\r\n"):
                    if ln.lower().startswith(b"content-length:"):
                        n = int(ln.split(b":", 1)[1])
                m = _QS.search(head.split(b"\r\n", 1)[0])
                uid = m.group(1).decode() if m else "?"
                ofs = m.group(2).decode() if m else "?"
                active[uid] = active.get(uid, 0) + 1
                total[0] += 1
                put("S %s %s %d %d" % (uid, ofs, active[uid], total[0]))
                try:
                    got = 0
                    while got < n:
                        d = await r.read(min(1 << 20, n - got))
                        if not d:
                            break
                        got += len(d)
                    if uid.startswith("9"):
                        await asyncio.sleep(hold_ms / 1000.0)
                    body = b'{"result":0}'
                    w.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n" % len(body) + body)
                    await w.drain()
                finally:
                    active[uid] -= 1
                    total[0] -= 1
                    put("E %s %s" % (uid, ofs))
        except Exception:
            pass
        finally:
            w.close()

    srv = await asyncio.start_server(handle, "127.0.0.1", lport, ssl=ctx, limit=1 << 20)
    async with srv:
        await srv.serve_forever()


def _conn(port, host):
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=15), server_hostname=host)


def _status(s):
    buf = b""
    while b"\r\n" not in buf:
        d = s.recv(4096)
        if not d:
            return 0
        buf += d
    return int(buf.split(b" ")[1])


def _req(port, host, path, n, ticket):
    h = "PUT %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n" % (path, host, n)
    if ticket:
        h += "X-Fm-Ticket: %s\r\n" % ticket
    return (h + "\r\n").encode()


def race_main(port, host, uid, atk_ticket, good_ticket, drip):
    out = {"a": 0}
    stop = [False]

    def attacker():
        s = _conn(port, host)
        s.sendall(_req(port, host, "/_fm/up/%s/0" % uid, 33554432, None if atk_ticket == "-" else atk_ticket))
        s.settimeout(0.2)
        t0 = time.time()
        while time.time() - t0 < drip and not stop[0]:
            try:
                s.sendall(b"x")
            except Exception:
                break
            try:
                d = s.recv(4096)
                if d and not out["a"]:
                    out["a"] = int(d.split(b" ")[1])
            except socket.timeout:
                pass
            except Exception:
                break
            time.sleep(0.5)
        s.close()

    t = threading.Thread(target=attacker)
    t.start()
    time.sleep(0.7)
    codes = []
    t0 = time.time()
    k = 1
    while time.time() - t0 < min(drip - 1.5, 6.0):
        s = _conn(port, host)
        s.sendall(_req(port, host, "/_fm/up/%s/%d" % (uid, k), 4096, good_ticket) + b"x" * 4096)
        codes.append(str(_status(s)))
        s.close()
        k += 1
        time.sleep(0.3)
    stop[0] = True
    t.join()
    print("saldirgan=%d mesru=%s" % (out["a"], ",".join(codes)))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "spawn":
        import subprocess
        lg = open(sys.argv[3], "ab")
        pr = subprocess.Popen([sys.executable, "-I", __file__] + sys.argv[4:], stdin=subprocess.DEVNULL, stdout=lg, stderr=lg,
                              start_new_session=True)
        with open(sys.argv[2], "w") as f:
            f.write("%d\n" % pr.pid)
        sys.exit(0)
    if mode == "race":
        race_main(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6], float(sys.argv[7]))
    elif mode == "slowsink":
        asyncio.run(slowsink_main(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5], float(sys.argv[6])))
    else:
        sys.exit(2)
