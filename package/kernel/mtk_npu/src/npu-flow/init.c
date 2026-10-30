// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (c) 2026 MediaTek Inc. All Rights Reserved.
 *
 * Author: Chris Chou <chris.chou@mediatek.com>
 */

#include <linux/device.h>
#include <linux/err.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>

#include "npu-flow/internal.h"
#include "npu-flow/net-event.h"
#include "npu-flow/tnl-offload.h"

struct npu_flow_dev npu_flow;

static int mtk_npu_flow_device_init(void)
{
	struct platform_device *pdev;
	struct device_node *node;
	struct resource *res;
	int ret = 0;

	node = of_find_compatible_node(NULL, NULL, "mediatek,npu");
	if (!node) {
		/* for legacy NPU name, should be removed after openwrt-21.02 deprecated */
		node = of_find_compatible_node(NULL, NULL, "mediatek,tops");
		if (!node) {
			pr_notice("Cannot find NPU device node\n");
			return -ENODEV;
		}
	}

	pdev = of_find_device_by_node(node);
	if (!pdev) {
		pr_notice("Cannot find NPU platform device\n");
		ret = -ENODEV;
		goto out;
	}

	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "npu-base");
	if (!res)
		res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "tops-base");
	if (!res) {
		ret = -ENXIO;
		goto out_device;
	}

	npu_flow.base = ioremap(res->start, resource_size(res));
	if (!npu_flow.base) {
		ret = -ENOMEM;
		goto out_device;
	}

	npu_flow.dev = &pdev->dev;
	/* Retain the platform-device reference for the module lifetime. */
	of_node_put(node);
	return 0;

out_device:
	put_device(&pdev->dev);
out:
	of_node_put(node);
	return ret;
}

static void mtk_npu_flow_device_deinit(void)
{
	if (npu_flow.base)
		iounmap(npu_flow.base);
	if (npu_flow.dev)
		put_device(npu_flow.dev);
	memset(&npu_flow, 0, sizeof(npu_flow));
}

static int __init mtk_npu_flow_init(void)
{
	int ret = 0;

	ret = mtk_npu_flow_device_init();
	if (ret)
		return ret;

	ret = mtk_npu_flow_tnl_offload_init();
	if (ret) {
		mtk_npu_flow_device_deinit();
		return ret;
	}

	ret = mtk_npu_flow_net_event_init();
	if (ret)
		goto err_tnl_offload_deinit;

	return ret;

err_tnl_offload_deinit:
	mtk_npu_flow_tnl_offload_deinit();
	mtk_npu_flow_device_deinit();

	return ret;
}

static void __exit mtk_npu_flow_exit(void)
{
	mtk_npu_flow_net_event_deinit();

	mtk_npu_flow_tnl_offload_deinit();
	mtk_npu_flow_device_deinit();
}

module_init(mtk_npu_flow_init);
module_exit(mtk_npu_flow_exit);

MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("MediaTek NPU Tunnel Offload Module with FlowBlock");
MODULE_AUTHOR("Chris Chou <chris.chou@mediatek.com>");
