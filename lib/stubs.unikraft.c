/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Authors: Simon Kuenzer <simon.kuenzer@neclab.eu>
 *          Fabrice Buoro <fabrice@tarides.com>
 *          Romain Calascibetta <romain.calascibetta@gmail.com>
 *          Roxana Nicolescu <nicolescu.roxana1996@gmail.com>
 *
 * Copyright (c) 2019, NEC Laboratories Europe GmbH, NEC Corporation.
 *               2019, University Politehnica of Bucharest.
 *               2024-2025, Tarides.
 *               2025-2026, Robur Cooperative.
 *               All rights reserved.
 */

#include <stdint.h>

#define MAX_NET_DEVICES 16
#define MAX_BLK_DEVICES 16
#define MAX_BLK_TOKENS 62

typedef unsigned int net_id_t;
typedef unsigned int block_id_t;
typedef unsigned int token_id_t;

#include <uk/assert.h>
#include <uk/netdev.h>
#include <uk/print.h>

struct netif {
  struct uk_netdev *dev;
  struct uk_alloc *alloc;
  struct uk_netdev_info dev_info;
  unsigned id;
};

#include <uk/alloc.h>
#include <uk/assert.h>
#include <uk/blkdev.h>
#include <uk/plat/time.h>
#include <uk/print.h>

struct token_s;
typedef struct token_s token_t;

typedef unsigned token_id_t;
typedef unsigned stoken_id_t;

struct token_s {
  struct uk_blkreq req;
  struct block_s *block;
};

typedef struct block_s {
  struct uk_blkdev *dev;
  struct uk_alloc *alloc;
  unsigned int id;
  _Atomic unsigned long inflight;
  token_t *tokens;
} block_t;

#ifdef __Unikraft__

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

/* Scheduler operations */

pthread_mutex_t ready_sets_mutex = PTHREAD_MUTEX_INITIALIZER;
pthread_cond_t ready_sets_cond = PTHREAD_COND_INITIALIZER;
uint64_t netdev_ready_set;
uint64_t blkdev_ready_set[MAX_BLK_DEVICES];

static uint64_t netdev_to_setid(net_id_t id) {
  assert(id < 63);
  return 1L << id;
}

static uint64_t token_to_setid(token_id_t id) {
  assert(id < 63);
  return 1L << id;
}

void set_netdev_queue_empty(net_id_t id) {
  pthread_mutex_lock(&ready_sets_mutex);
  netdev_ready_set &= ~(netdev_to_setid(id));
  pthread_mutex_unlock(&ready_sets_mutex);
}

static bool netdev_is_queue_ready(net_id_t id) {
  bool ready;

  pthread_mutex_lock(&ready_sets_mutex);
  ready = (netdev_ready_set & netdev_to_setid(id)) != 0;
  pthread_mutex_unlock(&ready_sets_mutex);
  return ready;
}

void signal_netdev_queue_ready(net_id_t id) {
  pthread_mutex_lock(&ready_sets_mutex);
  netdev_ready_set |= netdev_to_setid(id);
  pthread_cond_broadcast(&ready_sets_cond);
  pthread_mutex_unlock(&ready_sets_mutex);
}

void signal_block_request_ready(block_id_t devid, token_id_t tokenid) {
  pthread_mutex_lock(&ready_sets_mutex);
  blkdev_ready_set[devid] |= token_to_setid(tokenid);
  pthread_cond_broadcast(&ready_sets_cond);
  pthread_mutex_unlock(&ready_sets_mutex);
}

void set_block_request_completed(block_id_t devid, token_id_t tokenid) {
  pthread_mutex_lock(&ready_sets_mutex);
  blkdev_ready_set[devid] &= ~(token_to_setid(tokenid));
  pthread_mutex_unlock(&ready_sets_mutex);
}

typedef union {
  net_id_t netid;
  struct {
    block_id_t blkid;
    token_id_t tokid;
  };
} u_next_io;

typedef enum { NONE, NET, BLOCK } e_next_io;

