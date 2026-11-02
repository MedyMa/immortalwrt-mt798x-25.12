// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (C) 2023 MediaTek Inc.
 *
 * Author: Chris.Chou <chris.chou@mediatek.com>
 *         Ren-Ting Wang <ren-ting.wang@mediatek.com>
 */

#include <linux/bitops.h>
#include <linux/spinlock.h>
#include <linux/netdevice.h>
#include <linux/module.h>
#include <net/gso.h>
#include <net/icmp.h>
#include <net/neighbour.h>
#include <net/ip6_route.h>

#include <mtk_eth_soc.h>

#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
#include <mtk_hnat/hnat.h>
#include <mtk_hnat/nf_hnat_mtk.h>
#elif defined(CONFIG_CRYPTO_OFFLOAD_INLINE_FLOWBLOCK)
#include <mtk_ppe.h>
#endif

#include <pce/cdrt.h>
#include <pce/cls.h>
#include <pce/netsys.h>

#include <crypto-eip/ddk/kit/iotoken/iotoken.h>
#include <crypto-eip/ddk/kit/iotoken/iotoken_ext.h>

#include "crypto-eip/crypto-eip.h"
#include "crypto-eip/ddk-wrapper.h"
#include "crypto-eip/internal.h"

static struct xfrm_params_list xfrm_params_list = {
	.list = LIST_HEAD_INIT(xfrm_params_list.list),
	.lock = __SPIN_LOCK_UNLOCKED(xfrm_params_list.lock),
};

#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
extern int (*ra_sw_nat_hook_tx)(struct sk_buff *skb, int gmac_no);

static inline bool is_tops_tunnel(struct sk_buff *skb)
{
	return skb_hnat_tops(skb) && (ntohs(skb->protocol) == ETH_P_IP) &&
		(ip_hdr(skb)->protocol == IPPROTO_UDP ||
		 ip_hdr(skb)->protocol == IPPROTO_GRE);
}

static inline bool is_hnat_rate_reach(struct sk_buff *skb)
{
	return is_magic_tag_valid(skb) && (skb_hnat_reason(skb) == HIT_UNBIND_RATE_REACH);
}
#endif // HNAT

#if defined(CONFIG_CRYPTO_OFFLOAD_INLINE_FLOWBLOCK)
int mtk_crypto_xfrm_get_cdrt(struct xfrm_state *xs)
{
	struct mtk_xfrm_params *xfrm_params;
	struct mtk_xfrm_params *temp;

	xfrm_params = (struct mtk_xfrm_params *)xs->xso.offload_handle;

	if (!xfrm_params)
		return 0;

	spin_lock_bh(&xfrm_params_list.lock);
	list_for_each_entry(temp, &xfrm_params_list.list, node) {
		if (xfrm_params == temp && temp->xs == xs) {
			int idx = temp->active ? temp->cdrt->idx : 0;

			spin_unlock_bh(&xfrm_params_list.lock);
			return idx;
		}
	}
	spin_unlock_bh(&xfrm_params_list.lock);

	return 0;
}
#endif // Flow_Block

void mtk_crypto_decrypt_sec_path_setup(struct sk_buff *skb, u16 cdrt)
{
	struct mtk_xfrm_params *xfrm_params;
	struct xfrm_state *x = NULL;
	struct xfrm_offload *xo;
	struct sec_path *sp;

	if (!cdrt)
		return;

	spin_lock_bh(&xfrm_params_list.lock);
	list_for_each_entry(xfrm_params, &xfrm_params_list.list, node) {
		if (cdrt == xfrm_params->cdrt->idx) {
			if (xfrm_params->active &&
			    xfrm_params->xs->km.state == XFRM_STATE_VALID &&
			    xfrm_params->xs->xso.type == XFRM_DEV_OFFLOAD_PACKET &&
			    xfrm_params->xs->xso.dir == XFRM_DEV_OFFLOAD_IN) {
				x = xfrm_params->xs;
				xfrm_state_hold(x);
			}
			break;
		}
	}
	spin_unlock_bh(&xfrm_params_list.lock);

	if (!x)
		return;

	/* only attach secpath for resolved states, an empty secpath
	 * (len == 0) makes xfrm_input_state() read xvec[-1]
	 */
	sp = secpath_set(skb);
	if (!sp || sp->len >= XFRM_MAX_OFFLOAD_DEPTH) {
		xfrm_state_put(x);
		return;
	}

	sp->xvec[sp->len++] = x;
	sp->olen++;
	xo = xfrm_offload(skb);
	if (!xo) {
		secpath_reset(skb);
		return;
	}
	xo->flags = CRYPTO_DONE;
	xo->status = CRYPTO_SUCCESS;
}

