#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise the actual netifd shell functions with temporary files and fake CLI."""
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile

source = Path(__file__).resolve().parents[2] / "mtwifi-cfg/files/netifd/mtwifi.sh"
text = source.read_text()
functions = "\n".join(
    re.search(r"^" + name + r"\(\) \{.*?^\}", text, re.M | re.S).group()
    for name in ("mtwifi_hostapd_start", "mtwifi_hostapd_stop", "mtwifi_wpas_conf")
)
count = 0


def expect(value, label):
    global count
    assert value, label
    count += 1
    print(f"ok {count} - {label}")


with tempfile.TemporaryDirectory(prefix="easymesh-netifd-") as directory:
    root = Path(directory)
    runtime = root / "var/run"
    control = runtime / "hostapd"
    control.mkdir(parents=True)
    (root / "etc/map").mkdir(parents=True)
    cli = root / "hostapd_cli"
    cli.write_text("""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['MESH_TEST_ROOT'])
with (root / 'commands').open('a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
print('FAIL' if os.environ.get('CLI_FAIL') else 'OK')
""")
    cli.chmod(0o755)
    functions = functions.replace("/var/run", str(runtime)).replace("/etc/map", str(root / "etc/map"))
    functions = functions.replace("/usr/sbin/hostapd_cli", str(cli))
    stubs = """
json_select() { :; }
json_get_vars() { :; }
mtwifi_resolve_phy() { echo phy7; }
logger() { :; }
map_mode=1
"""
    environment = dict(os.environ, MESH_TEST_ROOT=directory)

    def run(body, **extra):
        return subprocess.run(["sh", "-c", functions + stubs + body], env=dict(environment, **extra),
                              capture_output=True, text=True)

    def commands():
        return [json.loads(line) for line in (root / "commands").read_text().splitlines()]

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sock.bind(str(control / "global"))
    conf = runtime / "hostapd-ra0.conf"
    conf.write_text("interface=ra1\ndriver=nl80211\nssid=test\nbss=ra2\nssid=second\n")
    result = run("mtwifi_hostapd_start ra0")
    expect(result.returncode == 0, "MAP hostapd starts through the global socket")
    expect(commands()[0][-2:] == ["REMOVE", "ra1"], "disabled ra0 does not replace the first active AP")
    expect(commands()[1][-2:] == ["ADD", f"bss_config=phy7:{conf}"], "hostapd ADD uses the resolved PHY")
    expect(all((control / f"hostapd-{name}.conf").resolve() == conf for name in ("ra1", "ra2")),
           "each BSS has the runtime path expected by wapp")
    result = run("mtwifi_hostapd_stop ra0")
    expect(result.returncode == 0 and commands()[-1][-2:] == ["REMOVE", "ra1"] and not conf.exists(),
           "MAP stop removes the first active AP and its configuration")
    expect(not any(control.glob("hostapd-*.conf")), "MAP stop removes per-BSS aliases")
    conf.write_text("interface=ra1\ndriver=nl80211\nssid=test\n")
    expect(run("mtwifi_hostapd_start ra0", CLI_FAIL="1").returncode != 0,
           "hostapd ADD rejection reaches netifd")

    station = runtime / "wpa.conf"
    quoted = shlex.quote(str(station))
    result = run(f'ssid=""; encryption=none; mtwifi_wpas_conf apcli0 {quoted}')
    expect(result.returncode == 0 and "network={" not in station.read_text() and "wps_cred_processing=1" in station.read_text(),
           "unconfigured bSTA waits for onboarding without an empty SSID network")
    expect(station.stat().st_mode & 0o777 == 0o600, "supplicant credentials are private")
    saved = root / "etc/map/backhaul-apcli0.conf"
    saved.write_text('update_config=1\nnetwork={\n ssid="learned mesh"\n psk="learned=password"\n}\n')
    result = run(f'ssid=""; encryption=none; mtwifi_wpas_conf apcli0 {quoted}')
    expect(result.returncode == 0 and station.read_bytes() == saved.read_bytes(),
           "wireless reload restores learned backhaul credentials exactly")
    saved.unlink()
    result = run(f'ssid="configured mesh"; key="safe=password"; encryption=psk2; mtwifi_wpas_conf apcli0 {quoted}')
    expect(result.returncode == 0 and "multi_ap_backhaul_sta=1" in station.read_text() and 'psk="safe=password"' in station.read_text(),
           "configured bSTA retains its password and Multi-AP role")
    sock.close()

print(f"1..{count}")