#define NANO 1000000000
static e_next_io yield(uint64_t deadline, u_next_io *next_io) {
  struct timeval now;
  struct timespec timeout;
  e_next_io next = NONE;

  gettimeofday(&now, NULL);
  timeout.tv_sec = now.tv_sec + deadline / NANO;
  timeout.tv_nsec = now.tv_usec * 1000 + deadline % NANO;
  if (timeout.tv_nsec >= NANO) {
    timeout.tv_sec += 1;
    timeout.tv_nsec -= NANO;
  }

  pthread_mutex_lock(&ready_sets_mutex);
  do {
    if (netdev_ready_set != 0) {
      for (net_id_t i = 0; i < MAX_NET_DEVICES; i++) {
        if (netdev_ready_set & netdev_to_setid(i)) {
          next = NET;
          next_io->netid = i;
          goto out;
        }
      }
    }
    for (block_id_t i = 0; i < MAX_BLK_DEVICES; i++) {
      if (blkdev_ready_set[i] != 0) {
        for (token_id_t j = 0; j < MAX_BLK_TOKENS; j++) {
          if (blkdev_ready_set[i] & token_to_setid(j)) {
            next = BLOCK;
            next_io->blkid = i;
            next_io->tokid = j;
            goto out;
          }
        }
      }
    }

    int rc =
        pthread_cond_timedwait(&ready_sets_cond, &ready_sets_mutex, &timeout);
    if (rc == ETIMEDOUT) {
      break;
    }
  } while (1);
out:
  pthread_mutex_unlock(&ready_sets_mutex);
  return next;
}

void uk_yield(uint64_t deadline, value result) {
  assert(deadline >= 0);

  u_next_io next_io = {.blkid = -1, .tokid = -1};
  uint64_t uid = 0;
  uint64_t tuid = 0;
  memset(Bytes_val(result), 0, 17);
  switch (yield(deadline, &next_io)) {
  case NONE:
    break;

  case NET:
    assert(next_io.netid != -1);
    uid = next_io.netid;
    Bytes_val(result)[0] = '\001';
    memcpy(Bytes_val(result) + 1, (uint64_t *)&uid, sizeof(uint64_t));
    break;

  case BLOCK:
    assert(next_io.blkid != -1 && next_io.tokid != -1);
    Bytes_val(result)[0] = '\002';
    uid = next_io.blkid;
    tuid = next_io.tokid;
    memcpy(Bytes_val(result) + 1, (uint64_t *)&uid, sizeof(uint64_t));
    memcpy(Bytes_val(result) + 9, (uint64_t *)&tuid, sizeof(uint64_t));
    break;
  }
}

bool uk_netdev_is_queue_ready(intnat devid) {
  return (netdev_is_queue_ready(devid));
}

/* Misc */

CAMLprim value alloc_result_ok(value v) {
  CAMLparam1(v);
  CAMLlocal1(v_result);

  v_result = caml_alloc(1, 0);
  Store_field(v_result, 0, v);
  CAMLreturn(v_result);
}

CAMLprim value alloc_result_error(const char *msg) {
  CAMLparam0();
  CAMLlocal2(v_result, v_error);

  v_error = caml_copy_string(msg);
  v_result = caml_alloc_1(1, v_error);
  CAMLreturn(v_result);
}

/* Net operations */

// Size of the buffer area for uk_netbuf allocation
#define UKNETDEV_BUFLEN 2048

static struct uk_netbuf *netdev_alloc_rx_netbuf(const struct netif *netif) {
  struct uk_netbuf *netbuf = NULL;
  struct uk_alloc *alloc = netif->alloc;
  const size_t size = UKNETDEV_BUFLEN;
  const size_t align = netif->dev_info.ioalign;
  const size_t headroom = netif->dev_info.nb_encap_rx;
  const size_t priv_len = 0;

  netbuf = uk_netbuf_alloc_buf(alloc, size, align, headroom, priv_len, NULL);
  if (!netbuf) {
    return NULL;
  }
  netbuf->len = netbuf->buflen - headroom;
  return netbuf;
}

static struct uk_netbuf *netdev_alloc_tx_netbuf(const struct netif *netif) {
  struct uk_netbuf *netbuf = NULL;
  struct uk_alloc *alloc = netif->alloc;
  const size_t size = UKNETDEV_BUFLEN;
  const size_t align = netif->dev_info.ioalign;
  const size_t headroom = netif->dev_info.nb_encap_tx;
  const size_t priv_len = 0;

  netbuf = uk_netbuf_alloc_buf(alloc, size, align, headroom, priv_len, NULL);
  if (!netbuf) {
    return NULL;
  }
  return netbuf;
}