struct xfrm_params_list *mtk_xfrm_params_list_get(void)
{
	return &xfrm_params_list;
}

static void mtk_xfrm_offload_cdrt_tear_down(struct mtk_xfrm_params *xfrm_params)
{
	if (!xfrm_params->cdrt)
		return;

	memset(&xfrm_params->cdrt->desc, 0, sizeof(struct cdrt_desc));

	mtk_pce_cdrt_entry_write(xfrm_params->cdrt);
}

static int mtk_xfrm_offload_cdrt_setup(struct mtk_xfrm_params *xfrm_params)
{
	struct cdrt_desc *cdesc = &xfrm_params->cdrt->desc;

	cdesc->desc1.common.type = 3;
	cdesc->desc1.token_len = 48;
	/* All use small transform record now */
	cdesc->desc1.p_tr[0] = lower_32_bits(xfrm_params->tr_dma) | xfrm_params->tr_type;
	cdesc->desc1.p_tr[1] = upper_32_bits(xfrm_params->tr_dma);

	cdesc->desc2.hw_srv = 3;
	cdesc->desc2.allow_pad = 1;
	cdesc->desc2.strip_pad = 1;

	return mtk_pce_cdrt_entry_write(xfrm_params->cdrt);
}

static void mtk_xfrm_offload_cls_entry_tear_down(struct mtk_xfrm_params *xfrm_params)
{
	if (!xfrm_params->cdrt || !xfrm_params->cdrt->cls)
		return;

	memset(&xfrm_params->cdrt->cls->cdesc, 0, sizeof(struct cls_desc));

	mtk_pce_cls_entry_write(xfrm_params->cdrt->cls);

	mtk_pce_cls_entry_free(xfrm_params->cdrt->cls);
	xfrm_params->cdrt->cls = NULL;
}

