#!/usr/bin/env python3
"""Run native boundary tests against the prepared iwinfo and rpcd functions.

Only device I/O and ubus transport are mocked. Compile the target packages
separately; these tests exercise lengths, initialization and serialization.
"""
import argparse
import re
from pathlib import Path
import subprocess
import tempfile


def function(source, name):
    match = re.search(r"static[\w\s*]+\b" + re.escape(name)
                      + r"\([^;{]*\)\s*\{", source)
    assert match, name
    start = match.start()
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--iwinfo-dir", required=True, type=Path)
parser.add_argument("--rpcd-dir", required=True, type=Path)
args = parser.parse_args()
iwinfo = args.iwinfo_dir.resolve()
rpcd = args.rpcd_dir.resolve()
mtk = (iwinfo / "iwinfo_mtk.c").read_text()
nl = (iwinfo / "iwinfo_nl80211.c").read_text()
rpc = (rpcd / "iwinfo.c").read_text()
assert ".max_count = IWINFO_ASSOCLIST_BUFSIZE / sizeof(struct iwinfo_assoclist_entry)" in nl
assert "arr->count >= arr->max_count" in function(nl, "nl80211_get_assoclist_cb")

preamble = r'''
#define _GNU_SOURCE
#define __IWINFO_UTILS_H_
#include "iwinfo.h"
#include "mtwifi.h"
/* vendor_structs */
#include <assert.h>
#include <stdbool.h>
#include <netinet/ether.h>

static int table_failure, count = MAX_NUMBER_OF_MAC;
static RT_802_11_MAC_TABLE *mtk_get_mac_table(const char *dev)
{
    if (table_failure) return NULL;
    RT_802_11_MAC_TABLE *t = calloc(1, sizeof(*t));
    assert(t);
    t->Num = count;
    for (int i = 0; i < count; i++) {
        t->Entry[i].Addr[5] = i;
        t->Entry[i].AvgRssi0 = -43;
        t->Entry[i].RxBytes = 1000 + i;
    }
    return t;
}
static size_t mtk_mac_table_count(RT_802_11_MAC_TABLE *t) { return t->Num; }
static void mtk_parse_rateinfo(RT_802_11_MAC_ENTRY *p,
                             struct iwinfo_rate_entry *rx,
                             struct iwinfo_rate_entry *tx)
{
    memset(rx, 0, sizeof(*rx)); memset(tx, 0, sizeof(*tx));
    rx->is_eht = tx->is_eht = 1;
    rx->nss = tx->nss = 2;
    rx->eht_dcm = tx->eht_dcm = 1;
}
static struct mtk_station_information vendor;
static int vendor_failure;
static int nl80211_get_mtk_sta_info(const char *dev, const unsigned char *mac,
                                  struct mtk_station_information *out)
{
    if (vendor_failure) return -1;
    *out = vendor; return 0;
}
'''

