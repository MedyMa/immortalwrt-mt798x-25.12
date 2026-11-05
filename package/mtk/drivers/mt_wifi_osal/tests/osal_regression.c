// SPDX-License-Identifier: GPL-2.0
/* Load only with other OSAL clients stopped: these tests own device slot 1. */
#include <linux/module.h>
#include <linux/completion.h>
#include <linux/cpu.h>
#include <linux/delay.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/if_arp.h>
#include <linux/wireless.h>
#include <linux/kthread.h>
#include <linux/slab.h>
#include <linux/unaligned.h>
#include <linux/rtnetlink.h>
#include <mt_osal.h>
#include <mt_osal_module.h>

static int test_rx_checksum(void)
{
	struct sk_buff *skb, *reference;
	u8 bytes[64];
	int i, ret = 0;

	for (i = 0; i < sizeof(bytes); i++)
		bytes[i] = i * 13 + 7;
	skb = alloc_skb(sizeof(bytes), GFP_KERNEL);
	if (!skb)
		return -ENOMEM;
	skb_put_data(skb, bytes, sizeof(bytes));
	skb->ip_summed = CHECKSUM_COMPLETE;
	skb->csum = csum_partial(skb->data, skb->len, 0);
	reference = skb_copy(skb, GFP_KERNEL);
	if (!reference) {
		kfree_skb(skb);
		return -ENOMEM;
	}
	skb_pull_rcsum(reference, ETH_HLEN);
	mt_os_pkt_pull_rcsum(skb, ETH_HLEN);
	if (skb->len != reference->len || skb->csum != reference->csum ||
	    skb->ip_summed != reference->ip_summed ||
	    memcmp(skb->data, reference->data, reference->len))
		ret = -EINVAL;
	kfree_skb(reference);
	kfree_skb(skb);
	return ret;
}

static int test_vlan_tag(void)
{
	u8 header[ETH_HLEN] = { 0x02, 1, 2, 3, 4, 5, 0x02, 6, 7, 8, 9, 10, 8, 0 };
	u8 tag[] = { 0x81, 0x00 };
	u8 packet[ETH_HLEN + VLAN_HLEN] = {};

	if (mt_os_vlan_8023_header_copy(100, 5, header, sizeof(header), packet, tag) != VLAN_HLEN)
		return -EINVAL;
	if (memcmp(packet, header, 12) || memcmp(packet + 12, tag, 2) ||
	    get_unaligned_be16(packet + 14) != ((5 << VLAN_PRIO_SHIFT) | 100) ||
	    memcmp(packet + 16, header + 12, 2))
		return -EINVAL;
	return 0;
}

static bool calendar_matches(const struct mt_time_info *info, time64_t seconds)
{
	struct rtc_time tm;

	rtc_time64_to_tm(seconds, &tm);
	return info->year == tm.tm_year + 1900 && info->month == tm.tm_mon + 1 &&
	       info->day == tm.tm_mday && info->hour == tm.tm_hour &&
	       info->min == tm.tm_min && info->sec == tm.tm_sec;
}

static int test_time_units(void)
{
	struct mt_time_info info = {};
	time64_t before, after;
	u64 boot_before, boot_after, boot_value;

	before = ktime_get_real_seconds();
	mt_get_time_info(&info);
	after = ktime_get_real_seconds();
	if (!calendar_matches(&info, before) && !calendar_matches(&info, after))
		return -EINVAL;
	boot_before = ktime_get_boottime_ns();
	boot_value = mt_os_get_boottime64_ns();
	boot_after = ktime_get_boottime_ns();
	return boot_value >= boot_before && boot_value <= boot_after ? 0 : -EINVAL;
}

struct thread_case {
	MT_OS_TASK task;
	struct completion entered;
};

static int nonzero_thread(unsigned long arg)
{
	struct thread_case *ctx = (void *)arg;
	int status;

	complete(&ctx->entered);
	while (mt_os_task_wait(NULL, &ctx->task, &status))
		;
	return -ENOMEM;
}