static int mtk_xfrm_offload_cls_entry_setup(struct mtk_xfrm_params *xfrm_params)
{
	struct cls_desc *cdesc;
	struct xfrm_state *xs = xfrm_params->xs;
	int ppe_port, ret;

	xfrm_params->cdrt->cls = mtk_pce_cls_entry_alloc();
	if (IS_ERR(xfrm_params->cdrt->cls)) {
		ret = PTR_ERR(xfrm_params->cdrt->cls);
		xfrm_params->cdrt->cls = NULL;
		return ret;
	}

	cdesc = &xfrm_params->cdrt->cls->cdesc;

	if (READ_ONCE(mac_filter_enable)) {
		CLS_DESC_DATA(cdesc, fport, PSE_PORT_TDMA);
		CLS_DESC_DATA(cdesc, tport_idx, 0x3);
	} else {
		ppe_port = mtk_crypto_ppe_get_num(xs->xso.dev);
		if (ppe_port < 0) {
			mtk_pce_cls_entry_free(xfrm_params->cdrt->cls);
			xfrm_params->cdrt->cls = NULL;
			return ppe_port;
		}
		CLS_DESC_DATA(cdesc, fport, ppe_port);
		CLS_DESC_DATA(cdesc, tport_idx, 0x2);
	}
	CLS_DESC_DATA(cdesc, cdrt_idx, xfrm_params->cdrt->idx);

	if (xs->encap) {
		CLS_DESC_MASK_DATA(cdesc, tag,
			   CLS_DESC_TAG_MASK, CLS_DESC_TAG_MATCH_L4_USR);
		CLS_DESC_MASK_DATA(cdesc, l4_type,
				CLS_DESC_L4_TYPE_MASK, IPPROTO_UDP);
		CLS_DESC_MASK_DATA(cdesc, l4_valid,
			   CLS_DESC_L4_VALID_MASK,
			   CLS_DESC_VALID_UPPER_HALF_WORD_BIT |
			   CLS_DESC_VALID_LOWER_HALF_WORD_BIT |
			   CLS_DESC_VALID_DPORT_BIT);
		CLS_DESC_MASK_DATA(cdesc, l4_dport, CLS_DESC_L4_DPORT_MASK,
							be16_to_cpu(xs->encap->encap_dport));
	} else {
		CLS_DESC_MASK_DATA(cdesc, tag,
			   CLS_DESC_TAG_MASK, CLS_DESC_TAG_MATCH_L4_HDR);
		CLS_DESC_MASK_DATA(cdesc, l4_udp_hdr_nez,
			   CLS_DESC_UDPLITE_L4_HDR_NEZ_MASK,
			   CLS_DESC_UDPLITE_L4_HDR_NEZ_MASK);
		CLS_DESC_MASK_DATA(cdesc, l4_type,
			   CLS_DESC_L4_TYPE_MASK, IPPROTO_ESP);
		CLS_DESC_MASK_DATA(cdesc, l4_valid,
			   0x3,
			   CLS_DESC_VALID_UPPER_HALF_WORD_BIT |
			   CLS_DESC_VALID_LOWER_HALF_WORD_BIT);
	}

	CLS_DESC_MASK_DATA(cdesc, l4_hdr_usr_data,
					0xFFFFFFFF, be32_to_cpu(xfrm_params->xs->id.spi));

	ret = mtk_pce_cls_entry_write(xfrm_params->cdrt->cls);
	if (ret)
		mtk_xfrm_offload_cls_entry_tear_down(xfrm_params);
	return ret;
}

static void mtk_xfrm_offload_context_tear_down(struct mtk_xfrm_params *xfrm_params)
{
	mtk_xfrm_offload_cdrt_tear_down(xfrm_params);
	if (xfrm_params->p_handle) {
		mtk_ddk_invalidate_rec(xfrm_params->p_handle, true);
		crypto_free_sa(xfrm_params->p_handle, 0);
		xfrm_params->p_handle = NULL;
	}
}

/* Policies and in-flight submitters keep the CDRT index reserved until
 * their last reference is released, including during device flush/rekey.
 */
static void mtk_xfrm_params_put(struct mtk_xfrm_params *params)
{
	if (!refcount_dec_and_test(&params->refs))
		return;
	mtk_xfrm_offload_cls_entry_tear_down(params);
	mtk_xfrm_offload_context_tear_down(params);
	mtk_pce_cdrt_entry_free(params->cdrt);
	kfree(params);
	module_put(THIS_MODULE);
}

static int mtk_xfrm_offload_context_setup(struct mtk_xfrm_params *xfrm_params)
{
	void *tr;
	int ret;

	switch (xfrm_params->xs->outer_mode.encap) {
	case XFRM_MODE_TUNNEL:
		tr = mtk_ddk_tr_ipsec_build(xfrm_params, SAB_IPSEC_TUNNEL);
		break;
	case XFRM_MODE_TRANSPORT:
		tr = mtk_ddk_tr_ipsec_build(xfrm_params, SAB_IPSEC_TRANSPORT);
		break;
	default:
		ret = -ENOMEM;
		goto err_out;
	}

	if (!tr) {
		ret = -EINVAL;
		goto err_out;
	}

	xfrm_params->p_tr = tr;

	ret = mtk_xfrm_offload_cdrt_setup(xfrm_params);
	if (ret)
		mtk_xfrm_offload_context_tear_down(xfrm_params);
	return ret;

err_out:
	return ret;
}