transport = r'''
struct ubus_context { int unused; };
struct ubus_object { int unused; };
struct ubus_request_data { int unused; };
struct blob_attr { const char *text; };
static struct { struct blob_attr *head; } buf;
enum { RPC_A_DEVICE, RPC_A_MACADDR, __RPC_A_MAX };
enum { UBUS_STATUS_OK, UBUS_STATUS_NOT_FOUND, UBUS_STATUS_UNKNOWN_ERROR };
static int rpc_assoclist_policy[__RPC_A_MAX];
static struct blob_attr device_attr = { "rai0" }, mac_attr = { "FF:FF:FF:FF:FF:FF" };
static int want_mac, closes, replies, mode, allocation_failure;
static int tables, mlo_fields, link_mask, dcm_fields, nss_fields;
static const struct iwinfo_ops *iw;
static char *ifname = "rai0";
static int fake_assoclist(const char *dev, char *out, int *len)
{
    int n = IWINFO_ASSOCLIST_BUFSIZE / sizeof(struct iwinfo_assoclist_entry);
    if (mode == 0) return mtk_get_assoclist(dev, out, len);
    if (mode == 1) {
        for (int i = 0; i < n; i++) {
            struct iwinfo_assoclist_entry *e = (void *)out + i * sizeof(*e);
            memset(e, 0, sizeof(*e));
            e->mac[0] = 2; e->mac[5] = i;
        }
        *len = n * sizeof(struct iwinfo_assoclist_entry);
    } else if (mode == 2) *len = -1;
    else if (mode == 3) *len = IWINFO_ASSOCLIST_BUFSIZE + 1;
    else if (mode == 4) *len = 1;
    else if (mode == 5) return -1; /* May leave len untouched. */
    else {
        struct iwinfo_assoclist_entry *e = (void *)out;
        memset(e, 0, sizeof(*e));
        e->mlo_enable = 1;
        e->mlo_num_links = mode == 6 ? 2 : 255;
        e->mlo_link_id = 1;
        e->mlo_rx_rate[1].is_eht = 1;
        e->mlo_tx_rate[2].is_eht = 1;
        *len = sizeof(*e);
    }
    return 0;
}
static const struct iwinfo_ops ops = { .assoclist = fake_assoclist };
static int __rpc_iwinfo_open(struct blob_attr *a) { iw = &ops; return 0; }
static void rpc_iwinfo_close(void) { closes++; }
static void *blob_data(struct blob_attr *m) { return m; }
static int blob_len(struct blob_attr *m) { return 0; }
static void *blobmsg_data(struct blob_attr *m) { return (void *)m->text; }
static void blobmsg_parse(const void *p, int n, struct blob_attr **tb, void *m, int l)
{ tb[RPC_A_DEVICE] = &device_attr; tb[RPC_A_MACADDR] = want_mac ? &mac_attr : NULL; }
static void blob_buf_init(void *b, int n)
{ tables = mlo_fields = link_mask = dcm_fields = nss_fields = 0; }
static void *blobmsg_open_table(void *b, const char *n)
{ if (!n) tables++; return (void *)1; }
static void *blobmsg_open_array(void *b, const char *n) { return (void *)1; }
static void blobmsg_close_table(void *b, void *p) {}
static void blobmsg_close_array(void *b, void *p) {}
static void blobmsg_add_string(void *b, const char *k, const char *v)
{ assert(strnlen(v, 4096) < 4096); }
static void number(const char *key, uint64_t value)
{
    if (!strcmp(key, "mlo_enable")) mlo_fields++;
    if (!strcmp(key, "eht_dcm")) dcm_fields++;
    if (!strcmp(key, "nss")) { assert(value > 0); nss_fields++; }
    assert(strcmp(key, "link_id") && strcmp(key, "mlo_link_id"));
    if (!strcmp(key, "link_index")) { assert(value < 3); link_mask |= 1 << value; }
}
#define blobmsg_add_u8(b,k,v) number(k,v)
#define blobmsg_add_u16(b,k,v) number(k,v)
#define blobmsg_add_u32(b,k,v) number(k,v)
#define blobmsg_add_u64(b,k,v) number(k,v)
static void ubus_send_reply(struct ubus_context *c, struct ubus_request_data *r,
                            struct blob_attr *m) { replies++; }
static void *rpc_calloc(size_t n, size_t size)
{ return allocation_failure ? NULL : calloc(n, size); }
#define calloc rpc_calloc
'''