static int test_nonzero_thread_exit(void)
{
	struct thread_case ctx;
	int ret = 0;

	init_completion(&ctx.entered);
	if (!mt_os_task_init(&ctx.task, "osal-regression", &ctx))
		return -EINVAL;
	if (!mt_os_task_attach(&ctx.task, nonzero_thread, (unsigned long)&ctx))
		return -ENOMEM;
	if (!wait_for_completion_timeout(&ctx.entered, HZ))
		ret = -ETIMEDOUT;
	if (!mt_os_task_kill(&ctx.task) || ctx.task.kthread_task ||
	    ctx.task.taskStatus != MT_TASK_STAT_STOPED)
		return -EINVAL;
	if (mt_os_task_kill(&ctx.task))
		return -EINVAL;
	return ret;
}

struct work_case {
	atomic_t calls;
	struct completion entered;
};

#define TEST_DEVICE_SLOT (MT_MAX_DEVICE_NUM - 1)

static void repeating_work(void *arg)
{
	struct work_case *ctx = arg;

	atomic_inc(&ctx->calls);
	complete(&ctx->entered);
	mt_add_delayed_work(TEST_DEVICE_SLOT, 2);
}

static int test_delayed_work_teardown(void)
{
	struct work_case ctx;
	int count, ret = 0;

	atomic_set(&ctx.calls, 0);
	init_completion(&ctx.entered);
	mt_device_init_work(&ctx, TEST_DEVICE_SLOT, repeating_work);
	mt_add_delayed_work(TEST_DEVICE_SLOT, 1000);
	mt_device_clean_work(TEST_DEVICE_SLOT);
	msleep(20);
	if (atomic_read(&ctx.calls))
		return -EINVAL;

	mt_device_init_work(&ctx, TEST_DEVICE_SLOT, repeating_work);
	mt_add_delayed_work(TEST_DEVICE_SLOT, 0);
	if (!wait_for_completion_timeout(&ctx.entered, HZ))
		ret = -ETIMEDOUT;
	mt_device_clean_work(TEST_DEVICE_SLOT);
	count = atomic_read(&ctx.calls);
	/* Producers after cleanup must not revive the queue. */
	mt_add_delayed_work(TEST_DEVICE_SLOT, 0);
	mt_device_clean_work(TEST_DEVICE_SLOT);
	msleep(20);
	if (atomic_read(&ctx.calls) != count)
		ret = -EINVAL;
	return ret;
}

struct timer_case {
	struct timer_list timer;
	struct completion entered;
	atomic_t finished;
};

static void running_timer(struct timer_list *timer)
{
	struct timer_case *ctx = from_timer(ctx, timer, timer);

	complete(&ctx->entered);
	/* Bounded busy work makes the pending=false/running=true window observable. */
	mdelay(30);
	atomic_set(&ctx->finished, 1);
}

static int test_running_timer_cancel(void)
{
	struct timer_case ctx;
	unsigned char cancelled = false;
	int cpu, target, ret = 0;

	cpus_read_lock();
	cpu = get_cpu();
	target = cpumask_any_but(cpu_online_mask, cpu);
	put_cpu();
	if (target >= nr_cpu_ids) {
		pr_info("osal regression: running-timer case requires SMP, skipped\n");
		goto out;
	}
	init_completion(&ctx.entered);
	atomic_set(&ctx.finished, 0);
	timer_setup(&ctx.timer, running_timer, 0);
	ctx.timer.expires = jiffies + 1;
	add_timer_on(&ctx.timer, target);
	if (!wait_for_completion_timeout(&ctx.entered, HZ)) {
		ret = -ETIMEDOUT;
		goto out_timer;
	}
	mt_os_del_timer(&ctx.timer, &cancelled);
	if (!cancelled || !atomic_read(&ctx.finished))
		ret = -EINVAL;
out_timer:
	del_timer_sync(&ctx.timer);
out:
	cpus_read_unlock();
	return ret;
}

