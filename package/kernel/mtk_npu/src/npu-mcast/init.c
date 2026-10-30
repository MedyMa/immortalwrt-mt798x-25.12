// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (c) 2025 MediaTek Inc. All Rights Reserved.
 *
 * Author: Ren-Ting Wang <ren-ting.wang@mediatek.com>
 */

#include <linux/io.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>

#include "npu/mcu.h"
#include "npu-mcast/internal.h"
#include "npu-mcast/mcast.h"
#include "npu-mcast/procfs.h"
#include "npu-mcast/sysfs.h"

struct npu_mcast_dev nmcast;

enum npu_mcast_state {
	NPU_MCAST_DOWN,
	NPU_MCAST_STARTING,
	NPU_MCAST_UP,
	NPU_MCAST_RECOVERING,
};

static DEFINE_MUTEX(mcast_lifecycle_lock);
static DEFINE_MUTEX(mcast_state_lock);
static enum npu_mcast_state mcast_state;
static bool netstop_registered;
static bool init_registered;
static bool freerun_registered;
static bool sysfs_ready;
static bool procfs_ready;
static bool ops_published;

static int mtk_npu_multicast_device_init(void)
{
	struct platform_device *pdev;
	struct device_node *node;
	struct resource *res;
	resource_size_t size;
	int ret = 0;

	node = of_find_compatible_node(NULL, NULL, "mediatek,npu");
	if (!node) {
		/* Legacy device name retained for older device trees. */
		node = of_find_compatible_node(NULL, NULL, "mediatek,tops");
		if (!node)
			return -ENODEV;
	}

	pdev = of_find_device_by_node(node);
	if (!pdev) {
		ret = -ENODEV;
		goto out_node;
	}

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "npu-base");
	if (!res)
		res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "tops-base");
	if (!res) {
		ret = -ENXIO;
		goto out_device;
	}

	size = resource_size(res);
	nmcast.base = ioremap(res->start, size);
	if (!nmcast.base) {
		ret = -ENOMEM;
		goto out_device;
	}
	nmcast.dev = &pdev->dev;
	nmcast.size = size;
	/* Keep the of_find_device_by_node() reference until module exit. */
	goto out_node;

out_device:
	put_device(&pdev->dev);
out_node:
	of_node_put(node);
	return ret;
}

static void mtk_npu_multicast_device_deinit(void)
{
	if (nmcast.base)
		iounmap(nmcast.base);
	if (nmcast.dev)
		put_device(nmcast.dev);

	memset(&nmcast, 0, sizeof(nmcast));
}

static int mcast_before_reset(struct mcu_state_notifier *notifier)
{
	mutex_lock(&mcast_state_lock);
	if (mcast_state != NPU_MCAST_DOWN) {
		mtk_npu_mcast_pause();
		mcast_state = NPU_MCAST_RECOVERING;
	}
	mutex_unlock(&mcast_state_lock);
	return 0;
}

static int mcast_after_reset(struct mcu_state_notifier *notifier)
{
	int ret = 0;

	mutex_lock(&mcast_state_lock);
	if (mcast_state == NPU_MCAST_RECOVERING && mtk_npu_mcu_alive()) {
		ret = mtk_npu_mcast_resume();
		if (!ret)
			mcast_state = NPU_MCAST_UP;
	}
	mutex_unlock(&mcast_state_lock);
	return ret;
}

static struct mcu_state_notifier mcast_stop_notifier = {
	.pre_enter = mcast_before_reset,
};

static struct mcu_state_notifier mcast_init_notifier = {
	.post_enter = mcast_after_reset,
};

static struct mcu_state_notifier mcast_freerun_notifier = {
	/* Warm reset can return from NETSTOP without passing through INIT. */
	.pre_enter = mcast_after_reset,
};

int mtk_npu_mcast_enable(bool en)
{
	int ret = -EAGAIN;

	mutex_lock(&mcast_state_lock);
	if (mcast_state == NPU_MCAST_UP && mtk_npu_mcu_alive()) {
		mtk_npu_mcast_pause();
		ret = mtk_npu_mcast_set_enabled(en);
		if (!ret)
			mcast_state = NPU_MCAST_UP;
		else
			mcast_state = NPU_MCAST_RECOVERING;
	}
	mutex_unlock(&mcast_state_lock);

	return ret;
}

