#include <caml/bigarray.h>
#include <caml/memory.h>
#include <sys/ioctl.h>
#include <ifaddrs.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include <fcntl.h>
#include <errno.h>

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

#if defined(__linux__)
#include <linux/if.h>
#include <linux/if_tun.h>
#include <sys/socket.h>
#include <time.h>
#elif defined(__FreeBSD__)
#include <net/if.h>
#elif defined(__OpenBSD__)
#include <net/if.h>
#include <sys/socket.h>
#else
#error Unsupported system
#endif

intnat miou_solo5_net_connect(value vifname) {
  const char *ifname = String_val(vifname);
  struct ifaddrs *ifa, *ifp;
  int fd;
  int found;
  int up;

  if (getifaddrs(&ifa) == -1)
    return -1;
  ifp = ifa;
  while (ifp) {
    if (strncmp(ifp->ifa_name, ifname, IFNAMSIZ) == 0) {
      found = 1;
      up = ifp->ifa_flags & (IFF_UP | IFF_RUNNING);
      break;
    }
    ifp = ifp->ifa_next;
  }
  freeifaddrs(ifa);
  if (!found)
    return (-1);

#if defined(__linux__)

  if (!up)
    return (-2);

  struct ifreq ifr;
  fd = open("/dev/net/tun", O_RDWR | O_NONBLOCK);
  if (fd == -1)
    return (-3);

  memset(&ifr, 0, sizeof(ifr));
  ifr.ifr_flags = IFF_TAP | IFF_NO_PI;
  strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);

  if (ioctl(fd, TUNSETIFF, (void *)&ifr) == -1) {
    close(fd);
    return (-4);
  }

  if (strncmp(ifr.ifr_name, ifname, IFNAMSIZ) != 0) {
    close(fd);
    return (-5);
  }
#elif defined(__FreeBSD__)

  if (!up)
    ;

  char devname[strlen(ifname) + 6];
  snprintf(devname, sizeof devname, "/dev/%s", ifname);
  fd = open(devname, O_RDWR | O_NONBLOCK);
  if (fd == -1)
    return (-3);
#elif defined(__OpenBSD__)
  if (!up)
    return (-2);

  char devname[strlen(ifname) + 6];
  snprintf(devname, sizeof devname, "/dev/%s", ifname);
  fd = open(devname, O_RDWR | O_NONBLOCK);

  if (fd == -1)
    return (-3);
#endif

  return (fd);
}

value miou_solo5_net_read(intnat fd, value vbstr, intnat off, intnat len, value vread_size) {
  CAMLparam1(vread_size);
  ssize_t result = 0;
  size_t size = len;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = read(fd, buf, size);
  if ((result == 0) || (result == -1 && errno == EAGAIN)) {
    ssize_t tmp = 0;
    memcpy(Bytes_val(vread_size), (ssize_t *)&tmp, sizeof(ssize_t));
    result = 2;
  } else {
    memcpy(Bytes_val(vread_size), (uint64_t *)&result, sizeof(uint64_t));
    result = 0;
  }
  CAMLreturn(Val_long(result));
}

void miou_solo5_net_write(intnat fd, intnat off, intnat len, value vbstr) {
  size_t size = len;
  ssize_t result;
  uint8_t *buf = (uint8_t *)Caml_ba_data_val(vbstr) + off;
  result = write(fd, buf, size);
  assert (result == len);
}

intnat miou_solo5_clock_monotonic(__unit()) {
#if defined(__linux__)
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ((uint64_t) ts.tv_sec
          * (uint64_t) 1000000000LL
          + (uint64_t) ts.tv_nsec);
#else
  return 0;
#endif
}

intnat miou_solo5_clock_wall(__unit()) { return 0; }

#include <sys/select.h>
#include <caml/alloc.h>
#include <caml/misc.h>
#include <caml/fail.h>
#include <caml/callback.h>
#include <math.h>
#include <time.h>

#define Nothing ((value) 0)

static int fdlist_to_fdset(value fdlist, fd_set *fdset, int *maxfd)
{
  FD_ZERO(fdset);
  for (value l = fdlist; l != Val_emptylist; l = Field(l, 1)) {
    long fd = Long_val(Field(l, 0));
    if (fd < 0 || fd >= FD_SETSIZE) return -1;
    FD_SET((int) fd, fdset);
    if (fd > *maxfd) *maxfd = fd;
  }
  return 0;
}

static value fdset_to_fdlist(value fdlist, fd_set *fdset)
{
  CAMLparam0();
  CAMLlocal2(l, res);

  for (l = fdlist; l != Val_emptylist; l = Field(l, 1)) {
    int fd = Int_val(Field(l, 0));
    if (FD_ISSET(fd, fdset)) {
      value newres = caml_alloc_small(2, Tag_cons);
      Field(newres, 0) = Val_int(fd);
      Field(newres, 1) = res;
      res = newres;
    }
  }
  CAMLreturn(res);
}

#define USEC_PER_SEC         1000000UL

Caml_inline struct timeval caml_timeval_of_sec(double sec)
{
  double int_sec, frac_sec;
  frac_sec = modf(sec, &int_sec);
  return (struct timeval)
    { .tv_sec  = (time_t) int_sec,
      .tv_usec = (suseconds_t) (frac_sec * USEC_PER_SEC) };
}

void miou_solo5_error(int errcode, const char *cmdname, value cmdarg) {
  CAMLparam0();
  CAMLlocal2(name, arg);
  value res;
  const value *exn;
  exn = caml_named_value("Miou_solo5.Solo5_error");
  arg = cmdarg == Nothing ? caml_copy_string("") : cmdarg;
  name = caml_copy_string(cmdname);
  res = caml_alloc_small(4, 0);
  Field(res, 0) = *exn;
  Field(res, 1) = Val_int(errcode);
  Field(res, 2) = name;
  Field(res, 3) = arg;
  caml_raise(res);
  CAMLnoreturn;
}

CAMLprim value miou_solo5_select(value readfds, value timeout_sec)
{
  CAMLparam1(readfds);
  fd_set read;
  fd_set write;
  fd_set except;
  int maxfd;
  double tm_sec;
  struct timeval tv;
  struct timeval * tvp;
  int retcode;
  value res;

  FD_ZERO(&write);
  FD_ZERO(&except);
  maxfd = -1;
  retcode = fdlist_to_fdset(readfds, &read, &maxfd);
  if (retcode != 0) miou_solo5_error(0, "select", Nothing);
  tm_sec = Double_val(timeout_sec);
  if (tm_sec < 0.0) {
    tvp = (struct timeval *) NULL;
  } else {
    tv = caml_timeval_of_sec(tm_sec);
    tvp = &tv;
  }
  caml_enter_blocking_section();
  retcode = select(maxfd + 1, &read, &write, &except, tvp);
  caml_leave_blocking_section();
  if (retcode == -1) miou_solo5_error(0, "select", Nothing);
  readfds = fdset_to_fdlist(readfds, &read);
  CAMLreturn(readfds);
}
