#include "solo5.h"

#include <caml/bigarray.h>
#include <caml/callback.h>
#include <caml/memory.h>
#include <string.h>

/* We currently have no need for these functions. They consist of releasing the
 * GC lock when we do operations with Solo5 with bigstrings, because of the
 * quality of bigstrings, we can execute these operations after informing OCaml
 * that it can do the work it wants on the GC in parallel. However, we don't
 * have parallelism with Solo5. This comment is to explain why we don't use
 * them when we could. */
extern void caml_enter_blocking_section(void);
extern void caml_leave_blocking_section(void);

/* Note between solo5_handle_t and intnat. Currently, solo5_handle_t is an
 * integer 64, but Solo5 cannot manage more than 64 devices at the same time.
 * More practically, it would be difficult to make a unikernel that needed 64
 * or even 63 different devices. We can afford to lose one bit for both
 * solo5_handle_t (which represents our file-descriptors) and
 * solo5_handle_set_t, which can only contain file-descriptors with a value
 * between 0 and 63. */

value miou_solo5_block_acquire(value vname, value vhandle, value vlen,
                               value vpage) {
  CAMLparam4(vname, vhandle, vlen, vpage);
  solo5_result_t result;
  solo5_handle_t handle;
  struct solo5_block_info bi;

  result = solo5_block_acquire(String_val(vname), &handle, &bi);

  if (result == SOLO5_R_OK) {
    memcpy(Bytes_val(vhandle), (uint64_t *)&handle, sizeof(uint64_t));
    memcpy(Bytes_val(vlen), (uint64_t *)&bi.capacity, sizeof(uint64_t));
    memcpy(Bytes_val(vpage), (uint64_t *)&bi.block_size, sizeof(uint64_t));
  }

  CAMLreturn(Val_long(result));
}

intnat miou_solo5_block_read(intnat fd, intnat off, intnat len, value vbstr) {
  solo5_handle_t handle = fd;
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_read(handle, off, buf, size);
  return result;
}

intnat miou_solo5_block_write(intnat fd, intnat off, intnat len, value vbstr) {
  solo5_handle_t handle = fd;
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  const uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_write(handle, offset, buf, size);
  return result;
}

value miou_solo5_net_acquire(value vname, value vhandle, value vmac,
                             value vmtu) {
  CAMLparam3(vname, vmac, vmtu);
  solo5_result_t result;
  solo5_handle_t handle;
  struct solo5_net_info ni;

  result = solo5_net_acquire(String_val(vname), &handle, &ni);

  if (result == SOLO5_R_OK) {
    memcpy(Bytes_val(vhandle), (uint64_t *)&handle, sizeof(uint64_t));
    memcpy(Bytes_val(vmac), ni.mac_address, SOLO5_NET_ALEN);
    memcpy(Bytes_val(vmtu), (uint64_t *)&ni.mtu, sizeof(uint64_t));
  }

  CAMLreturn(Val_long(result));
}

/* Instead of passing the [read_size] result in data that would be allocated on
 * the C side, the OCaml side allocates a small buffer of 8 bytes to store the
 * number of bytes that Solo5 was able to read. memcpy saves our result in this
 * small buffer and, on the OCaml side, we just need to read it. It's a bit
 * like the poor man's C-style reference passage in OCaml. */

value miou_solo5_net_read(intnat fd, value vbstr, intnat off, intnat len, value vread_size) {
  CAMLparam1(vread_size);
  solo5_handle_t handle = fd;
  size_t size = len;
  size_t read_size;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = solo5_net_read(handle, buf, size, &read_size);
  memcpy(Bytes_val(vread_size), (uint64_t *)&read_size, sizeof(uint64_t));
  CAMLreturn(Val_long(result));
}

intnat miou_solo5_net_write(intnat fd, intnat off, intnat len, value vbstr) {
  solo5_handle_t handle = fd;
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = solo5_net_write(handle, buf, size);
  return result;
}

intnat miou_solo5_yield(intnat ts) {
  solo5_time_t deadline = ts;
  solo5_handle_set_t handles;
  solo5_yield(deadline, &handles);
  return handles;
}

#ifndef __unused
#if defined(_MSC_VER) && _MSC_VER >= 1500
#define __unused(x)                                                            \
  __pragma(warning(push)) __pragma(warning(disable : 4189)) x __pragma(        \
      warning(pop))
#else
#define __unused(x) x __attribute__((unused))
#endif
#endif
#define __unit() value __unused(unit)

intnat miou_solo5_clock_monotonic(__unit()) {
  return (solo5_clock_monotonic());
}

intnat miou_solo5_clock_wall(__unit()) { return (solo5_clock_wall()); }

extern void _nolibc_init(uintptr_t, size_t);
static char *unused_argv[] = {"uniker.ml", NULL};
static const char *cmdline = "";

static char *strdup(const char *s) {
  size_t l = strlen(s);
  char *d = malloc(l + 1);
  if (!d)
    return NULL;
  return memcpy(d, s, l + 1);
}

static char *split(const char *s, char *dst[], size_t len) {
  int i = 0;
  char *rem = strdup(s);
  char *str = rem;

  while (rem != NULL && *rem != '\0' && i < len) {
    char *e = strstr(rem, " ");
    dst[i++] = rem;
    if (e != NULL) {
      *e = '\0';
      while (*(++e) == ' ')
        ;
    }
    rem = e;
  }

  return str;
}

int solo5_app_main(const struct solo5_start_info *si) {
  char *cmdline[64] = {NULL};
  cmdline[0] = "uniker.ml";

  _nolibc_init(si->heap_start, si->heap_size);
  char *tmp = split(si->cmdline, cmdline + 1, 62);
  caml_startup(cmdline);
  free(tmp);

  return (0);
}
