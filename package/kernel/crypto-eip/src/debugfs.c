// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Copyright (C) 2024 MediaTek Inc.
 *
 * Author: Frank-zj Lin <frank-zj.lin@mediatek.com>
 */

#include <linux/debugfs.h>
#include <linux/spinlock.h>
#include <linux/netdevice.h>
#include <linux/module.h>

#include <pce/cdrt.h>

#include "crypto-eip/crypto-eip.h"
#include "crypto-eip/debugfs.h"

struct dentry *mtk_crypto_debugfs_root;
int mac_filter_enable;

static int mtk_crypto_debugfs_read(struct seq_file *s, void *private)
{
	struct xfrm_params_list *xfrm_params_list;
	struct mtk_xfrm_params *xfrm_params;

	xfrm_params_list = mtk_xfrm_params_list_get();
	if (!xfrm_params_list)
		return 0;
	seq_puts(s, "Counters: host-observed packets/bytes; not hardware totals\n");

	spin_lock_bh(&xfrm_params_list->lock);

	list_for_each_entry(xfrm_params, &xfrm_params_list->list, node) {
		seq_printf(s, "XFRM STATE: spi 0x%x, cdrt_idx %3d: ",
			   htonl(xfrm_params->xs->id.spi),
			   xfrm_params->cdrt->idx);

		if (xfrm_params->cdrt->type == CDRT_DECRYPT)
			seq_puts(s, "INBOUND\n");
		else if (xfrm_params->cdrt->type == CDRT_ENCRYPT)
			seq_puts(s, "OUTBOUND\n");
		else
			seq_puts(s, "\n");

		seq_printf(s, "\tBytes Sent: %llu\n", atomic64_read(&xfrm_params->bytes));
		seq_printf(s, "\tPackets Sent: %llu\n", atomic64_read(&xfrm_params->packets));
	}

	spin_unlock_bh(&xfrm_params_list->lock);

	return 0;
}

static int mtk_crypto_debugfs_open(struct inode *inode, struct file *file)
{
	return single_open(file, mtk_crypto_debugfs_read, file->private_data);
}

static ssize_t mtk_crypto_debugfs_write(struct file *file,
					const char __user *ubuf,
					size_t count, loff_t *ppos)
{
	return count;
}

static const struct file_operations mtk_crypto_debugfs_fops = {
	.owner = THIS_MODULE,
	.open = mtk_crypto_debugfs_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.write = mtk_crypto_debugfs_write,
	.release = single_release,
};

static int mtk_crypto_offload_dev_read(struct seq_file *s, void *private)
{
	return 0;
}

static int mtk_crypto_offload_dev_open(struct inode *inode, struct file *file)
{
	return single_open(file, mtk_crypto_offload_dev_read, file->private_data);
}

static ssize_t mtk_crypto_offload_dev_write(struct file *file,
					const char __user *ubuf,
					size_t count, loff_t *ppos)
{
	char buf[IFNAMSIZ];
	struct net_device *dev;
	char *p, *tmp;
	int ret;

	if (!count || count >= IFNAMSIZ)
		return -EINVAL;

	memset(buf, 0, IFNAMSIZ);

	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;

	tmp = buf;
	p = strsep(&tmp, "\n\r ");
	dev = dev_get_by_name(&init_net, p);

	if (!dev)
		return -ENODEV;
	ret = mtk_crypto_enable_ipsec_dev_features(dev);
	dev_put(dev);
	return ret ? ret : count;
}

static const struct file_operations mtk_crypto_offload_dev_fops = {
	.owner = THIS_MODULE,
	.open = mtk_crypto_offload_dev_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.write = mtk_crypto_offload_dev_write,
	.release = single_release,
};

static int mtk_crypto_mac_filter_read(struct seq_file *m, void *private)
{
	seq_printf(m, "%d\n", READ_ONCE(mac_filter_enable));

	return 0;
}

static int mtk_crypto_mac_filter_enable_open(struct inode *inode, struct file *file)
{
	return single_open(file, mtk_crypto_mac_filter_read, file->private_data);
}

static ssize_t mtk_crypto_mac_filter_enable_write(struct file *file,
						  const char __user *buffer,
						  size_t count, loff_t *data)
{
	bool enabled;
	int ret;

	ret = kstrtobool_from_user(buffer, count, &enabled);
	if (ret)
		return ret;
	WRITE_ONCE(mac_filter_enable, enabled);
	return count;
}

static const struct file_operations mtk_crypto_mac_filter_enable_fops = {
	.owner = THIS_MODULE,
	.open = mtk_crypto_mac_filter_enable_open,
	.read = seq_read,
	.llseek = seq_lseek,
	.write = mtk_crypto_mac_filter_enable_write,
	.release = single_release,
};

int mtk_crypto_debugfs_init(void)
{
	mtk_crypto_debugfs_root = debugfs_create_dir("mtk_crypto", NULL);
	if (IS_ERR_OR_NULL(mtk_crypto_debugfs_root))
		return -ENODEV;

	debugfs_create_file("xfrm_params", 0644, mtk_crypto_debugfs_root, NULL,
			    &mtk_crypto_debugfs_fops);

	debugfs_create_file("offload_dev", 0644, mtk_crypto_debugfs_root, NULL,
				&mtk_crypto_offload_dev_fops);

	debugfs_create_file("mac_filter_enable", 0644, mtk_crypto_debugfs_root, NULL,
			    &mtk_crypto_mac_filter_enable_fops);

	return 0;
}

void mtk_crypto_debugfs_exit(void)
{
	debugfs_remove_recursive(mtk_crypto_debugfs_root);
	mtk_crypto_debugfs_root = NULL;
}