intnat uk_netdev_tx(struct netif *netif, struct uk_netbuf *netbuf,
                    int64_t size) {
  int rc;

  netbuf->len = size;

  do {
    rc = uk_netdev_tx_one(netif->dev, 0, netbuf);
  } while (uk_netdev_status_notready(rc));

  if (rc < 0) {
    uk_netbuf_free_single(netbuf);
    return -1;
  }
  return 0;
}

intnat uk_get_tx_buffer(struct netif *netif, size_t size) {
  struct uk_netbuf *nb;

  nb = netdev_alloc_tx_netbuf(netif);
  if (!nb)
    return -1;

  const size_t tailroom = uk_netbuf_tailroom(nb);
  if (size > tailroom) {
    uk_netbuf_free_single(nb);
    return -1;
  }
  nb->len = size;
  memset(nb->data, 0, nb->len);
  return ((intnat)nb);
}

CAMLprim value uk_netbuf_to_bigarray(struct uk_netbuf *nb) {
  CAMLparam0();
  CAMLlocal1(ba);

  ba =
      caml_ba_alloc_dims(CAML_BA_CHAR | CAML_BA_C_LAYOUT, 1, nb->data, nb->len);

  CAMLreturn(ba);
}

uint16_t netdev_alloc_rxpkts(void *argp, struct uk_netbuf *nb[],
                             uint16_t count) {
  struct netif *netif = (struct netif *)argp;
  uint16_t i;

  for (i = 0; i < count; ++i) {
    nb[i] = netdev_alloc_rx_netbuf(netif);
    if (!nb[i]) {
      /* we run out of memory */
      break;
    }
  }
  return i;
}

/* Returns
 * -1 on error
 *  0 on success
 *  1 on success and more to process
 */
static int netdev_rx(struct netif *netif, uint8_t *buf, size_t *size) {
  struct uk_netdev *dev = netif->dev;
  struct uk_netbuf *nb;
  unsigned bufsize = *size;

  *size = 0;

  const int rc = uk_netdev_rx_one(dev, 0, &nb);
  if (rc < 0)
    return -1;

  if (!uk_netdev_status_successful(rc))
    return 0;

  const bool more = uk_netdev_status_more(rc);

  /* If bufsize < nb->len, simply drop the extra trailing bytes, as they cannot
   * be part of the packet payload or it would exceed MTU; so define len, the
   * number of bytes to copy, to be the minimum of bufsize and nb->len */
  const unsigned len = (bufsize < nb->len) ? bufsize : nb->len;
  memcpy(buf, nb->data, len);
  *size = len;
  uk_netbuf_free_single(nb);

  return (more ? 1 : 0);
}

intnat uk_netdev_rx(struct netif *netif, value vbstr, intnat off, intnat len,
                    value read_size) {
  size_t size = len;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  const int rc = netdev_rx(netif, buf, &size);
  memcpy(Bytes_val(read_size), (uint64_t *)&size, sizeof(uint64_t));
  if (rc == 0)
    set_netdev_queue_empty(netif->id);
  return rc;
}

static struct netif *init_netif(unsigned id) {
  struct netif *netif = malloc(sizeof(*netif));
  memset(netif, 0, sizeof(*netif));

  netif->alloc = uk_alloc_get_default();
  if (!netif->alloc) {
    free(netif);
    return NULL;
  }
  netif->id = id;
  return netif;
}

static void netdev_queue_event(struct uk_netdev *netdev, uint16_t queueid,
                               void *argp) {
  struct netif *netif = argp;

  (void)netdev;
  (void)queueid;
  signal_netdev_queue_ready(netif->id);
}

