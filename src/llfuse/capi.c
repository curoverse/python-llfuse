/*
capi.c

Copyright © 2013 Nikolaus Rath <Nikolaus.org>

This file is part of Python-LLFUSE. This work may be distributed under
the terms of the GNU LGPL.
*/

#include <fuse.h>

#if FUSE_VERSION < 28
#error FUSE version too old, 2.8.0 or newer required
#endif

#if FUSE_MAJOR_VERSION != 2
#error This version of the FUSE library is not yet supported.
#endif

#ifdef __gnu_linux__
#include "capi_linux.c"
#elif __FreeBSD__
#include "capi_freebsd.c"
#elif __NetBSD__
#include "capi_freebsd.c"
#elif __APPLE__ && __MACH__
#include "capi_darwin.c"
#else
#error "Unable to determine system (Linux/FreeBSD/Darwin)"
#endif
