// SPDX-License-Identifier: GPL-2.0
/* Load only with other OSAL clients stopped: these tests own device slot 1. */
#include <linux/module.h>
#include <linux/completion.h>
#include <linux/cpu.h>
#include <linux/delay.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
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