static int netdev_configure(struct netif *netif) {
  struct uk_netdev *dev = netif->dev;
  struct uk_netdev_info *dev_info = &netif->dev_info;
  int rc;

  UK_ASSERT(dev != NULL);
  UK_ASSERT(uk_netdev_state_get(dev) == UK_NETDEV_UNCONFIGURED);

  uk_netdev_info_get(dev, dev_info);
  if (!dev_info->max_rx_queues || !dev_info->max_tx_queues)
    return -1;

  struct uk_netdev_conf dev_conf = {0};
  dev_conf.nb_rx_queues = 1;
  dev_conf.nb_tx_queues = 1;
  rc = uk_netdev_configure(dev, &dev_conf);
  if (rc < 0)
    return -1;

  struct uk_netdev_rxqueue_conf rxq_conf = {0};
  rxq_conf.a = netif->alloc;
  rxq_conf.alloc_rxpkts = netdev_alloc_rxpkts;
  rxq_conf.alloc_rxpkts_argp = netif;

  rxq_conf.callback = netdev_queue_event;
  rxq_conf.callback_cookie = netif;
  rxq_conf.s = uk_sched_current();
  if (!rxq_conf.s)
    return -1;

  rc = uk_netdev_rxq_configure(dev, 0, 0, &rxq_conf);
  if (rc < 0)
    return -1;

  struct uk_netdev_txqueue_conf txq_conf = {0};
  txq_conf.a = netif->alloc;
  rc = uk_netdev_txq_configure(dev, 0, 0, &txq_conf);
  if (rc < 0)
    return -1;

  rc = uk_netdev_start(dev);
  if (rc < 0)
    return -1;

  if (!uk_netdev_rxintr_supported(dev_info->features))
    return -1;

  rc = uk_netdev_rxq_intr_enable(dev, 0);
  if (rc < 0)
    return -1;
  else if (rc == 1)
    signal_netdev_queue_ready(netif->id);

  return 0;
}

intnat uk_netdev_stop(struct netif *netif) {
  struct uk_netdev *dev = netif->dev;

  UK_ASSERT(dev != NULL);
  UK_ASSERT(uk_netdev_state_get(dev) == UK_NETDEV_RUNNING);

  if (uk_netdev_rxq_intr_disable(dev, 0) < 0)
    return -1;

  free(netif);

  return 0;
}

intnat uk_netdev_init(const intnat id) {
  UK_ASSERT(id >= 0);

  struct netif *netif;
  struct uk_netdev *netdev;
  netif = init_netif(id);

  if (!netif)
    return -1;

  netdev = uk_netdev_get(id);

  if (!netdev) {
    free(netif);
    return -1;
  }

  netif->dev = netdev;

  if (uk_netdev_state_get(netdev) != UK_NETDEV_UNPROBED) {
    free(netif);
    return -1;
  }

  if (uk_netdev_probe(netdev) < 0) {
    free(netif);
    return -1;
  }

  if (uk_netdev_state_get(netdev) != UK_NETDEV_UNCONFIGURED) {
    free(netif);
    return -1;
  }

  if (netdev_configure(netif) < 0) {
    free(netif);
    return -1;
  }

  return ((intnat)netif);
}

// ---------------------------------------------------------------------------//

void uk_netdev_mac(const struct netif *netif, value v_mac) {
  memcpy(Bytes_val(v_mac), uk_netdev_hwaddr_get(netif->dev)->addr_bytes, 6);
}

int uk_netdev_mtu(const struct netif *netif) {
  return (uk_netdev_mtu_get(netif->dev));
}

/* Block operations. */

block_t blocks[MAX_BLK_DEVICES] = {0};

static token_t *acquire_token(block_t *block) {
  token_t *token;

  for (unsigned int i = 0; i < MAX_BLK_TOKENS; i++) {
    const unsigned long pos = 1L << i;
    unsigned long old = block->inflight;
    while ((old & pos) == 0) {
      const unsigned long new = old | pos;
      if (atomic_compare_exchange_strong(&block->inflight, &old, new)) {
        token = &block->tokens[i];
        assert(uk_blkreq_is_done(&token->req));
        return token;
      }
    }
  }
  return NULL;
}

static token_id_t token_id(block_t *block, token_t *token) {
  return token - block->tokens;
}

static void release_token(block_t *block, token_t *token) {
  token_id_t id = token_id(block, token);

  unsigned long mask = ~(1L << id);
  block->inflight &= mask;
}

void req_callback(struct uk_blkreq *req, void *cookie) {
  token_t *token = (token_t *)cookie;
  block_t *block = token->block;

  token_id_t tok_id = token_id(block, token);

  signal_block_request_ready(block->id, tok_id);
}

void queue_callback(struct uk_blkdev *dev, uint16_t queue_id, void *argp) {
  (void)argp;

  int rc = uk_blkdev_queue_finish_reqs(dev, 0);
  if (rc) {
    uk_pr_err("Error finishing request: %d\n", rc);
  }
}