struct rcu_case {
	struct rcu_head head;
	atomic_t *done;
};

static void deferred_free(struct rcu_head *head)
{
	struct rcu_case *ctx = container_of(head, struct rcu_case, head);

	atomic_inc(ctx->done);
	kfree(ctx);
}

static int test_rcu_callback_barrier(void)
{
	struct rcu_case *ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	atomic_t done = ATOMIC_INIT(0);

	if (!ctx)
		return -ENOMEM;
	ctx->done = &done;
	mt_call_rcu(&ctx->head, deferred_free);
	mt_rcu_barrier();
	return atomic_read(&done) == 1 ? 0 : -EINVAL;
}


static int test_fragmented_slice(void)
{
	struct sk_buff *source, *slice;
	struct page *page;
	u8 data[40] = {};
	int i, ret = 0;

	source = alloc_skb(64, GFP_KERNEL);
	if (!source)
		return -ENOMEM;
	skb_reserve(source, 8);
	for (i = 0; i < 32; i++)
		*(u8 *)skb_put(source, 1) = i;
	page = alloc_page(GFP_KERNEL);
	if (!page) {
		kfree_skb(source);
		return -ENOMEM;
	}
	for (i = 0; i < 32; i++)
		((u8 *)page_address(page))[i] = i + 32;
	skb_add_rx_frag(source, 0, page, 0, 32, PAGE_SIZE);
	source->ip_summed = CHECKSUM_COMPLETE;
	source->csum = skb_checksum(source, 0, source->len, 0);
	slice = mt_os_clone_pkt_by_data(0, source, source->data + 8, sizeof(data));
	if (!slice) {
		ret = -ENOMEM;
		goto out;
	}
	if (slice->len != 40 || skb_headlen(slice) != 24 || slice->data_len != 16 ||
	    source->len != 64 || source->data_len != 32 ||
	    source->ip_summed != CHECKSUM_COMPLETE || slice->ip_summed != CHECKSUM_NONE ||
	    skb_copy_bits(slice, 0, data, sizeof(data)))
		ret = -EINVAL;
	for (i = 0; i < sizeof(data); i++)
		if (data[i] != i + 8)
			ret = -EINVAL;
	kfree_skb(slice);
	slice = mt_os_clone_pkt_by_data(0, source, source->data + 8, 12);
	if (!slice || slice->len != 12 || slice->data_len ||
	    skb_tail_pointer(slice) != slice->data + 12)
		ret = -EINVAL;
	kfree_skb(slice);
	slice = mt_os_clone_pkt_by_data(0, source, skb_tail_pointer(source) + 1, 1);
	if (slice)
		ret = -EINVAL;
	kfree_skb(slice);
out:
	kfree_skb(source);
	return ret;
}

struct netdev_case {
	int opened;
	int stopped;
	bool bad_ioctl;
#ifdef CFG80211_SUPPORT
	u32 bands;
	int fail_stage;
	int cfg_registered;
	int cfg_unregistered;
#endif
};

static int regression_open(void *netdev)
{
	struct netdev_case *ctx = mt_os_net_dev_get_priv(netdev);

	ctx->opened++;
	return 0;
}

static int regression_stop(void *netdev)
{
	struct netdev_case *ctx = mt_os_net_dev_get_priv(netdev);

	ctx->stopped++;
	return 0;
}

