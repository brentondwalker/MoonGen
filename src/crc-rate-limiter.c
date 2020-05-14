#include <stdint.h>
#include <stdlib.h>
#include <rte_config.h>
#include <rte_ethdev.h>
#include <rte_mbuf.h>
#include <rte_mempool.h>
#include <stdio.h>

#include "device.h"

static uint64_t bad_pkts_sent[RTE_MAX_ETHPORTS];
static uint64_t bad_bytes_sent[RTE_MAX_ETHPORTS];

uint64_t moongen_get_bad_pkts_sent(uint8_t port_id) {
	return __sync_fetch_and_add(&bad_pkts_sent[port_id], 0);
}

uint64_t moongen_get_bad_bytes_sent(uint8_t port_id) {
	return __sync_fetch_and_add(&bad_bytes_sent[port_id], 0);
}

/*
static struct rte_mbuf* get_delay_pkt_bad_crc_debug(struct rte_mempool* pool, uint32_t* rem_delay, uint32_t min_pkt_size) {
	// _Thread_local support seems to suck in (older?) gcc versions?
	// this should give us the best compatibility
	//static __thread uint64_t target = 0;
	//static __thread uint64_t current = 0;

	// for some desired delays and rates, we can't emulate the inter-packet
	// times exactly because of the min frame size.  In these cases we need
	// to keep track of the delay that has yet to be emulated, and add it in
	// when emough accumulates.
	static __thread uint64_t leftover_delay = 0;

	//printf("rem %u\t%lu\t%lu\n",*rem_delay,target,current);
	printf("rem %u\t%lu\t\n",*rem_delay,leftover_delay);
	uint64_t delay = *rem_delay + leftover_delay;
	//target += delay;
	//if (target < current) {
	//	// don't add a delay
	//	*rem_delay = 0;
	//	printf("exiting because target %lu < current %lu\n",target,current);
	//	printf("delay: %lu\t%ld\n",delay,delay);
	//	return NULL;
	//}
	// add delay
	//target -= current;
	//current = 0;
	if (delay < min_pkt_size) {
		// this will have to be added in the next cycle.
		leftover_delay = delay;
		// *rem_delay = min_pkt_size; // will be set to 0 at the end of the function
		//delay = min_pkt_size;
		*rem_delay = 0;
		delay = 0;
		return NULL;
	}
	// calculate the optimimum packet size
	if (delay < 1538) {
		delay = delay;
	} else if (delay > 2000) {
		// 2000 is an arbitrary chosen value as it doesn't really matter
		// we just need to avoid doing something stupid for packet sizes that are just over 1538 bytes
		delay = 1538;
	} else {
		// delay between 1538 and 2000
		delay = delay / 2;
	}
	*rem_delay -= delay;
	struct rte_mbuf* pkt = rte_pktmbuf_alloc(pool);
	// account for preamble, sfd, and ifg (CRC is disabled)
	pkt->data_len = delay - 20;
	pkt->pkt_len = delay - 20;
	pkt->ol_flags |= PKT_TX_NO_CRC_CSUM;
	//current += delay;
	//current = delay;
	//printf("%u\t%lu\t%lu\n",*rem_delay,target,current);
	printf("%u\t%lu\n",*rem_delay,leftover_delay);
	return pkt;
}
*/

static struct rte_mbuf* get_delay_pkt_bad_crc(struct rte_mempool* pool, uint32_t* rem_delay, uint32_t min_pkt_size) {
	// for some desired delays and rates, we can't emulate the inter-packet
	// times exactly because of the min frame size.  In these cases we need
	// to keep track of the accumulated delay that has yet to be emulated,
	//and add it in when emough accumulates.
	static __thread uint64_t leftover_delay = 0;

	uint64_t delay = *rem_delay + leftover_delay;
	leftover_delay = 0;

	//printf("delay=%lu\tleftover_delay=%lu\n",delay,leftover_delay);

	if (delay < min_pkt_size) {
		// this will have to be added in the next cycle.
		leftover_delay = delay;
		*rem_delay = 0;
		delay = 0;
		//printf("leftover_delay %lu\n",leftover_delay);
		return NULL;
	}

	// calculate the optimimum packet size
	if (delay < 1538) {
		delay = delay;
	} else if (delay > 2000) {
		// 2000 is an arbitrary chosen value as it doesn't really matter
		// we just need to avoid doing something stupid for packet sizes that are just over 1538 bytes
		delay = 1538;
	} else {
		// delay between 1538 and 2000
		delay = delay / 2;
	}
	if (delay > *rem_delay) {
		*rem_delay  = 0;
	} else {
		*rem_delay -= delay;
	}
	//printf("rem_delay=%u\n",*rem_delay);
	struct rte_mbuf* pkt = rte_pktmbuf_alloc(pool);
	// account for preamble, sfd, and ifg (CRC is disabled)
	pkt->data_len = delay - 20;
	pkt->pkt_len = delay - 20;
	pkt->ol_flags |= PKT_TX_NO_CRC_CSUM;
	return pkt;
}