static int mtk_xfrm_offload_state_add_outbound(struct xfrm_state *xs,
					       struct mtk_xfrm_params *xfrm_params)
{
	int ret;

	xfrm_params->cdrt = mtk_pce_cdrt_entry_alloc(CDRT_ENCRYPT);
	if (IS_ERR(xfrm_params->cdrt))
		return PTR_ERR(xfrm_params->cdrt);

	xfrm_params->dir = SAB_DIRECTION_OUTBOUND;

	ret = mtk_xfrm_offload_context_setup(xfrm_params);
	if (ret)
		goto free_cdrt;

	return ret;

free_cdrt:
	mtk_pce_cdrt_entry_free(xfrm_params->cdrt);

	return ret;
}

static int mtk_xfrm_offload_state_add_inbound(struct xfrm_state *xs,
					      struct mtk_xfrm_params *xfrm_params)
{
	int ret;

	xfrm_params->cdrt = mtk_pce_cdrt_entry_alloc(CDRT_DECRYPT);
	if (IS_ERR(xfrm_params->cdrt))
		return PTR_ERR(xfrm_params->cdrt);

	xfrm_params->dir = SAB_DIRECTION_INBOUND;

	ret = mtk_xfrm_offload_context_setup(xfrm_params);
	if (ret)
		goto free_cdrt;

	ret = mtk_xfrm_offload_cls_entry_setup(xfrm_params);
	if (ret)
		goto tear_down_context;

	return ret;

tear_down_context:
	mtk_xfrm_offload_context_tear_down(xfrm_params);

free_cdrt:
	mtk_pce_cdrt_entry_free(xfrm_params->cdrt);

