"""Run with PYTHONPATH=files python3 -m unittest discover -s tests."""
import copy
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from cryptography.exceptions import InvalidTag
import agent
import inform
import wlan

KEY = "0123456789abcdef0123456789abcdef"
WLAN = "0123456789abcdef01234567"
MAC = "02:00:00:00:00:01"
RAW_MAC = bytes.fromhex(MAC.replace(":", ""))
CONFIG = """wireless.1.id=0123456789abcdef01234567
wireless.1.parent=wifi1
wireless.1.devname=ath1
wireless.1.ssid=Test five
aaa.3.devname=ath1
aaa.3.ssid=Test five
aaa.3.wpa=2
aaa.3.wpa.key.1.mgmt=WPA-PSK
aaa.3.wpa.psk=only-a-fixture
"""


class Local:
    def __init__(self):
        self.snap = dict(ip="127.0.0.1", mac=MAC, url="http://127.0.0.1:8080/inform", wlan_id=WLAN,
                         sshd_port=22, aps=[], radios={c: dict(name=n, radio=c) for n, c in wlan.BANDS.items()},
                         bindings={"na": dict(device="saved5", section="be14_ucg_five", ssid="Old", observed="Old",
                                              encryption="psk2", key="old-fixture", ieee80211w="0")})
        self.writes = 0
        self.stuck = False

    def read(self, op, **data):
        if op == "snapshot":
            return copy.deepcopy(self.snap)
        assert op == "replace"
        for band, change in data["changes"].items():
            current = self.snap["bindings"][band]
            actual = {k: current[k] for k in wlan.FIELDS if k in current}
            if actual != change["before"]:
                raise ValueError("concurrent edit")
            for k in wlan.FIELDS:
                current.pop(k, None)
            current.update(change["after"])
        self.writes += 1

    def reload(self):
        if not self.stuck:
            for binding in self.snap["bindings"].values():
                binding["observed"] = binding["ssid"]
                binding["applied"] = {k: binding[k] for k in wlan.FIELDS if k in binding}


class AgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name, "persistent", "state.json")
        p = patch.object(agent, "STATE", self.path)
        p.start()
        self.addCleanup(p.stop)
        self.local = Local()

    def state(self):
        return agent.state_for(self.local.snap["url"])

    def provision(self):
        s = self.state()
        s["key"] = KEY
        agent.save(s)
        changes, expected = wlan.plan(wlan.sys_vaps(CONFIG, WLAN), self.local.snap, WLAN)
        s["pending"] = dict(changes=changes, expected=expected, version="rev1", wlan_id=WLAN)
        agent.save(s)
        return s

    def test_http_adoption_restart_and_provision(self):
        replies = [dict(_type="setparam", mgmt_cfg="authkey=" + KEY + "\nuse_aes_gcm=true"),
                   dict(_type="setparam", cfgversion="revision1", system_cfg=CONFIG),
                   dict(_type="noop", interval=9)]
        seen = []
        class Controller(BaseHTTPRequestHandler):
            def do_POST(handler):
                i = len(seen)
                key = KEY if i else inform.FACTORY_KEY
                data = handler.rfile.read(int(handler.headers["Content-Length"]))
                seen.append(inform.unpack(data, RAW_MAC, key, bool(i)))
                body = inform.packet(replies[i], RAW_MAC, key, bool(i))
                handler.send_response(200)
                handler.send_header("Content-Length", str(len(body)))
                handler.end_headers()
                handler.wfile.write(body)
            def log_message(handler, *args):
                pass
        srv = HTTPServer(("127.0.0.1", 0), Controller)
        thread = threading.Thread(target=srv.serve_forever, daemon=True)
        thread.start()
        self.local.snap["url"] = "http://127.0.0.1:%s/inform" % srv.server_port
        try:
            with patch.object(agent, "local", self.local.read), patch.object(agent, "reload_wifi", self.local.reload):
                agent.tick()
                self.assertEqual(self.state()["key"], KEY)
                self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
                agent.tick()
                self.assertEqual(self.state()["cfgversion"], "revision1")
                self.assertEqual(agent.tick(), 9)
        finally:
            srv.shutdown()
            thread.join()
            srv.server_close()
        self.assertTrue(seen[0]["default"])
        self.assertFalse(seen[1]["default"])
        self.assertEqual([x["radio"] for x in seen[1]["radio_table"]], ["ng", "na", "6e"])
        self.assertEqual(seen[2]["cfgversion"], "revision1")
        self.assertNotIn("only-a-fixture", json.dumps(seen))

    def test_restart_after_commit_and_repeated_push(self):
        s = self.provision()
        self.local.read("replace", changes=s["pending"]["changes"])
        agent.finish_pending(self.state(), self.local.read, self.local.reload, lambda _: None)
        self.assertEqual(self.state()["cfgversion"], "rev1")
        agent.handle(dict(_type="setparam", cfgversion="rev1", system_cfg=CONFIG), self.state(), self.local.snap, True)
        self.assertEqual(self.local.writes, 1)

    def test_stale_air_ssid_rolls_back(self):
        before = copy.deepcopy(self.local.snap["bindings"])
        s = self.provision()
        self.local.stuck = True
        with self.assertRaisesRegex(ValueError, "did not become active"):
            agent.finish_pending(s, self.local.read, self.local.reload, lambda _: None)
        self.assertEqual(self.state()["cfgversion"], "0")
        self.assertEqual(self.local.snap["bindings"], before)

    def test_repeated_config_with_stale_live_security_withholds_revision(self):
        state = self.provision()
        agent.finish_pending(state, self.local.read, self.local.reload, lambda _: None)
        self.local.snap["bindings"]["na"]["applied"]["key"] = "previous-fixture"
        with self.assertRaisesRegex(ValueError, "live settings"):
            agent.handle(dict(_type="setparam", cfgversion="rev2", system_cfg=CONFIG), state, self.local.snap, True)
        self.assertEqual(self.state()["cfgversion"], "rev1")
        self.assertEqual(self.local.writes, 1)

    def test_local_edit_is_preserved(self):
        s = self.provision()
        self.local.snap["bindings"]["na"]["key"] = "local-change"
        with self.assertRaisesRegex(ValueError, "concurrent"):
            agent.finish_pending(s, self.local.read, self.local.reload)
        self.assertEqual(self.local.writes, 0)
        self.assertIn("pending", self.state())

    def test_bootstrap_cannot_provision(self):
        s = self.state()
        agent.handle(dict(_type="setparam", system_cfg=CONFIG, mgmt_cfg="authkey=" + KEY), s, self.local.snap)
        self.assertEqual(self.local.writes, 0)
        self.assertEqual(self.state()["cfgversion"], "0")
        with self.assertRaises(ValueError):
            agent.state_for("http://127.0.0.2:8080/inform")

    def test_unbound_management_revision_and_authenticated_key_rotation(self):
        self.local.snap.update(wlan_id="", bindings={})
        state = self.state()
        agent.handle(dict(_type="setparam", mgmt_cfg="authkey=" + KEY + "\ncfgversion=adopt1"), state, self.local.snap)
        self.assertEqual(self.state()["cfgversion"], "adopt1")
        new = "fedcba9876543210fedcba9876543210"
        rotate = dict(_type="cmd", cmd="set-adopt", key=new, uri=state["url"])
        agent.handle(rotate, state, self.local.snap)
        self.assertEqual(self.state()["key"], KEY)
        agent.handle(rotate, state, self.local.snap, True)
        self.assertEqual(self.state()["key"], new)
        self.assertEqual(self.local.writes, 0)

    def test_three_band_and_policy(self):
        rows = wlan.sys_vaps(CONFIG, WLAN)
        self.assertEqual(rows[0]["radio"], "na")
        for n, c in wlan.BANDS.items():
            snap = copy.deepcopy(self.local.snap)
            snap["bindings"] = {c: next(iter(snap["bindings"].values()))}
            row = dict(rows[0], radio=c, security="sae")
            changes, expect = wlan.plan([row], snap, WLAN)
            self.assertEqual(changes[c]["after"]["ieee80211w"], "2")
            self.assertEqual(expect[c]["settings"]["ssid"], "Test five")
        for text in (CONFIG.replace("WPA-PSK", "WPA-EAP"), CONFIG + "aaa.3.wpa.psk_file.status=enabled\n",
                     CONFIG + "wireless.1.is_guest=true\n"):
            with self.assertRaises(ValueError):
                wlan.sys_vaps(text, WLAN)
        for invalid in (dict(rows[0], radio="6e"), dict(rows[0], vlan_id=2),
                        dict(rows[0], essid="x"*33), dict(rows[0], x_passphrase=None),
                        dict(rows[0], hide_ssid="unknown"), dict(rows[0], enabled="false")):
            with self.assertRaises(ValueError):
                wlan.plan([invalid], self.local.snap, WLAN)

    def test_framing(self):
        msg = {"_type": "noop"}
        for gcm in (False, True):
            body = inform.packet(msg, RAW_MAC, KEY, gcm)
            self.assertEqual(inform.unpack(body, RAW_MAC, KEY, gcm), msg)
            with self.assertRaises(ValueError):
                inform.unpack(body, bytes(6), KEY)
            with self.assertRaises(ValueError):
                inform.unpack(body + b"x", RAW_MAC, KEY)
            if gcm:
                with self.assertRaises(InvalidTag):
                    inform.unpack(body[:-1] + bytes([body[-1] ^ 1]), RAW_MAC, KEY, True)
            else:
                with self.assertRaises(ValueError):
                    inform.unpack(body, RAW_MAC, KEY, True)
        self.assertEqual(inform.snappy(bytes([5, 0, 65, 1, 1])), b"AAAAA")
        for bad in (b"", bytes([1, 1, 0]), bytes([128])*5, bytes([20, 0, 65])):
            with self.assertRaises(ValueError):
                inform.snappy(bad)
