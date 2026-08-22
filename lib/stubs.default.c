#include <caml/memory.h>
#include <caml/alloc.h>

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

intnat miou_solo5_clock_monotonic(__unit()) { return 0; }

CAMLprim value
caml_get_monotonic_time(value v_unit)
{
  CAMLparam1(v_unit);
  CAMLreturn(caml_copy_int64(0));
}

intnat miou_solo5_clock_wall(__unit()) { return 0; }