	return ret;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
int mtk_xfrm_offload_state_add(struct xfrm_state *xs, struct netlink_ext_ack *extack)
#else
int mtk_xfrm_offload_state_add(struct xfrm_state *xs)
#endif
{
	struct mtk_xfrm_params *xfrm_params;
	int ret = 0;

	/* Never interpret a bridge/VLAN/PPP netdev's private area as mtk_mac. */
	if (mtk_crypto_ppe_get_num(xs->xso.dev) < 0)
		return -EOPNOTSUPP;

	if (xs->xso.type != XFRM_DEV_OFFLOAD_PACKET ||
	    (xs->xso.dir != XFRM_DEV_OFFLOAD_IN && xs->xso.dir != XFRM_DEV_OFFLOAD_OUT) ||
	    xs->props.flags & XFRM_STATE_ESN)
		return -EOPNOTSUPP;

	/* Both supported families use full packet offload. */
	if (xs->props.family != AF_INET && xs->props.family != AF_INET6) {
		CRYPTO_NOTICE("Only IPv4 and IPv6 xfrm states may be offloaded\n");
		return -EINVAL;
	}

	/* only support ESP right now */
	if (xs->id.proto != IPPROTO_ESP) {
		CRYPTO_NOTICE("Unsupported protocol 0x%04x\n", xs->id.proto);
		return -EINVAL;
	}

	/* only support tunnel mode or transport mode */
	if (!(xs->outer_mode.encap == XFRM_MODE_TUNNEL
	    || xs->outer_mode.encap == XFRM_MODE_TRANSPORT)) {
		CRYPTO_NOTICE("Unsupported outer encapsulation type %u\n", xs->outer_mode.encap);
		return -EINVAL;
	}

	xfrm_params = kzalloc(sizeof(*xfrm_params), GFP_KERNEL);
	if (!xfrm_params)
		return -ENOMEM;
	if (!try_module_get(THIS_MODULE)) {
		kfree(xfrm_params);
		return -ENODEV;
	}

	xfrm_params->xs = xs;
	INIT_LIST_HEAD(&xfrm_params->node);

#if KERNEL_VERSION(6, 3, 0) < LINUX_VERSION_CODE
	if (xs->xso.dir == XFRM_DEV_OFFLOAD_IN)
#else
	if (xs->xso.flags & XFRM_OFFLOAD_INBOUND)
#endif
		/* rx path */
		ret = mtk_xfrm_offload_state_add_inbound(xs, xfrm_params);
	else
		/* tx path */
		ret = mtk_xfrm_offload_state_add_outbound(xs, xfrm_params);

	if (ret) {
		kfree(xfrm_params);
		module_put(THIS_MODULE);
		goto out;
	}

	refcount_set(&xfrm_params->refs, 1);
	xfrm_params->active = true;
	xs->xso.offload_handle = (unsigned long)xfrm_params;

#if KERNEL_VERSION(6, 3, 0) < LINUX_VERSION_CODE
	if (extack) {
		memcpy(extack->cookie, &xfrm_params->cdrt->idx, sizeof(xfrm_params->cdrt->idx));
		extack->cookie_len = sizeof(xfrm_params->cdrt->idx);
	}
#endif

	spin_lock_bh(&xfrm_params_list.lock);

	list_add_tail(&xfrm_params->node, &xfrm_params_list.list);

	spin_unlock_bh(&xfrm_params_list.lock);

out:
	return ret;
}

static void mtk_xfrm_clear_flows(struct mtk_xfrm_params *params)
{
#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
	foe_clear_crypto_entry(params->cdrt->idx);
#elif defined(CONFIG_CRYPTO_OFFLOAD_INLINE_FLOWBLOCK)
	mtk_flow_offload_teardown_by_tnl(mcrypto.eth, MTK_FOE_CRYPTO_DEL,
					 params->cdrt->idx);
#endif
}

void mtk_xfrm_offload_state_delete(struct xfrm_state *xs)
{
	struct mtk_xfrm_params *params = (void *)xs->xso.offload_handle;

	if (!params)
		return;
	WRITE_ONCE(params->active, false);
	if (params->cdrt->cls) {
		memset(&params->cdrt->cls->cdesc, 0, sizeof(struct cls_desc));
		mtk_pce_cls_entry_write(params->cdrt->cls);
	}
	mtk_xfrm_clear_flows(params);
}

void mtk_xfrm_offload_state_free(struct xfrm_state *xs)
{
	struct mtk_xfrm_params *params;

	spin_lock_bh(&xfrm_params_list.lock);
	params = (void *)xs->xso.offload_handle;
	if (!params) {
		spin_unlock_bh(&xfrm_params_list.lock);
		return;
	}
	WRITE_ONCE(params->active, false);
	xs->xso.offload_handle = 0;
	list_del(&params->node);
	spin_unlock_bh(&xfrm_params_list.lock);

	mtk_xfrm_clear_flows(params);
	mtk_xfrm_params_put(params);
}

struct mtk_xfrm_policy {
	struct xfrm_state *state;
	struct mtk_xfrm_params *params;
};

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
int mtk_xfrm_offload_policy_add(struct xfrm_policy *xp, struct netlink_ext_ack *extack)
#else
int mtk_xfrm_offload_policy_add(struct xfrm_policy *xp)
#endif
{
	struct mtk_xfrm_policy *policy;
	struct mtk_xfrm_params *params;

	if (xp->xdo.type != XFRM_DEV_OFFLOAD_PACKET ||
	    mtk_crypto_ppe_get_num(xp->xdo.dev) < 0 || xp->xfrm_nr > 1)
		return -EOPNOTSUPP;
	policy = kzalloc(sizeof(*policy), GFP_KERNEL);
	if (!policy)
		return -ENOMEM;
	if (!try_module_get(THIS_MODULE)) {
		kfree(policy);
		return -ENODEV;
	}
	if (xp->xfrm_nr && xp->xfrm_vec[0].id.spi)
		policy->state = xfrm_state_lookup_byspi(&init_net,
				xp->xfrm_vec[0].id.spi, xp->xfrm_vec[0].encap_family);
	if (policy->state) {
		spin_lock_bh(&xfrm_params_list.lock);
		list_for_each_entry(params, &xfrm_params_list.list, node)
			if (params->xs == policy->state && params->active) {
				refcount_inc(&params->refs);
				policy->params = params;
				break;
			}
		spin_unlock_bh(&xfrm_params_list.lock);
	}
	xp->xdo.offload_handle = (unsigned long)policy;
	return 0;
}

void mtk_xfrm_offload_policy_delete(struct xfrm_policy *xp)
{
	struct mtk_xfrm_policy *policy = (void *)xp->xdo.offload_handle;

	if (policy && policy->params)
		mtk_xfrm_clear_flows(policy->params);
}

void mtk_xfrm_offload_policy_free(struct xfrm_policy *xp)
{
	struct mtk_xfrm_policy *policy = (void *)xp->xdo.offload_handle;

	if (!policy)
		return;
	xp->xdo.offload_handle = 0;
	if (policy->params)
		mtk_xfrm_params_put(policy->params);
	if (policy->state)
		xfrm_state_put(policy->state);
	kfree(policy);
	module_put(THIS_MODULE);
}

bool mtk_xfrm_offload_ok(struct sk_buff *skb, struct xfrm_state *xs)
{
	struct mtk_xfrm_params *params;
	bool ok;
	struct dst_entry *dst = skb_dst(skb);

	/* This callback must never consume or modify skb. */
	spin_lock_bh(&xfrm_params_list.lock);
	params = (void *)xs->xso.offload_handle;
	ok = params && READ_ONCE(params->active) && dst &&
	       xs->xso.type == XFRM_DEV_OFFLOAD_PACKET &&
	       xs->xso.dir == XFRM_DEV_OFFLOAD_OUT && xs->xso.dev &&
	       xfrm_dst_path(dst)->dev == xs->xso.dev &&
	       xs->xso.dev->type == ARPHRD_ETHER &&
	       ((xs->props.family == AF_INET && skb->protocol == htons(ETH_P_IP)) ||
		(xs->props.family == AF_INET6 && skb->protocol == htons(ETH_P_IPV6)));
	spin_unlock_bh(&xfrm_params_list.lock);
	return ok;
}

/* The kernel's explicit packet-xmit op transfers ownership on every return,
 * including failed neighbour resolution, segmentation and fragmentation.
 */
static int mtk_xfrm_fragment_output(struct net *net, struct sock *sk,
				   struct sk_buff *skb)
{
	return xfrm_output(sk, skb);
}

int mtk_xfrm_offload_packet_xmit(struct sk_buff *skb, struct xfrm_state *xs)
{
	struct mtk_xfrm_params *params = NULL;
	struct dst_entry *dst = skb_dst(skb);
	struct net_device *dev = xs->xso.dev;
	struct neighbour *neigh;
	struct net *net = xs_net(xs);
	unsigned int payload_len;
	int mtu, ret = -EHOSTUNREACH;
#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
	int fill_inner_info;
#endif
	u8 mac[ETH_ALEN];

	if (!mtk_xfrm_offload_ok(skb, xs) ||
	    !netif_carrier_ok(dev) || !(dev->flags & IFF_UP))
		goto drop;

	spin_lock_bh(&xfrm_params_list.lock);
	params = (void *)xs->xso.offload_handle;
	if (params && params->active)
		refcount_inc(&params->refs);
	else
		params = NULL;
	spin_unlock_bh(&xfrm_params_list.lock);
	if (!params)
		goto drop;

	if (skb_is_gso(skb)) {
		struct sk_buff *segs, *next;

		segs = skb_gso_segment(skb, 0);
		if (IS_ERR_OR_NULL(segs)) {
			ret = segs ? PTR_ERR(segs) : -EINVAL;
			goto drop;
		}
		consume_skb(skb);
		while (segs) {
			next = segs->next;
			skb_mark_not_on_list(segs);
			ret = mtk_xfrm_offload_packet_xmit(segs, xs);
			if (ret) {
				kfree_skb_list(next);
				goto out;
			}
			segs = next;
		}
		ret = 0;
		goto out;
	}

	mtu = xfrm_state_mtu(xs, ((struct xfrm_dst *)dst)->child_mtu_cached);
	if (mtu <= 0) {
		ret = -EMSGSIZE;
		goto drop;
	}
	if (skb->len > mtu) {
		if (skb->protocol == htons(ETH_P_IP) &&
		    (!(ip_hdr(skb)->frag_off & htons(IP_DF)) || skb->ignore_df)) {
			IPCB(skb)->frag_max_size = mtu;
			ret = ip_do_fragment(net, skb->sk, skb, mtk_xfrm_fragment_output);
			goto out;
		}
		if (skb->protocol == htons(ETH_P_IP))
			icmp_send(skb, ICMP_DEST_UNREACH, ICMP_FRAG_NEEDED, htonl(mtu));
#if IS_ENABLED(CONFIG_IPV6)
		else {
			skb->dev = dev;
			icmpv6_send(skb, ICMPV6_PKT_TOOBIG, 0, mtu);
		}
#endif
		ret = -EMSGSIZE;
		goto drop;
	}

	if (skb->ip_summed == CHECKSUM_PARTIAL) {
		ret = skb_checksum_help(skb);
		if (ret)
			goto drop;
	}
	/* Reserve metadata AND Ethernet headroom before skb_push(). */
	ret = skb_cow_head(skb, NET_SKB_PAD + NET_IP_ALIGN + ETH_HLEN);
	if (ret)
		goto drop;

	neigh = dst_neigh_lookup(xfrm_dst_path(dst), &xs->id.daddr);
	if (!neigh) {
		ret = -EHOSTUNREACH;
		goto drop;
	}
	if (!(READ_ONCE(neigh->nud_state) & NUD_VALID)) {
		/* Trigger ARP/ND without queueing an unencrypted clone to WAN. */
		neigh_event_send(neigh, NULL);
		neigh_release(neigh);
		ret = -EAGAIN;
		goto drop;
	}
	neigh_ha_snapshot(mac, neigh, dev);
	neigh_release(neigh);
	if (!is_valid_ether_addr(mac)) {
		ret = -EHOSTUNREACH;
		goto drop;
	}

#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
	fill_inner_info = skb->mac_header == skb->network_header;
#endif
	payload_len = skb->len;
	skb_push(skb, ETH_HLEN);
	skb_reset_mac_header(skb);
	ether_addr_copy(eth_hdr(skb)->h_dest, mac);
	ether_addr_copy(eth_hdr(skb)->h_source, dev->dev_addr);
	eth_hdr(skb)->h_proto = skb->protocol;

#if IS_ENABLED(CONFIG_NET_MEDIATEK_HNAT)
	skb_hnat_cdrt(skb) = params->cdrt->idx;
	if (ra_sw_nat_hook_tx && is_hnat_rate_reach(skb))
		hnat_bind_crypto_entry(skb, dev, fill_inner_info);
	skb_hnat_magic_tag(skb) = HNAT_MAGIC_TAG;
#else
	skb_tnl_cdrt(skb) = params->cdrt->idx;
	skb_tnl_magic_tag(skb) = TNL_MAGIC_TAG;
#endif
	atomic64_add(payload_len, &params->bytes);
	atomic64_inc(&params->packets);
	skb->inner_protocol = IPPROTO_ESP;
	skb->dev = dev;
	nf_reset_ct(skb);
	ret = dev_queue_xmit(skb);
	ret = net_xmit_eval(ret) ? -ENOBUFS : 0;
	goto out;

drop:
	XFRM_INC_STATS(net, LINUX_MIB_XFRMOUTERROR);
	kfree_skb(skb);
out:
	if (params)
		mtk_xfrm_params_put(params);
	return ret;
}