static void mcast_unregister_notifiers(void)
{
	if (freerun_registered) {
		mtk_npu_mcu_state_notifier_unregister(MCU_STATE_TYPE_FREERUN,
						      &mcast_freerun_notifier);
		freerun_registered = false;
	}
	if (init_registered) {
		mtk_npu_mcu_state_notifier_unregister(MCU_STATE_TYPE_INIT,
						      &mcast_init_notifier);
		init_registered = false;
	}
	if (netstop_registered) {
		mtk_npu_mcu_state_notifier_unregister(MCU_STATE_TYPE_NETSTOP,
						      &mcast_stop_notifier);
		netstop_registered = false;
	}
}

static void mcast_stop(void)
{
	mutex_lock(&mcast_state_lock);
	mcast_state = NPU_MCAST_DOWN;
	mtk_npu_mcast_pause();
	mutex_unlock(&mcast_state_lock);

	/* Do not wait for notifier removal while holding its state mutex. */
	mcast_unregister_notifiers();
	if (ops_published) {
		mtk_npu_mcast_unpublish();
		ops_published = false;
	}
	if (procfs_ready) {
		mtk_npu_mcast_procfs_deinit();
		procfs_ready = false;
	}
	if (sysfs_ready) {
		mtk_npu_mcast_sysfs_deinit();
		sysfs_ready = false;
	}
	mtk_npu_mcast_deinit();
	mtk_npu_multicast_device_deinit();
}

static int __init mtk_npu_multicast_init(void)
{
	int ret;

	mutex_lock(&mcast_lifecycle_lock);
	ret = mtk_npu_multicast_device_init();
	if (ret)
		goto out;

	ret = mtk_npu_mcast_init();
	if (ret)
		goto err_device;

	mutex_lock(&mcast_state_lock);
	mcast_state = NPU_MCAST_STARTING;
	mutex_unlock(&mcast_state_lock);

	ret = mtk_npu_mcu_state_notifier_register(MCU_STATE_TYPE_NETSTOP,
						 &mcast_stop_notifier);
	if (ret)
		goto err_stop;
	netstop_registered = true;
	ret = mtk_npu_mcu_state_notifier_register(MCU_STATE_TYPE_INIT,
						 &mcast_init_notifier);
	if (ret)
		goto err_stop;
	init_registered = true;
	ret = mtk_npu_mcu_state_notifier_register(MCU_STATE_TYPE_FREERUN,
						 &mcast_freerun_notifier);
	if (ret)
		goto err_stop;
	freerun_registered = true;

	mutex_lock(&mcast_state_lock);
	ret = mtk_npu_mcu_alive() ? mtk_npu_mcast_resume() : -EBUSY;
	if (!ret) {
		ret = mtk_npu_mcast_publish();
		if (!ret) {
			ops_published = true;
			mcast_state = NPU_MCAST_UP;
		}
	}
	mutex_unlock(&mcast_state_lock);
	if (ret)
		goto err_stop;

	ret = mtk_npu_mcast_sysfs_init();
	if (ret)
		goto err_stop;
	sysfs_ready = true;
	ret = mtk_npu_mcast_procfs_init();
	if (ret)
		goto err_stop;
	procfs_ready = true;

	mutex_unlock(&mcast_lifecycle_lock);
	return 0;

err_stop:
	mcast_stop();
	mutex_unlock(&mcast_lifecycle_lock);
	return ret;
err_device:
	mtk_npu_multicast_device_deinit();
out:
	mutex_unlock(&mcast_lifecycle_lock);
	return ret;
}

static void __exit mtk_npu_multicast_exit(void)
{
	mutex_lock(&mcast_lifecycle_lock);
	mcast_stop();
	mutex_unlock(&mcast_lifecycle_lock);
}

module_init(mtk_npu_multicast_init);
module_exit(mtk_npu_multicast_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("MediaTek Network Processor Unit with IPv4/IPv6 Multicast");
MODULE_AUTHOR("Ren-Ting Wang <ren-ting.wang@mediatek.com>");
