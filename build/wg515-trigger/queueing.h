/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Copyright (C) 2015-2019 Jason A. Donenfeld <Jason@zx2c4.com>. All Rights Reserved.
 */

#ifndef _WG_QUEUEING_H
#define _WG_QUEUEING_H

#include "peer.h"
#include <linux/types.h>
#include <linux/skbuff.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/hrtimer.h>
#include <linux/ktime.h>
#include <linux/atomic.h>
#include <net/ip_tunnels.h>

struct wg_device;
struct wg_peer;
struct multicore_worker;
struct crypt_queue;
struct prev_queue;
struct sk_buff;

/* queueing.c APIs: */
int wg_packet_queue_init(struct crypt_queue *queue, work_func_t function,
			 unsigned int len);
void wg_packet_queue_free(struct crypt_queue *queue, bool purge);
struct multicore_worker __percpu *
wg_packet_percpu_multicore_worker_alloc(work_func_t function, void *ptr);

/* receive.c APIs: */
void wg_packet_receive(struct wg_device *wg, struct sk_buff *skb);
void wg_packet_handshake_receive_worker(struct work_struct *work);
/* NAPI poll function: */
int wg_packet_rx_poll(struct napi_struct *napi, int budget);
/* Workqueue worker: */
void wg_packet_decrypt_worker(struct work_struct *work);

/* send.c APIs: */
void wg_packet_send_queued_handshake_initiation(struct wg_peer *peer,
						bool is_retry);
void wg_packet_send_handshake_response(struct wg_peer *peer);
void wg_packet_send_handshake_cookie(struct wg_device *wg,
				     struct sk_buff *initiating_skb,
				     __le32 sender_index);
void wg_packet_send_keepalive(struct wg_peer *peer);
void wg_packet_purge_staged_packets(struct wg_peer *peer);
void wg_packet_send_staged_packets(struct wg_peer *peer);
/* Workqueue workers: */
void wg_packet_handshake_send_worker(struct work_struct *work);
void wg_packet_tx_worker(struct work_struct *work);
void wg_packet_encrypt_worker(struct work_struct *work);

enum packet_state {
	PACKET_STATE_UNCRYPTED,
	PACKET_STATE_CRYPTED,
	PACKET_STATE_DEAD
};

struct packet_cb {
	u64 nonce;
	struct noise_keypair *keypair;
	atomic_t state;
	u32 mtu;
	u8 ds;
};

#define PACKET_CB(skb) ((struct packet_cb *)((skb)->cb))
#define PACKET_PEER(skb) (PACKET_CB(skb)->keypair->entry.peer)

static inline bool wg_check_packet_protocol(struct sk_buff *skb)
{
	__be16 real_protocol = ip_tunnel_parse_protocol(skb);
	return real_protocol && skb->protocol == real_protocol;
}

static inline void wg_reset_packet(struct sk_buff *skb, bool encapsulating)
{
	u8 l4_hash = skb->l4_hash;
	u8 sw_hash = skb->sw_hash;
	u32 hash = skb->hash;
	skb_scrub_packet(skb, true);
	memset(&skb->headers_start, 0,
	       offsetof(struct sk_buff, headers_end) -
		       offsetof(struct sk_buff, headers_start));
	if (encapsulating) {
		skb->l4_hash = l4_hash;
		skb->sw_hash = sw_hash;
		skb->hash = hash;
	}
	skb->queue_mapping = 0;
	skb->nohdr = 0;
	skb->peeked = 0;
	skb->mac_len = 0;
	skb->dev = NULL;
#ifdef CONFIG_NET_SCHED
	skb->tc_index = 0;
#endif
	skb_reset_redirect(skb);
	skb->hdr_len = skb_headroom(skb);
	skb_reset_mac_header(skb);
	skb_reset_network_header(skb);
	skb_reset_transport_header(skb);
	skb_probe_transport_header(skb);
	skb_reset_inner_headers(skb);
}