stoken_id_t block_async_io(block_t *block, int write, unsigned long sstart,
                           unsigned long size, char *buf) {

  token_t *token = acquire_token(block);
  if (!token) {
    return -1;
  }

  struct uk_blkreq *req = &token->req;
  uk_blkreq_init(req, write ? UK_BLKREQ_WRITE : UK_BLKREQ_READ, sstart, size,
                 buf, req_callback, token);
  assert(!uk_blkreq_is_done(&token->req));

  int rc = uk_blkdev_queue_submit_one(block->dev, 0, &token->req);
  if (rc < 0) {
    release_token(block, token);
    return -1;
  }

  return token_id(block, token);
}

// -------------------------------------------------------------------------- //

static block_t *block_init(unsigned int id) {
  block_t *block = &blocks[id];

  block->tokens = malloc(MAX_BLK_TOKENS * sizeof(token_t));
  if (!block->tokens) {
    return NULL;
  }

  for (int i = 0; i < MAX_BLK_TOKENS; i++) {
    block->tokens[i].block = block;
  }

  block->inflight = 0;
  block->id = id;
  return block;
}

static void block_deinit(block_t *block) {
  if (block->tokens) {
    free(block->tokens);
  }
  block->inflight = 0;
}

static block_t *block_get(unsigned int id, const char **err) {
  block_t *block;

  block = block_init(id);
  if (!block) {
    *err = "Failed to allocate memory for blkdev";
    return NULL;
  }

  block->dev = uk_blkdev_get(id);
  if (!block->dev) {
    *err = "Failed to acquire block device";
    block_deinit(block);
    return NULL;
  }

  block->alloc = uk_alloc_get_default();
  if (!block->alloc) {
    *err = "Failed to get default allocator";
    block_deinit(block);
    return NULL;
  }
  return block;
}

static int block_configure(block_t *block, const char **err) {
  int rc;

  if (uk_blkdev_state_get(block->dev) != UK_BLKDEV_UNCONFIGURED) {
    *err = "Block device not in unconfigured state";
    return -1;
  }

  struct uk_blkdev_info info;
  rc = uk_blkdev_get_info(block->dev, &info);
  if (rc) {
    *err = "Error getting device information";
    return -1;
  }

  struct uk_blkdev_conf conf = {0};
  conf.nb_queues = 1;
  rc = uk_blkdev_configure(block->dev, &conf);
  if (rc) {
    *err = "Error configuring device";
    return -1;
  }

  struct uk_blkdev_queue_info q_info;
  rc = uk_blkdev_queue_get_info(block->dev, 0, &q_info);
  if (rc) {
    *err = "Error getting device queue information";
    return -1;
  }

  assert(MAX_BLK_TOKENS < q_info.nb_max);

  struct uk_blkdev_queue_conf q_conf = {0};
  q_conf.a = block->alloc;
  q_conf.callback = queue_callback;
  q_conf.callback_cookie = block;
  q_conf.s = uk_sched_current();
  // nb_desc = 0: device default queue length
  rc = uk_blkdev_queue_configure(block->dev, 0, 0, &q_conf);
  if (rc) {
    *err = "Error configuring device queue";
    return -1;
  }

  rc = uk_blkdev_start(block->dev);
  if (rc) {
    *err = "Error starting block device";
    return -1;
  }

  if (uk_blkdev_state_get(block->dev) != UK_BLKDEV_RUNNING) {
    *err = "Block device not in running state";
    return -1;
  }

  const struct uk_blkdev_cap *cap = uk_blkdev_capabilities(block->dev);
  if (cap->mode == O_WRONLY) {
    *err = "Write-only devices are not supported";
    return -1;
  }

  rc = uk_blkdev_queue_intr_enable(block->dev, 0);
  if (rc) {
    *err = "Error enabling interrupt for block device queue";
    return -1;
  }
  return 0;
}

// -------------------------------------------------------------------------- //

#define CAML_NAME_SPACE
#include <caml/alloc.h>
#include <caml/bigarray.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>

