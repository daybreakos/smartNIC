# -----------------------------------------------------------------------
# Makefile for the AF_XDP ICMP-redirect example
#
# Produces:
#   xdp_afxdp_icmp_kern.o   - eBPF object, loaded by the userspace prog
#   afxdp_icmp_user         - userspace loader/loop
#
# Requires: clang, llvm, libbpf headers+lib (libbpf-dev / libbpf.a),
# and a vmlinux.h if your kernel headers don't already provide the BPF
# map-definition macros used in the kernel .c file's includes.
# -----------------------------------------------------------------------

CLANG     ?= clang
CC        ?= gcc
ARCH      := $(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/')

# Adjust if libbpf/libxdp are installed elsewhere. On Fedora (and most
# distros with -devel/-dev packages), pkg-config knows the right
# include paths and link flags, so we prefer it over hardcoding them.
#
# NOTE: as of libbpf 1.0+, the AF_XDP socket API (xsk.h) lives in the
# separate libxdp library, not in libbpf itself. We link both.
PKG_CFLAGS := $(shell pkg-config --cflags libbpf libxdp 2>/dev/null)
PKG_LIBS   := $(shell pkg-config --libs libbpf libxdp 2>/dev/null)

# Fallback if pkg-config .pc files aren't found for some reason.
ifeq ($(strip $(PKG_LIBS)),)
PKG_CFLAGS := -I/usr/include
PKG_LIBS   := -lbpf -lxdp
endif

CFLAGS    := -g -O2 -Wall $(PKG_CFLAGS)
BPF_CFLAGS:= -g -O2 -target bpf -D__TARGET_ARCH_$(ARCH) $(PKG_CFLAGS)

KERN_SRC  := xdp_afxdp_icmp_kern.c
KERN_OBJ  := xdp_afxdp_icmp_kern.o

USER_SRC  := afxdp_icmp_user.c
USER_BIN  := afxdp_icmp_user

.PHONY: all clean

all: $(KERN_OBJ) $(USER_BIN)

$(KERN_OBJ): $(KERN_SRC)
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@

$(USER_BIN): $(USER_SRC)
	$(CC) $(CFLAGS) $< -o $@ $(PKG_LIBS)

clean:
	rm -f $(KERN_OBJ) $(USER_BIN)