static inline int wg_cpumask_choose_online(int *stored_cpu, unsigned int id)
{
	unsigned int cpu = *stored_cpu, cpu_index, i;

	if (unlikely(cpu == nr_cpumask_bits ||
		     !cpumask_test_cpu(cpu, cpu_online_mask))) {
		cpu_index = id % cpumask_weight(cpu_online_mask);
		cpu = cpumask_first(cpu_online_mask);
		for (i = 0; i < cpu_index; ++i)
			cpu = cpumask_next(cpu, cpu_online_mask);
		*stored_cpu = cpu;
	}
	return cpu;
}

/* This function is racy, in the sense that it's called while last_cpu is
 * unlocked, so it could return the same CPU twice. Adding locking or using
 * atomic sequence numbers is slower though, and the consequences of racing are
 * harmless, so live with it.
 */
static inline int wg_cpumask_next_online(int *last_cpu)
{
	int cpu = cpumask_next(READ_ONCE(*last_cpu), cpu_online_mask);
	if (cpu >= nr_cpu_ids)
		cpu = cpumask_first(cpu_online_mask);
	WRITE_ONCE(*last_cpu, cpu);
	return cpu;
}

void wg_prev_queue_init(struct prev_queue *queue);

/* Multi producer */
bool wg_prev_queue_enqueue(struct prev_queue *queue, struct sk_buff *skb);

/* Single consumer */
struct sk_buff *wg_prev_queue_dequeue(struct prev_queue *queue);

/* Single consumer */
static inline struct sk_buff *wg_prev_queue_peek(struct prev_queue *queue)
{
	if (queue->peeked)
		return queue->peeked;
	queue->peeked = wg_prev_queue_dequeue(queue);
	return queue->peeked;
}

/* Single consumer */
static inline void wg_prev_queue_drop_peeked(struct prev_queue *queue)
{
	queue->peeked = NULL;
}

static inline int wg_queue_enqueue_per_device_and_peer(
	struct crypt_queue *device_queue, struct prev_queue *peer_queue,
	struct sk_buff *skb, struct workqueue_struct *wq)
{
	int cpu;

	atomic_set_release(&PACKET_CB(skb)->state, PACKET_STATE_UNCRYPTED);
	/* We first queue this up for the peer ingestion, but the consumer
	 * will wait for the state to change to CRYPTED or DEAD before.
	 */
	if (unlikely(!wg_prev_queue_enqueue(peer_queue, skb)))
		return -ENOSPC;

	/* Then we queue it up in the device queue, which consumes the
	 * packet as soon as it can.
	 */
	cpu = wg_cpumask_next_online(&device_queue->last_cpu);
	if (unlikely(ptr_ring_produce_bh(&device_queue->ring, skb)))
		return -EPIPE;
	queue_work_on(cpu, wq, &per_cpu_ptr(device_queue->worker, cpu)->work);
	return 0;
}

static inline void wg_queue_enqueue_per_peer_tx(struct sk_buff *skb, enum packet_state state)
{
	/* We take a reference, because as soon as we call atomic_set, the
	 * peer can be freed from below us.
	 */
	struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));

	atomic_set_release(&PACKET_CB(skb)->state, state);
	queue_work_on(wg_cpumask_choose_online(&peer->serial_work_cpu, peer->internal_id),
		      peer->device->packet_crypt_wq, &peer->transmit_packet_work);
	wg_peer_put(peer);
}

/* RX completion-coalescing trigger knobs (defined in main.c, live-tunable). */
extern unsigned long wg_trig_k;       /* batch threshold; 0 => trigger OFF (stock) */
extern unsigned long wg_trig_tau_ns;  /* coalesce window in nanoseconds */
extern unsigned long wg_supp;         /* 1 => suppress wasted MISSED re-polls (poll side) */
extern unsigned long wg_headwake;     /* 1 => only wake when this completion makes the head ready */
extern unsigned long wg_decrypt_delay_ns; /* busy-wait injected per decrypt to slow T_decrypt (0=off) */
/* Diagnostic (wg_diag): classify head-state × MISSED at poll completion. */
extern unsigned long wg_diag;
extern unsigned long wg_diag_empty_missed, wg_diag_empty_nomiss;
extern unsigned long wg_diag_uncrypt_missed, wg_diag_uncrypt_nomiss;
extern unsigned long wg_diag_supp_cleared, wg_diag_supp_rearmed, wg_diag_supp_reset_race;
extern unsigned long wg_diag_stall_empty[7], wg_diag_stall_uncrypt[7];
extern unsigned long wg_steal;        /* max packets the poll decrypts itself while head-blocked (0=off) */
extern unsigned long wg_diag_steal_pulled, wg_diag_steal_unblocked, wg_diag_steal_dryruns;