value uk_block_init(value v_id) {
  CAMLparam1(v_id);
  CAMLlocal2(v_result, v_error);
  const char *err = NULL;
  const unsigned id = Int_val(v_id);

  UK_ASSERT(id >= 0);

  block_t *block = block_get(id, &err);
  if (!block) {
    v_result = alloc_result_error(err);
    CAMLreturn(v_result);
  }

  const int rc = block_configure(block, &err);
  if (rc) {
    v_result = alloc_result_error(err);
    CAMLreturn(v_result);
  }

  v_result = alloc_result_ok(Val_ptr(block));
  CAMLreturn(v_result);
}

value uk_block_info(value v_block) {
  CAMLparam1(v_block);
  CAMLlocal1(v_result);

  block_t *block = (block_t *)Ptr_val(v_block);
  const struct uk_blkdev_cap *cap = uk_blkdev_capabilities(block->dev);

  v_result = caml_alloc(3, 0);
  Store_field(v_result, 0, (cap->mode == O_RDONLY) ? Val_false : Val_true);
  // read_write
  Store_field(v_result, 1, Val_int(cap->ssize));           // sector size
  Store_field(v_result, 2, caml_copy_int64(cap->sectors)); // number of sectors
  CAMLreturn(v_result);
}

/* NOTE(dinosaure): we want to provide synchronous read/write on block devices.
 * Unikraft can provides them if CONFIG_LIBUKBLKDEV_SYNC_IO_BLOCKED_WAITING is
 * set which is not the case for [ocaml-unikraft]. We copied the code here to be
 * able to provide synchronous operations (and they are at the Unikraft level).
 */

struct uk_blkdev_sync_io_request {
  struct uk_blkreq req; /* Request structure */
  struct uk_semaphore
      s; /* Semaphore used for waiting after the response is done. */
};

static void __sync_io_callback(struct uk_blkreq *req __unused,
                               void *cookie_callback) {
  struct uk_blkdev_sync_io_request *sync_io_req;
  UK_ASSERT(cookie_callback);
  sync_io_req = (struct uk_blkdev_sync_io_request *)cookie_callback;
  uk_semaphore_up(&sync_io_req->s);
}

static int uk_blkdev_sync_io(struct uk_blkdev *dev, uint16_t queue_id,
                             enum uk_blkreq_op operation, __sector start_sector,
                             __sector nb_sectors, void *buf) {
  struct uk_blkreq *req;
  int rc = 0;
  struct uk_blkdev_sync_io_request sync_io_req;

  UK_ASSERT(dev != NULL);
  UK_ASSERT(queue_id < CONFIG_LIBUKBLKDEV_MAXNBQUEUES);
  UK_ASSERT(dev->_data);
  UK_ASSERT(dev->submit_one);
  UK_ASSERT(dev->_data->state == UK_BLKDEV_RUNNING);
  UK_ASSERT(dev->_queue[queue_id] && !PTRISERR(dev->_queue[queue_id]));

  req = &sync_io_req.req;
  uk_blkreq_init(req, operation, start_sector, nb_sectors, buf,
                 __sync_io_callback, (void *)&sync_io_req);
  uk_semaphore_init(&sync_io_req.s, 0);
  rc = uk_blkdev_queue_submit_one(dev, queue_id, req);
  if (unlikely(!uk_blkdev_status_successful(rc))) {
    uk_pr_err("blkdev%" PRIu16 "-q%" PRIu16 ": Failed to submit I/O req: %d\n",
              dev->_data->id, queue_id, rc);
    return rc;
  }

  uk_semaphore_down(&sync_io_req.s);
  return req->result;
}

value block_sync_io(block_t *block, int write, unsigned long sstart,
                    unsigned long size, char *buf) {
  int rc =
      uk_blkdev_sync_io(block->dev, 0, write ? UK_BLKREQ_WRITE : UK_BLKREQ_READ,
                        sstart, size, buf);
  if (rc < 0)
    return Val_false;
  return Val_true;
}

// -------------------------------------------------------------------------- //

static stoken_id_t block_async_read(block_t *block, unsigned long sstart,
                                    unsigned long size, char *buffer) {
  return block_async_io(block, 0, sstart, size, buffer);
}

