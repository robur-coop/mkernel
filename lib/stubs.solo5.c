#include "solo5.h"

#include <caml/memory.h>
#include <caml/bigarray.h>

extern void caml_enter_blocking_section(void);
extern void caml_leave_blocking_section(void);

intnat miou_solo5_block_read(solo5_handle_t handle, intnat off, intnat len,
                             value vbstr) {
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_read(handle, off, buf, size);
  return result;
}

intnat miou_solo5_block_write(solo5_handle_t handle, intnat off, intnat len,
                              value vbstr) {
  solo5_off_t offset = off;
  size_t size = len;
  solo5_result_t result;
  const uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr);
  result = solo5_block_write(handle, offset, buf, size);
  return result;
}

intnat miou_solo5_net_read(solo5_handle_t handle, intnat off, intnat len,
                           value vread_size, value vbstr) {
  CAMLparam1(vread_size);
  size_t size = len;
  size_t read_size;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = solo5_net_read(handle, buf, size, &read_size);
  memcpy(Bytes_val(vread_size), (uint64_t *)&read_size, sizeof(uint64_t));
  CAMLreturn(Val_long(result));
}

intnat miou_solo5_net_write(solo5_handle_t handle, intnat off, intnat len,
                            value vbstr) {
  size_t size = len;
  solo5_result_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = solo5_net_write(handle, buf, size);
  return result;
}