/* Per-peer hrtimer callback (defined in receive.c): liveness backstop that
 * wakes the poll when the coalesce window elapses before K completions land.
 */
enum hrtimer_restart wg_rx_coalesce_timer(struct hrtimer *timer);

static inline void wg_queue_enqueue_per_peer_rx(struct sk_buff *skb, enum packet_state state)
{
	/* We take a reference, because as soon as we call atomic_set, the
	 * peer can be freed from below us.
	 */
	struct wg_peer *peer = wg_peer_get(PACKET_PEER(skb));

	atomic_set_release(&PACKET_CB(skb)->state, state);

	/* Head-gated wake (wg_headwake) — the root fix. Only wake the poll when this
	 * completion can actually advance delivery: we are completing the exact packet
	 * the poll parked on (peer->rx_blocked_on == skb), or the poll parked on an
	 * empty queue (rx_blocked_on == NULL) so any arrival is the new head. A
	 * non-head completion cannot make an UNCRYPTED head deliverable, so waking on
	 * it only yields a wasted poll — stay silent. The poll publishes rx_blocked_on
	 * and then re-checks, so a head completion racing this window is never lost.
	 * We only COMPARE the pointer, never dereference it, so it is race-safe wrt the
	 * queue. DEAD/error packets fall through to the immediate wake (must be drained).
	 */
	if (wg_headwake && likely(state == PACKET_STATE_CRYPTED)) {
		struct sk_buff *b;

		/* Dekker pairing with the poll's publish+recheck (receive.c): a full
		 * barrier between making this packet CRYPTED (the store_release above)
		 * and reading rx_blocked_on guarantees that if we read a stale value
		 * and skip the wake, the poll's re-check is ordered to observe CRYPTED
		 * and re-poll. Without it the two-sided store-buffer race strands the
		 * packet (observed as a tunnel stall).
		 */
		smp_mb();
		b = READ_ONCE(peer->rx_blocked_on);
		if (b == NULL || b == skb)
			napi_schedule(&peer->napi);
		wg_peer_put(peer);
		return;
	}

	/* Trigger off (k==0), or a non-CRYPTED packet (DEAD/error): keep stock
	 * behaviour and wake the poll immediately so it can drain and free.
	 */
	if (!wg_trig_k || unlikely(state != PACKET_STATE_CRYPTED)) {
		napi_schedule(&peer->napi);
		wg_peer_put(peer);
		return;
	}

	/* Count-or-timeout coalescing. Each decrypt completion bumps the
	 * contiguous-ready estimate (reset on poll entry). Once K are ready we
	 * have a worthwhile batch: cancel any pending timer and wake now.
	 * Otherwise arm a single coalesce timer (one owner via cmpxchg) so
	 * followers completing within tau ride the same poll instead of each
	 * triggering its own (often wasted) poll.
	 */
	if (atomic_inc_return(&peer->rx_ready) >= (int)wg_trig_k) {
		if (atomic_xchg(&peer->rx_timer_armed, 0))
			hrtimer_try_to_cancel(&peer->rx_coalesce_timer);
		napi_schedule(&peer->napi);
	} else if (atomic_cmpxchg(&peer->rx_timer_armed, 0, 1) == 0) {
		hrtimer_start(&peer->rx_coalesce_timer,
			      ns_to_ktime(wg_trig_tau_ns), HRTIMER_MODE_REL_SOFT);
	}
	wg_peer_put(peer);
}

#ifdef DEBUG
bool wg_packet_counter_selftest(void);
#endif

#endif /* _WG_QUEUEING_H */