void moongen_send_all_packets_with_delay_bad_crc(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool, uint32_t min_pkt_size) {
	const int BUF_SIZE = 128;
	struct rte_mbuf* pkts[BUF_SIZE];
	int send_buf_idx = 0;
	uint32_t num_bad_pkts = 0;
	uint32_t num_bad_bytes = 0;
	//printf("num_pkts=%u\n",num_pkts);
	for (uint16_t i = 0; i < num_pkts; i++) {
		uint32_t nbp = 0;
		uint32_t nbb = 0;
		struct rte_mbuf* pkt = load_pkts[i];
		// desired inter-frame spacing is encoded in the hash 'usr' field
		uint32_t delay = (uint32_t) pkt->udata64;
		//printf("desired delay: %u\n",delay);
		// step 1: generate delay-packets
		while (delay > 0) {
			struct rte_mbuf* pkt = get_delay_pkt_bad_crc(pool, &delay, min_pkt_size);
			if (pkt) {
				num_bad_pkts++;
				nbp++;
				// packet size: [MAC, CRC] to be consistent with HW counters
				num_bad_bytes += pkt->pkt_len + 24;
				nbb += pkt->pkt_len + 24;
				pkts[send_buf_idx++] = pkt;
			}
			if (send_buf_idx >= BUF_SIZE) {
				//printf("*** sending packets in loop\n");
				dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
				send_buf_idx = 0;
			}
		}
		//printf("num bad packets sent: %u\t bad bytes: %u\n", nbp, nbb);

		// step 2: send the packet
		pkts[send_buf_idx++] = pkt;
		if (send_buf_idx >= BUF_SIZE || i + 1 == num_pkts) { // don't forget to send the last batch
			//printf("*** sending packets after loop %d\n",send_buf_idx);
			dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
			send_buf_idx = 0;
		}
	}
	//printf("send_pkts exited loop\n");
	// atomic as multiple threads may use the same stats register from multiple queues
	__sync_fetch_and_add(&bad_pkts_sent[port_id], num_bad_pkts);
	__sync_fetch_and_add(&bad_bytes_sent[port_id], num_bad_bytes);
	return;
}

void moongen_send_all_packets_with_delay_bad_crc_loss(uint8_t port_id, uint16_t queue_id, struct rte_mbuf** load_pkts, uint16_t num_pkts, struct rte_mempool* pool, uint32_t min_pkt_size, double loss_rate) {
	const int BUF_SIZE = 128;
	struct rte_mbuf* pkts[BUF_SIZE];
	int send_buf_idx = 0;
	uint32_t num_bad_pkts = 0;
	uint32_t num_bad_bytes = 0;
	//printf("num_pkts=%u\n",num_pkts);
	for (uint16_t i = 0; i < num_pkts; i++) {
		uint32_t nbp = 0;
		uint32_t nbb = 0;
		struct rte_mbuf* pkt;
		pkt = load_pkts[i];

		// desired inter-frame spacing is encoded in the hash 'usr' field
		uint32_t delay = (uint32_t) pkt->udata64;
		//printf("desired delay: %u\n",delay);

		if (pkt->udata64 > 0x0fffffff) {
			printf("WARNING: moongen_send_all_packets_with_delay_bad_crc_loss: bad value in udata64 %lx\n",pkt->udata64);
			delay = 0;
		}

		// step 1: generate delay-packets
		while (delay > 0) {
			struct rte_mbuf* bad_pkt = get_delay_pkt_bad_crc(pool, &delay, min_pkt_size);
			if (bad_pkt) {
				num_bad_pkts++;
				nbp++;
				// packet size: [MAC, CRC] to be consistent with HW counters
				num_bad_bytes += bad_pkt->pkt_len;
				nbb += pkt->pkt_len + 24;
				pkts[send_buf_idx++] = bad_pkt;
			}
			if (send_buf_idx >= BUF_SIZE) {
				dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
				send_buf_idx = 0;
			}
		}
		//printf("num bad packets sent: %u\t bad bytes: %u\n", nbp, nbb);

		// step 2: send the packet
		// include random losses
		if ((double)rand()/RAND_MAX >= loss_rate) {
			pkts[send_buf_idx++] = pkt;
		} else {
			// if the packet is not going to be sent, we have to free the mbuf.
			rte_pktmbuf_free(pkt);
		}
		if (send_buf_idx >= BUF_SIZE || i + 1 == num_pkts) { // don't forget to send the last batch
			dpdk_send_all_packets(port_id, queue_id, pkts, send_buf_idx);
			send_buf_idx = 0;
		}
	}
	// atomic as multiple threads may use the same stats register from multiple queues
	__sync_fetch_and_add(&bad_pkts_sent[port_id], num_bad_pkts);
	__sync_fetch_and_add(&bad_bytes_sent[port_id], num_bad_bytes);
	return;
}

