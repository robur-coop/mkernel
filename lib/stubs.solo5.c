#include "solo5.h"

#include <caml/memory.h>
#include <caml/bigarray.h>

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

intnat miou_solo5_block_read(intnat fd, intnat off, intnat len,
                             value vbstr) {
  solo5_handle_t handle = fd;
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_read(handle, off, buf, size);
  return result;
}

intnat miou_solo5_block_write(intnat fd, intnat off, intnat len,
                              value vbstr) {
  solo5_handle_t handle = fd;
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  const uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_write(handle, offset, buf, size);
  return result;
}

/* Instead of passing the [read_size] result in data that would be allocated on
 * the C side, the OCaml side allocates a small buffer of 8 bytes to store the
 * number of bytes that Solo5 was able to read. memcpy saves our result in this
 * small buffer and, on the OCaml side, we just need to read it. It's a bit
 * like the poor man's C-style reference passage in OCaml. */

intnat miou_solo5_net_read(intnat fd, intnat off, intnat len,
                           value vread_size, value vbstr) {
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

intnat miou_solo5_net_write(intnat fd, intnat off, intnat len,
                            value vbstr) {
  solo5_handle_t handle = fd;
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = solo5_net_write(handle, buf, size);
  return result;
}
