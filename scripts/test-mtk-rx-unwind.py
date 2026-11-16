#!/usr/bin/env python3
"""Fault-inject the prepared MTK RX allocator and cleanup with ASan/UBSan.

Only allocation, device I/O and DMA operations are mocked. The allocator
and teardown functions come directly from the final patched kernel source.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--kernel-dir', required=True, type=Path)
args = parser.parse_args()
source = (args.kernel_dir / 'drivers/net/ethernet/mediatek/mtk_eth_soc.c').read_text()
def function(name):
    m=re.search(r'static[\w\s*]+\b'+name+r'\([^;{]*\)\s*\{',source)
    assert m,name
    end=source.index('{',m.start())+1;depth=1
    while depth:
        depth+=(source[end]=='{')-(source[end]=='}');end+=1
    return source[m.start():end]+'\n'
base=r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
typedef uint64_t u64;
typedef uint64_t dma_addr_t;
typedef uint32_t u32;
#define MTK_RX_FLAGS_NORMAL 0
#define MTK_RX_FLAGS_QDMA 1
#define MTK_RX_FLAGS_HWLRO 2
#define MTK_MAX_LRO_RX_LENGTH 4096
#define MTK_HW_LRO_DMA_SIZE 4
#define ETH_DATA_LEN 1500
#define GFP_KERNEL 0
#define PAGE_SIZE 4096
#define NET_SKB_PAD 32
#define DMA_FROM_DEVICE 0
#define MTK_SRAM 2
#define MTK_36BIT_DMA 4
#define MTK_SOC_MT7628 8
#define MTK_QRX_OFFSET 16
#define MTK_PST_DRX_IDX_CFG(i) (1U<<(i))
#define MTK_HAS_CAPS(c,m) ((c)&(m))
#define RX_DMA_LSO 1
#define RX_DMA_PREP_PLEN0(v) (v)
#define RX_DMA_PREP_ADDR64(v) (((v) >> 32) & 0xf)
#define RX_DMA_GET_ADDR64(v) (((u64)(v) & 0xf) << 32)
#define IS_ERR(p) ((uintptr_t)(p)>(uintptr_t)-4096)
#define PTR_ERR(p) ((intptr_t)(p))
#define rcu_access_pointer(p) (p)
#define unlikely(p) (p)
#define wmb() ((void)0)
struct mtk_rx_dma {u32 rxd1,rxd2;};
struct mtk_rx_dma_v2 {u32 rxd1,rxd2,rxd3,rxd4,rxd5,rxd6,rxd7,rxd8;};
struct xdpq {bool registered;};
struct page_pool {int unused;};
struct mtk_rx_ring {
    void **data,*dma;
    dma_addr_t phys;
    int dma_size,frag_size,buf_size,calc_idx,crx_idx_reg,ring_no;
    bool in_sram,calc_idx_update;
    struct page_pool *page_pool;
    struct xdpq xdp_q;
};
struct mtk_tx_ring {void *dma;dma_addr_t phys;};
struct mtk_reg_map {struct {int qcrx_ptr,rx_ptr,rx_cnt_cfg,rst_idx;} qdma;struct {int pcrx_ptr,rx_ptr,rx_cnt_cfg,rst_idx;} pdma;};
struct mtk_soc_data {
    const struct mtk_reg_map *reg_map;
    unsigned caps;
    struct {int dma_size,desc_size;} tx,rx;
};
struct mtk_eth {
    const struct mtk_soc_data *soc;
    struct mtk_tx_ring tx_ring;
    struct mtk_rx_ring rx_ring[2],rx_ring_qdma;
    int version,ip_align;
    void *prog,*dma_dev;
};
static int live_arrays,live_dma,live_packets,live_pools,live_maps;
static dma_addr_t dma_base;
static unsigned expected_descriptor_bytes;
static int fail_array,fail_pool,fail_dma,fail_packet,fail_map,packet_calls,map_calls,mmio;
static int mtk_max_frag_size(struct mtk_eth *e,int n){return 2048;}
static int mtk_max_buf_size(struct mtk_eth *e,int n){return 1536;}
static void *kcalloc(int n,int size,int flags){if(fail_array)return NULL;live_arrays++;return calloc(n,size);}
static void kfree(void *p){if(p){live_arrays--;free(p);}}
static bool mtk_page_pool_enabled(struct mtk_eth *e){return e->version>=2;}
static struct page_pool *mtk_create_page_pool(struct mtk_eth *e,struct xdpq*q,int id,int size)
{if(fail_pool)return (void *)(intptr_t)-ENOMEM;live_pools++;q->registered=true;return calloc(1,sizeof(struct page_pool));}
static bool mtk_validate_sram_range(struct mtk_eth *e,u64 addr,unsigned n){return false;}
static void *dma_alloc_coherent(void *d,unsigned n,dma_addr_t *a,int flags)
{if(fail_dma)return NULL;live_dma++;*a=0x10000;return calloc(1,n);}
static void dma_free_coherent(void *d,unsigned n,void *p,dma_addr_t a)
{assert(n==expected_descriptor_bytes);live_dma--;free(p);}
static void *packet(void)
{packet_calls++;if(fail_packet==packet_calls)return NULL;live_packets++;return malloc(2048);}
static void *netdev_alloc_frag(int n){return packet();}
static void *mtk_max_buf_alloc(int n,int flags){return packet();}
static void skb_free_frag(void *p){live_packets--;free(p);}
static void *mtk_page_pool_get_buff(struct page_pool *p,dma_addr_t *a,int flags)
{void *data=packet();*a=dma_base+(packet_calls-1)*0x1000;return data;}
static dma_addr_t dma_map_single(void *d,void *p,unsigned n,int dir)
{map_calls++;if(fail_map==map_calls)return UINT64_MAX;live_maps++;return dma_base+(map_calls-1)*0x1000;}
static bool dma_mapping_error(void *d,dma_addr_t a){return a==UINT64_MAX;}
static void dma_unmap_single(void*d,u64 a,unsigned n,int dir)
{assert(a>=dma_base && a<dma_base+4*0x1000 && (a-dma_base)%0x1000==0);live_maps--;assert(live_maps>=0);}
static void mtk_rx_put_buff(struct mtk_rx_ring*r,void*p,bool napi){live_packets--;free(p);}
static bool xdp_rxq_info_is_reg(struct xdpq*q){return q->registered;}
static void xdp_rxq_info_unreg(struct xdpq*q){q->registered=false;}
static void page_pool_destroy(struct page_pool*p){live_pools--;free(p);}
static bool mtk_is_netsys_v3_or_greater(struct mtk_eth*e){return e->version>=3;}
static void mtk_w32(struct mtk_eth*e,u64 value,unsigned reg){mmio++;}
'''
checks=r'''
int main(void)
{
    struct mtk_reg_map map={0};
    struct mtk_soc_data soc={.reg_map=&map,.tx={.dma_size=4,.desc_size=16},.rx={.dma_size=4,.desc_size=sizeof(struct mtk_rx_dma_v2)}};
    unsigned cases=0;
    const dma_addr_t addresses[]={0x1000,0,0x100000000ULL};
    for(int generation=1;generation<=3;generation++)for(int pool=0;pool<2;pool++)for(int address=0;address<(generation==1?2:3);address++)for(int stage=0;stage<12;stage++){
        struct mtk_eth e={.soc=&soc,.version=generation,.prog=pool?(void*)1:NULL};
        dma_base=addresses[address];
        soc.caps=generation>=2?MTK_36BIT_DMA:0;
        soc.rx.desc_size=generation>=3?32:16;
        expected_descriptor_bytes=4*soc.rx.desc_size;
        fail_array=stage==1;fail_pool=stage==2;fail_dma=stage==3;
        fail_packet=stage>=4&&stage<=7?stage-3:0;
        fail_map=stage>=8?stage-7:0;
        packet_calls=map_calls=mmio=0;
        assert(!live_arrays&&!live_dma&&!live_packets&&!live_pools&&!live_maps);
        bool pooled=pool&&generation>=2;
        int rc=mtk_rx_alloc(&e,0,MTK_RX_FLAGS_NORMAL);
        bool failure=fail_array||(pooled&&fail_pool)||fail_dma||fail_packet||(!pooled&&fail_map);
        assert(rc==(failure?-ENOMEM:0));
        assert((mmio==0)==failure);
        mtk_rx_clean(&e,&e.rx_ring[0],false);
        mtk_rx_clean(&e,&e.rx_ring[0],false);
        assert(!live_arrays&&!live_dma&&!live_packets&&!live_pools&&!live_maps);
        assert(!e.rx_ring[0].data&&!e.rx_ring[0].dma&&!e.rx_ring[0].page_pool);
        cases++;
    }
    printf("PASS: %u actual RX allocation/unwind cases, Netsys 1/2/3, pooled/plain DMA, zero/4-GiB DMA addresses, every packet/map failure point and repeated cleanup\n",cases);
}
'''
with tempfile.TemporaryDirectory(prefix='mtk-rx-unwind-') as tmp:
    w = Path(tmp)
    (w/'rx_alloc.c').write_text(base+function('mtk_rx_alloc')+function('mtk_rx_clean')+checks)
    subprocess.run(['cc','-std=gnu99','-O1','-g','-no-pie','-fsanitize=address,undefined','-fno-omit-frame-pointer',str(w/'rx_alloc.c'),'-o',str(w/'rx_alloc')],check=True)
    subprocess.run([str(w/'rx_alloc')],check=True)