static int regression_xmit(struct sk_buff *skb, struct net_device *dev)
{
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static int regression_ioctl(void *netdev, void *config)
{
	struct netdev_case *ctx = mt_os_net_dev_get_priv(netdev);
	struct mt_os_wifi_ioctl_cmd_cfg *cmd = config;

	if (cmd->net_dev != netdev)
		ctx->bad_ioctl = true;
	if (cmd->cmd == MT_IO_GET_ESSID) {
		cmd->data = NULL;
		cmd->data_len = IW_ESSID_MAX_SIZE + 1;
		return 0;
	}
	if (cmd->cmd == MT_IO_GET_ETHER_STATS) {
		struct mt_os_net_dev_stats *stats = cmd->data;

		if (!stats || cmd->data_len != sizeof(*stats) || cmd->subcmd ||
		    cmd->subid || cmd->status || cmd->name)
			ctx->bad_ioctl = true;
		if (!stats)
			return -EINVAL;
		stats->rx_packets = 7;
		stats->rx_bytes = 701;
		stats->rx_crc_errors = 3;
		return 0;
	}
#ifdef CFG80211_SUPPORT
	if (cmd->cmd == MT_IO_CFG80211_INIT) {
		if (cmd->subcmd == MT_80211_GET_BAND_INFO) {
			struct mt_cfg80211_band *band = cmd->data;

			if (ctx->fail_stage == 1)
				return -EIO;
			memset(band, 0, sizeof(*band));
			band->phy_caps = ctx->bands | MTK_PHY_CAP_HT | MTK_PHY_CAP_VHT |
					 MTK_PHY_CAP_HE | MTK_PHY_CAP_EHT;
			band->TxStream = band->RxStream = band->max_nss = 2;
			return 0;
		}
		if (cmd->subcmd == MT_80211_DRIVER_REGISTER) {
			if (ctx->fail_stage == 2)
				return -EIO;
			ctx->cfg_registered++;
		}
		if (cmd->subcmd == MT_80211_DRIVER_UNREGISTER)
			ctx->cfg_unregistered++;
		return 0;
	}
#endif
	return -EOPNOTSUPP;
}

static void regression_hook(struct mt_os_net_dev_op_hook *hook)
{
	memset(hook, 0, sizeof(*hook));
	hook->xmit = regression_xmit;
	hook->init = regression_open;
	hook->uninit = regression_stop;
	hook->ioctl = regression_ioctl;
	eth_random_addr(hook->devAddr);
}

static int test_native_netdev_lifecycle(void)
{
	struct mt_os_net_dev_op_hook hook;
	struct netdev_case ctx = {};
	struct rtnl_link_stats64 stats;
	struct sockaddr address = { .sa_family = ARPHRD_ETHER };
	struct iwreq request = {};
	struct net_device *dev;
	u8 header[ETH_HLEN] = {};
	int ret;

	dev = mt_os_net_dev_create(0, NULL, 0, 0, 0, "osal-reg%d", 0, 0);
	if (!dev)
		return -ENOMEM;
	mt_os_net_dev_set_priv(dev, &ctx);
	regression_hook(&hook);
	hook.needProtcted = 1;
	rtnl_lock();
	ret = mt_os_net_dev_register(dev, &hook, 0);
	if (ret)
		goto free;
	ret = dev_open(dev, NULL);
	if (!ret)
		dev_close(dev);
	dev_get_stats(dev, &stats);
	request.u.essid.length = IW_ESSID_MAX_SIZE;
	if (mt_os_wifi_ioctl(dev, (struct ifreq *)&request, SIOCGIWESSID) != -EOVERFLOW)
		ret = -EINVAL;
	if (ctx.bad_ioctl || ctx.opened != 1 || ctx.stopped != 1 ||
	    stats.rx_packets != 7 || stats.rx_bytes != 701 || stats.rx_crc_errors != 3 ||
	    mt_os_net_dev_get_qstate(dev, dev->num_tx_queues) != ~0UL)
		ret = -EINVAL;
	eth_random_addr((u8 *)address.sa_data);
	if (mt_os_net_dev_prepare_mac_change(dev, &address, NULL))
		ret = -EINVAL;
	memcpy(header + ETH_ALEN, dev->dev_addr, ETH_ALEN);
	if (mt_os_net_dev_eth_convert_search(dev, header) != dev)
		ret = -EINVAL;
	memset(header + ETH_ALEN, 0, ETH_ALEN);
	if (mt_os_net_dev_eth_convert_search(dev, header))
		ret = -EINVAL;
	mt_os_net_dev_detach(dev, NET_DEV_MODE_NORMAL);
free:
	/* Exercise the free while unregister is still deferred by RTNL. */
	mt_os_net_dev_free(dev);
	rtnl_unlock();
	return ret;
}

#ifdef CFG80211_SUPPORT
static int test_native_cfg80211_registration(void)
{
	static const u32 bands[] = {
		MTK_PHY_CAP_RFIC_24GHZ, MTK_PHY_CAP_RFIC_5GHZ,
		MTK_PHY_CAP_RFIC_6GHZ,
		MTK_PHY_CAP_RFIC_24GHZ | MTK_PHY_CAP_RFIC_5GHZ | MTK_PHY_CAP_RFIC_6GHZ,
	};
	struct mt_os_net_dev_op_hook hook;
	struct netdev_case ctx;
	struct net_device *dev;
	struct wiphy *wiphy;
	int i, stage, ret, result = 0;

	for (i = 0; i < ARRAY_SIZE(bands); i++) {
		for (stage = 0; stage < 3; stage++) {
			memset(&ctx, 0, sizeof(ctx));
			ctx.bands = bands[i];
			ctx.fail_stage = stage;
			dev = mt_os_net_dev_create(0, NULL, 0, 0, 0, "osal-cfg%d", 0, 0);
			if (!dev)
				return -ENOMEM;
			mt_os_net_dev_set_priv(dev, &ctx);
			regression_hook(&hook);
			hook.reg_cfg80211 = 1;
			hook.mtk_dev_features = MT_FEATURE_MLO;
			ret = mt_os_net_dev_register(dev, &hook, 1);
			if (ret) {
				if (!stage || dev->ieee80211_ptr)
					result = -EINVAL;
				goto free;
			}
			if (stage)
				result = -EINVAL;
			wiphy = dev->ieee80211_ptr->wiphy;
			if (wiphy->flags & WIPHY_FLAG_SUPPORTS_MLO)
				result = -EINVAL;
			if (wiphy->bands[NL80211_BAND_5GHZ] &&
			    wiphy->bands[NL80211_BAND_5GHZ]->channels[0].center_freq != 5180)
				result = -EINVAL;
			if (wiphy->bands[NL80211_BAND_6GHZ] &&
			    wiphy->bands[NL80211_BAND_6GHZ]->channels[0].center_freq != 5955)
				result = -EINVAL;
			rtnl_lock();
			wiphy_lock(wiphy);
			mt_os_net_dev_detach(dev, NET_DEV_MODE_CFG80211);
			wiphy_unlock(wiphy);
			rtnl_unlock();
			mt_cfg80211_unregister(dev);
			if (ctx.bad_ioctl || ctx.cfg_registered != 1 || ctx.cfg_unregistered != 1)
				result = -EINVAL;
free:
			mt_os_net_dev_free(dev);
			if (result)
				return result;
		}
	}
	return 0;
}
#endif

static int __init osal_regression_init(void)
{
	static int (* const tests[])(void) = {
		test_rx_checksum,
		test_vlan_tag,
		test_time_units,
		test_nonzero_thread_exit,
		test_delayed_work_teardown,
		test_running_timer_cancel,
		test_rcu_callback_barrier,
		test_fragmented_slice,
		test_native_netdev_lifecycle,
#ifdef CFG80211_SUPPORT
		test_native_cfg80211_registration,
#endif
	};
	int i, ret;

	for (i = 0; i < ARRAY_SIZE(tests); i++) {
		ret = tests[i]();
		if (ret) {
			pr_err("osal regression: case %ps failed: %d\n", tests[i], ret);
			return ret;
		}
		pr_info("osal regression: %ps passed\n", tests[i]);
	}
	return 0;
}

static void __exit osal_regression_exit(void)
{
}

module_init(osal_regression_init);
module_exit(osal_regression_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("OSAL packet, task, timer and callback regression checks");
