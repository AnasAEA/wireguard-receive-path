// SPDX-License-Identifier: GPL-2.0
/*
 * Copyright (C) 2015-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

#include "version.h"
#include "device.h"
#include "noise.h"
#include "queueing.h"
#include "ratelimiter.h"
#include "netlink.h"

#include <uapi/linux/wireguard.h>

#include <linux/init.h>
#include <linux/module.h>
#include <linux/genetlink.h>
#include <net/rtnetlink.h>

/* RX completion-coalescing trigger knobs (see queueing.h / receive.c).
 * wg_trig_k == 0 disables the trigger entirely => the module is byte-for-byte
 * stock behaviour, so the A/B baseline and the trigger share one binary.
 */
unsigned long wg_trig_k;             /* batch threshold; 0 = off (default) */
unsigned long wg_trig_tau_ns = 5000; /* coalesce window in ns (data-driven default) */
module_param(wg_trig_k, ulong, 0644);
module_param(wg_trig_tau_ns, ulong, 0644);
MODULE_PARM_DESC(wg_trig_k, "RX coalesce batch threshold (0=off, stock behaviour)");
MODULE_PARM_DESC(wg_trig_tau_ns, "RX coalesce window in nanoseconds");

/* The simplest intervention: suppress the wasted MISSED-driven re-poll at the
 * poll-completion site when the head is still UNCRYPTED. Independent of the
 * coalescing trigger above. 0 = stock, 1 = suppress.
 */
unsigned long wg_supp;               /* 0 = off (default, stock) */
module_param(wg_supp, ulong, 0644);
MODULE_PARM_DESC(wg_supp, "Suppress wasted MISSED re-polls when head is UNCRYPTED (0=off)");

/* The root fix: wake the poll only when a decrypt completion makes the head
 * deliverable (it completes the packet the poll parked on, or the queue was
 * empty). Non-head completions stay silent. Timer-free. 0 = stock.
 */
unsigned long wg_headwake;           /* 0 = off (default, stock) */
module_param(wg_headwake, ulong, 0644);
MODULE_PARM_DESC(wg_headwake, "Wake the RX poll only when the completion makes the head ready (0=off)");

/* Decrypt-cost sensitivity (Alain 2026-06-25): busy-wait this many ns per decrypted
 * data packet, in the decrypt worker, to lengthen T_decrypt without touching the
 * per-poll cost. Lets us sweep the decrypt:poll ratio and find where the EoI fix
 * starts to pay. 0 = off (native hardware timing).
 */
unsigned long wg_decrypt_delay_ns;   /* 0 = off (default) */
module_param(wg_decrypt_delay_ns, ulong, 0644);
MODULE_PARM_DESC(wg_decrypt_delay_ns, "Busy-wait ns injected per decrypt to slow T_decrypt (0=off)");

/* Diagnostic counters (wg_diag=1): at poll completion, classify head-state ×
 * whether MISSED is set. Read/reset via sysfs. Behaviour-preserving.
 */
unsigned long wg_diag;
unsigned long wg_diag_empty_missed, wg_diag_empty_nomiss;
unsigned long wg_diag_uncrypt_missed, wg_diag_uncrypt_nomiss;
module_param(wg_diag, ulong, 0644);
module_param(wg_diag_empty_missed, ulong, 0644);
module_param(wg_diag_empty_nomiss, ulong, 0644);
module_param(wg_diag_uncrypt_missed, ulong, 0644);
module_param(wg_diag_uncrypt_nomiss, ulong, 0644);
/* wg_supp instrumentation: cleared a set MISSED (no re-arm) / recheck re-armed /
 * MISSED re-set by a concurrent core right after our clear (parallel-regime killer). */
unsigned long wg_diag_supp_cleared, wg_diag_supp_rearmed, wg_diag_supp_reset_race;
module_param(wg_diag_supp_cleared, ulong, 0644);
module_param(wg_diag_supp_rearmed, ulong, 0644);
module_param(wg_diag_supp_reset_race, ulong, 0644);
MODULE_PARM_DESC(wg_diag, "Enable poll-completion head-state/MISSED classification counters");
/* E11 stall-episode classifier (wg_diag=1): contiguous delivery-blocked
 * episodes, from the first wasted poll to the next productive poll, accounted
 * under the head class the episode opened with. Layout per array:
 * [0]=episodes [1]=total_ns [2]=max_ns [3]=<=16us [4]=16-128us [5]=128us-1ms
 * [6]=>1ms. Racy ulongs (ratios/bucket shares only). Reset: write 0,0,0,0,0,0,0.
 */
unsigned long wg_diag_stall_empty[7], wg_diag_stall_uncrypt[7];
module_param_array(wg_diag_stall_empty, ulong, NULL, 0644);
module_param_array(wg_diag_stall_uncrypt, ulong, NULL, 0644);
MODULE_PARM_DESC(wg_diag_stall_empty, "Blocked episodes, empty-queue class: n,total_ns,max_ns,le16us,le128us,le1ms,gt1ms");
MODULE_PARM_DESC(wg_diag_stall_uncrypt, "Blocked episodes, UNCRYPTED-head class: n,total_ns,max_ns,le16us,le128us,le1ms,gt1ms");

static int __init mod_init(void)
{
	int ret;

	ret = wg_allowedips_slab_init();
	if (ret < 0)
		goto err_allowedips;

#ifdef DEBUG
	ret = -ENOTRECOVERABLE;
	if (!wg_allowedips_selftest() || !wg_packet_counter_selftest() ||
	    !wg_ratelimiter_selftest())
		goto err_peer;
#endif
	wg_noise_init();

	ret = wg_peer_init();
	if (ret < 0)
		goto err_peer;

	ret = wg_device_init();
	if (ret < 0)
		goto err_device;

	ret = wg_genetlink_init();
	if (ret < 0)
		goto err_netlink;

	pr_info("WireGuard " WIREGUARD_VERSION " loaded. See www.wireguard.com for information.\n");
	pr_info("Copyright (C) 2015-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.\n");

	return 0;

err_netlink:
	wg_device_uninit();
err_device:
	wg_peer_uninit();
err_peer:
	wg_allowedips_slab_uninit();
err_allowedips:
	return ret;
}

static void __exit mod_exit(void)
{
	wg_genetlink_uninit();
	wg_device_uninit();
	wg_peer_uninit();
	wg_allowedips_slab_uninit();
}

module_init(mod_init);
module_exit(mod_exit);
MODULE_LICENSE("GPL v2");
MODULE_DESCRIPTION("WireGuard secure network tunnel");
MODULE_AUTHOR("Jason A. Donenfeld <Jason@zx2c4.com>");
MODULE_VERSION(WIREGUARD_VERSION);
MODULE_ALIAS_RTNL_LINK(KBUILD_MODNAME);
MODULE_ALIAS_GENL_FAMILY(WG_GENL_NAME);