value uk_block_async_read(value v_block, value v_sstart, value v_size,
                          value v_buffer, value v_offset) {
  CAMLparam5(v_block, v_sstart, v_size, v_buffer, v_offset);
  CAMLlocal1(v_result);

  block_t *block = (block_t *)Ptr_val(v_block);

  char *buf = (char *)Caml_ba_data_val(v_buffer) + Long_val(v_offset);
  unsigned long sstart = Int64_val(v_sstart);
  unsigned long size = Long_val(v_size);

  const stoken_id_t rc = block_async_read(block, sstart, size, (char *)buf);
  if (rc < 0) {
    v_result = alloc_result_error("uk_block_read: error");
    CAMLreturn(v_result);
  }
  token_id_t tokid = (token_id_t)rc;

  v_result = alloc_result_ok(Val_int(tokid));
  CAMLreturn(v_result);
}

static int block_read(block_t *block, unsigned long sstart, unsigned long size,
                      char *buffer) {
  return block_sync_io(block, 0, sstart, size, buffer);
}

value uk_block_read(value v_block, value v_sstart, value v_size, value v_buffer,
                    value v_offset) {
  CAMLparam5(v_block, v_sstart, v_size, v_buffer, v_offset);
  block_t *block = (block_t *)Ptr_val(v_block);
  char *buf = (char *)Caml_ba_data_val(v_buffer) + Long_val(v_offset);
  unsigned long sstart = Int64_val(v_sstart);
  unsigned long size = Long_val(v_size);

  const int rc = block_read(block, sstart, size, (char *)buf);
  CAMLreturn(Val_int(rc));
}

// -------------------------------------------------------------------------- //

static stoken_id_t block_async_write(block_t *block, unsigned long sstart,
                                     unsigned long size, char *buffer) {
  return block_async_io(block, 1, sstart, size, buffer);
}

value uk_block_async_write(value v_block, value v_sstart, value v_size,
                           value v_buffer, value v_offset) {
  CAMLparam5(v_block, v_sstart, v_size, v_buffer, v_offset);
  CAMLlocal1(v_result);

  block_t *block = (block_t *)Ptr_val(v_block);

  char *buf = (char *)Caml_ba_data_val(v_buffer) + Long_val(v_offset);
  unsigned long sstart = Int64_val(v_sstart);
  unsigned long size = Long_val(v_size);

  const stoken_id_t rc = block_async_write(block, sstart, size, buf);
  if (rc < 0) {
    v_result = alloc_result_error("uk_block_write: error");
    CAMLreturn(v_result);
  }
  token_id_t tokid = (token_id_t)rc;

  v_result = alloc_result_ok(Val_int(tokid));
  CAMLreturn(v_result);
}

static int block_write(block_t *block, unsigned long sstart, unsigned long size,
                       char *buffer) {
  return block_sync_io(block, 1, sstart, size, buffer);
}

value uk_block_write(value v_block, value v_sstart, value v_size,
                     value v_buffer, value v_offset) {
  CAMLparam5(v_block, v_sstart, v_size, v_buffer, v_offset);
  block_t *block = (block_t *)Ptr_val(v_block);
  char *buf = (char *)Caml_ba_data_val(v_buffer) + Long_val(v_offset);
  unsigned long sstart = Int64_val(v_sstart);
  unsigned long size = Long_val(v_size);

  const int rc = block_write(block, sstart, size, (char *)buf);
  CAMLreturn(Val_int(rc));
}

// -------------------------------------------------------------------------- //

value uk_complete_io(value v_block, value v_token_id) {
  CAMLparam2(v_block, v_token_id);
  CAMLlocal1(v_result);

  block_t *block = (block_t *)Ptr_val(v_block);
  token_id_t token_id = Int_val(v_token_id);
  token_t *token = &block->tokens[token_id];
  struct uk_blkreq *request = &token->req;

  assert(uk_blkreq_is_done(request));
  bool success = request->result >= 0;

  release_token(block, token);
  set_block_request_completed(block->id, token_id);

  if (success) {
    CAMLreturn(Val_true);
  }
  CAMLreturn(Val_false);
}

// -------------------------------------------------------------------------- //

value uk_max_tokens(void) {
  CAMLparam0();

  CAMLreturn(Val_int(MAX_BLK_TOKENS));
}

// -------------------------------------------------------------------------- //

value uk_max_sectors_per_req(value v_block) {
  CAMLparam1(v_block);
  CAMLlocal1(v_result);

  block_t *block = (block_t *)Ptr_val(v_block);
  int sectors = uk_blkdev_max_sec_per_req(block->dev);
  CAMLreturn(Val_int(sectors));
}

#endif /* __Unikraft__ */