checks = r'''
#undef calloc
static int query(void)
{
    int before = closes;
    int rc = rpc_iwinfo_assoclist(NULL, NULL, NULL, "assoclist", NULL);
    assert(closes == before + 1);
    return rc;
}
int main(void)
{
    size_t n = IWINFO_ASSOCLIST_BUFSIZE / sizeof(struct iwinfo_assoclist_entry);
    struct iwinfo_assoclist_entry *entries = malloc(IWINFO_ASSOCLIST_BUFSIZE);
    assert(entries && n <= MAX_NUMBER_OF_MAC);
    int len = -1;
    memset(entries, 0xa5, IWINFO_ASSOCLIST_BUFSIZE);
    assert(mtk_get_assoclist("rai0", (char *)entries, &len) == 0);
    assert(len == n * sizeof(*entries));
    for (size_t i = 0; i < n; i++) {
        assert(entries[i].mac[5] == (unsigned char)i);
        assert(entries[i].signal == -43 && entries[i].rx_bytes == 1000 + i);
        assert(entries[i].mlo_enable == 0 && entries[i].mlo_num_links == 0);
        assert(entries[i].plink_state[0] == 0 && entries[i].nonpeer_ps[0] == 0);
        assert(entries[i].is_authorized == 0 && entries[i].tx_failed == 0);
    }
    table_failure = 1; len = -1;
    assert(mtk_get_assoclist("rai0", (char *)entries, &len) == -1 && len == 0);
    table_failure = 0; free(entries);

    for (unsigned mask = 0; mask < 8; mask++) {
        struct iwinfo_assoclist_entry e = {0};
        memset(&vendor, 0, sizeof(vendor)); vendor.mlo_enable = 1;
        e.mac[5] = vendor.mac[5] = 2;
        e.rx_rate.is_eht = e.tx_rate.is_eht = 1;
        e.rx_rate.mcs = e.tx_rate.mcs = 13;
        e.rx_rate.nss = e.tx_rate.nss = 2;
        unsigned valid = 0;
        for (unsigned j = 0; j < 3; j++) {
            vendor.mlo_link[j].valid = !!(mask & (1 << j));
            vendor.mlo_link[j].link_address[5] = j + 1;
            vendor.mlo_link[j].rx_rate = 100 + j;
            vendor.mlo_link[j].tx_rate = 200 + j;
            if (vendor.mlo_link[j].valid) valid++;
        }
        nl80211_mtk_fill_mlo("rai0", &e);
        assert(e.mlo_num_links == valid && e.mlo_enable == !!valid);
        if (valid) assert(e.mlo_link_id == (mask & 2 ? 1 : UINT8_MAX));
        for (unsigned j = 0; j < 3; j++) {
            assert(e.mlo_rx_rate[j].is_eht == !!(mask & (1 << j)));
            if (mask & (1 << j)) {
                assert(e.mlo_rx_rate[j].rate == (100 + j) * 1000);
                assert(e.mlo_rx_rate[j].nss == (valid == 1 && j == 1 ? 2 : 0));
            }
        }
    }
    struct iwinfo_assoclist_entry e = {0};
    memset(&vendor, 0, sizeof(vendor)); vendor.mlo_enable = 1;
    vendor.mlo_link[2].valid = 1;
    vendor.mlo_link[2].rx_rate = UINT32_MAX;
    nl80211_mtk_fill_mlo("rai0", &e);
    assert(e.mlo_num_links == 1 && e.mlo_rx_rate[2].rate == 0);
    vendor.mac[5] = 99; memset(&e, 0, sizeof(e));
    nl80211_mtk_fill_mlo("rai0", &e); assert(e.mlo_enable == 0);
    vendor_failure = 1; memset(&e, 0, sizeof(e));
    nl80211_mtk_fill_mlo("rai0", &e); assert(e.mlo_enable == 0);

    mode = 0; assert(query() == UBUS_STATUS_OK && tables == n && !mlo_fields && dcm_fields == 2 * n);
    mode = 1; assert(query() == UBUS_STATUS_OK && tables == n);
    for (mode = 2; mode <= 4; mode++) assert(query() == UBUS_STATUS_UNKNOWN_ERROR);
    mode = 5; assert(query() == UBUS_STATUS_OK && tables == 0);
    mode = 6; assert(query() == UBUS_STATUS_OK && mlo_fields == 1 && link_mask == 6 && !nss_fields && !dcm_fields);
    mode = 7; assert(query() == UBUS_STATUS_OK && mlo_fields == 0);
    allocation_failure = 1; assert(query() == UBUS_STATUS_UNKNOWN_ERROR);
    allocation_failure = 0; mode = 1; want_mac = 1;
    assert(query() == UBUS_STATUS_NOT_FOUND);
    printf("PASS: %zu stations, WEXT initialization, 8 MLO masks, overflow, RPC lengths and cleanup\n", n);
    return 0;
}
'''

vendor_header = (iwinfo / "mtk_nl80211.h").read_text()
start = vendor_header.index("struct mtk_mlo_link_information {")
end = vendor_header.index("\n#define MODE_CCK", start)
preamble = preamble.replace("/* vendor_structs */", vendor_header[start:end])
code = (preamble + function(mtk, "mtk_get_assoclist")
        + function(nl, "nl80211_mtk_fill_mlo") + transport
        + function(rpc, "rpc_iwinfo_add_rateinfo")
        + function(rpc, "rpc_iwinfo_assoclist") + checks)
with tempfile.TemporaryDirectory(prefix="mtk-assoclist-") as tmp:
    source = Path(tmp) / "assoclist.c"
    binary = Path(tmp) / "assoclist"
    source.write_text(code)
    subprocess.run(["cc", "-std=gnu99", "-g", "-O1", "-no-pie",
                    "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
                    "-Werror=implicit-function-declaration", "-I", str(iwinfo / "include"),
                    "-I", str(iwinfo), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
