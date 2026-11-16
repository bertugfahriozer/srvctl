#!/usr/bin/env python3
"""test_edge_up_h2win_real.sh laboratuvar yardımcısı (yalnız Python stdlib, yalnız 127.0.0.1).

  delay  <dinle_port> <hedef_port> <tek_yon_ms> : kullanıcı alanı GECİKME VEKİLİ. Her yönde sabit gecikme, bant sınırı YOK,
                                                  bayt sırası korunur (WAN RTT'sini = 2 x tek_yon_ms taklit eder).
  sink   <dinle_port> <cert> <key> <kayıt>      : sahte pCloud — TLS, Content-Length kadar gövdeyi HIZLA yutar, 200 döner,
                                                  her istek için "bayt süre_sn" satırı kayda eklenir.
  spawn  <pidfile> <logfile> <mod> <arg...>     : yukarıdakilerden birini AYRIK süreç olarak başlatır (kabukta '&' gerekmez),
                                                  PID'i pidfile'a yazar ve hemen döner.
Süreç SIGTERM ile sonlanır (betik PID ile öldürür).
"""
import asyncio
import ssl
import sys
import time


async def _pump(reader, writer, delay):
    q = asyncio.Queue()

    async def rd():
        try:
            while True:
                d = await reader.read(65536)
                await q.put((time.monotonic() + delay, d))
                if not d:
                    return
        except Exception:
            await q.put((time.monotonic(), b""))

    async def wr():
        try:
            while True:
                due, d = await q.get()
                w = due - time.monotonic()
                if w > 0:
                    await asyncio.sleep(w)
                if not d:
                    break
                writer.write(d)
                await writer.drain()
        except Exception:
            pass
        finally:
            try:
                writer.close()
            except Exception:
                pass

    await asyncio.gather(rd(), wr())


async def delay_main(lport, tport, ms):
    delay = ms / 1000.0

    async def handle(cr, cw):
        await asyncio.sleep(delay)
        try:
            ur, uw = await asyncio.open_connection("127.0.0.1", tport)
        except Exception:
            cw.close()
            return
        await asyncio.gather(_pump(cr, uw, delay), _pump(ur, cw, delay))

    srv = await asyncio.start_server(handle, "127.0.0.1", lport, limit=1 << 20)
    async with srv:
        await srv.serve_forever()


async def sink_main(lport, cert, key, log):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)

    async def handle(r, w):
        try:
            while True:
                head = await r.readuntil(b"\r\n\r\n")
                n = 0
                for ln in head.split(b"\r\n"):
                    if ln.lower().startswith(b"content-length:"):
                        n = int(ln.split(b":", 1)[1])
                t0 = time.monotonic()
                got = 0
                while got < n:
                    d = await r.read(min(1 << 20, n - got))
                    if not d:
                        break
                    got += len(d)
                with open(log, "a") as f:
                    f.write("%d %.3f\n" % (got, time.monotonic() - t0))
                body = b'{"result":0}'
                w.write(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nContent-Type: application/json\r\n\r\n" % len(body) + body)
                await w.drain()
        except Exception:
            pass
        finally:
            w.close()

    srv = await asyncio.start_server(handle, "127.0.0.1", lport, ssl=ctx, limit=1 << 20)
    async with srv:
        await srv.serve_forever()


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
    if mode == "delay":
        asyncio.run(delay_main(int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])))
    elif mode == "sink":
        asyncio.run(sink_main(int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]))
    else:
        sys.exit(2)
