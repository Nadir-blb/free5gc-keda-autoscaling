#!/usr/bin/env python3
"""
GTP-U throughput exporter for free5GC UPF.
Reads /proc/net/dev for the upfgtp interface and exposes
bytes_in/bytes_out as Prometheus metrics.
"""
import time, sys
from http.server import HTTPServer, BaseHTTPRequestHandler

IFACE = "upfgtp"
PORT  = 9090

def read_iface_stats(iface):
    with open("/proc/net/dev") as f:
        for line in f:
            if iface in line:
                parts = line.split()
                # columns: iface rx_bytes rx_packets ... tx_bytes ...
                rx_bytes = int(parts[1])
                tx_bytes = int(parts[9])
                return rx_bytes, tx_bytes
    return 0, 0

prev_rx, prev_tx = read_iface_stats(IFACE)
prev_time = time.time()

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        global prev_rx, prev_tx, prev_time
        if self.path != "/metrics":
            self.send_response(404); self.end_headers(); return

        now = time.time()
        rx, tx = read_iface_stats(IFACE)
        dt = max(now - prev_time, 0.001)

        rx_rate = (rx - prev_rx) / dt
        tx_rate = (tx - prev_tx) / dt
        prev_rx, prev_tx, prev_time = rx, tx, now

        body = f"""# HELP upf_gtpu_rx_bytes_per_second GTP-U uplink bytes per second
# TYPE upf_gtpu_rx_bytes_per_second gauge
upf_gtpu_rx_bytes_per_second {rx_rate:.2f}
# HELP upf_gtpu_tx_bytes_per_second GTP-U downlink bytes per second
# TYPE upf_gtpu_tx_bytes_per_second gauge
upf_gtpu_tx_bytes_per_second {tx_rate:.2f}
# HELP upf_gtpu_rx_bytes_total GTP-U uplink bytes total
# TYPE upf_gtpu_rx_bytes_total counter
upf_gtpu_rx_bytes_total {rx}
# HELP upf_gtpu_tx_bytes_total GTP-U downlink bytes total
# TYPE upf_gtpu_tx_bytes_total counter
upf_gtpu_tx_bytes_total {tx}
""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
