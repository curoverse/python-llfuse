'''
misc.pxi

This file defines various functions that are used internally by
LLFUSE. It is included by llfuse.pyx.

Copyright © 2013 Nikolaus Rath <Nikolaus.org>

This file is part of Python-LLFUSE. This work may be distributed under
the terms of the GNU LGPL.
'''

cdef object fill_entry_param(object attr, fuse_entry_param* entry):
    entry.ino = attr.st_ino
    entry.generation = attr.generation
    entry.entry_timeout = attr.entry_timeout
    entry.attr_timeout = attr.attr_timeout

    fill_c_stat(attr, &entry.attr)

cdef object fill_c_stat(object attr, struct_stat* stat):

    # Under OS-X, struct_stat has an additional st_flags field. The memset
    # below sets this to zero without the need for an explicit
    # platform check (although, admittedly, this explanatory comment
    # make take even more space than the check would have taken).
    string.memset(stat, 0, sizeof(struct_stat))

    stat.st_ino = attr.st_ino
    stat.st_mode = attr.st_mode
    stat.st_nlink = attr.st_nlink
    stat.st_uid = attr.st_uid
    stat.st_gid = attr.st_gid
    stat.st_rdev = attr.st_rdev
    stat.st_size = attr.st_size
    stat.st_blksize = attr.st_blksize
    stat.st_blocks = attr.st_blocks

    if attr.st_atime_ns is not None:
        stat.st_atime = attr.st_atime_ns / 10**9
        SET_ATIME_NS(stat, attr.st_atime_ns % 10**9)
    else:
        stat.st_atime = attr.st_atime
        SET_ATIME_NS(stat, (attr.st_atime - stat.st_atime) * 1e9)

    if attr.st_ctime_ns is not None:
        stat.st_ctime = attr.st_ctime_ns / 10**9
        SET_CTIME_NS(stat, attr.st_ctime_ns % 10**9)
    else:
        stat.st_ctime = attr.st_ctime
        SET_CTIME_NS(stat, (attr.st_ctime - stat.st_ctime) * 1e9)

    if attr.st_mtime_ns is not None:
        stat.st_mtime = attr.st_mtime_ns / 10**9
        SET_MTIME_NS(stat, attr.st_mtime_ns % 10**9)
    else:
        stat.st_mtime = attr.st_mtime
        SET_MTIME_NS(stat, (attr.st_mtime - stat.st_mtime) * 1e9)


cdef object fill_statvfs(object attr, statvfs* stat):
    stat.f_bsize = attr.f_bsize
    stat.f_frsize = attr.f_frsize
    stat.f_blocks = attr.f_blocks
    stat.f_bfree = attr.f_bfree
    stat.f_bavail = attr.f_bavail
    stat.f_files = attr.f_files
    stat.f_ffree = attr.f_ffree
    stat.f_favail = attr.f_favail


cdef int handle_exc(fuse_req_t req):
    '''Try to call fuse_reply_err and terminate main loop'''

    global exc_info

    if not exc_info:
        exc_info = sys.exc_info()
        log.debug('handler raised exception, sending SIGTERM to self.')
        kill(getpid(), SIGTERM)
    else:
        log.exception('Exception after kill:')

    if req is NULL:
        return 0
    else:
        return fuse_reply_err(req, errno.EIO)

cdef object get_request_context(fuse_req_t req):
    '''Get RequestContext() object'''

    cdef const_fuse_ctx* context

    context = fuse_req_ctx(req)
    ctx = RequestContext()
    ctx.pid = context.pid
    ctx.uid = context.uid
    ctx.gid = context.gid
    ctx.umask = context.umask

    return ctx

cdef void init_fuse_ops():
    '''Initialize fuse_lowlevel_ops structure'''

    string.memset(&fuse_ops, 0, sizeof(fuse_lowlevel_ops))

    fuse_ops.init = fuse_init
    fuse_ops.destroy = fuse_destroy
    fuse_ops.lookup = fuse_lookup
    fuse_ops.forget = fuse_forget
    fuse_ops.getattr = fuse_getattr
    fuse_ops.setattr = fuse_setattr
    fuse_ops.readlink = fuse_readlink
    fuse_ops.mknod = fuse_mknod
    fuse_ops.mkdir = fuse_mkdir
    fuse_ops.unlink = fuse_unlink
    fuse_ops.rmdir = fuse_rmdir
    fuse_ops.symlink = fuse_symlink
    fuse_ops.rename = fuse_rename
    fuse_ops.link = fuse_link
    fuse_ops.open = fuse_open
    fuse_ops.read = fuse_read
    fuse_ops.write = fuse_write
    fuse_ops.flush = fuse_flush
    fuse_ops.release = fuse_release
    fuse_ops.fsync = fuse_fsync
    fuse_ops.opendir = fuse_opendir
    fuse_ops.readdir = fuse_readdir
    fuse_ops.releasedir = fuse_releasedir
    fuse_ops.fsyncdir = fuse_fsyncdir
    fuse_ops.statfs = fuse_statfs
    IF TARGET_PLATFORM == 'darwin':
        fuse_ops.setxattr = fuse_setxattr_darwin
        fuse_ops.getxattr = fuse_getxattr_darwin
    ELSE:
        fuse_ops.setxattr = fuse_setxattr
        fuse_ops.getxattr = fuse_getxattr
    fuse_ops.listxattr = fuse_listxattr
    fuse_ops.removexattr = fuse_removexattr
    fuse_ops.access = fuse_access
    fuse_ops.create = fuse_create

    FUSE29_ASSIGN(fuse_ops.forget_multi, &fuse_forget_multi)

cdef make_fuse_args(args, fuse_args* f_args):
    cdef char* arg
    cdef int i
    cdef ssize_t size

    args_new = [ b'Python-LLFUSE' ]
    for el in args:
        args_new.append(b'-o')
        args_new.append(el.encode('us-ascii'))
    args = args_new

    f_args.argc = <int> len(args)
    if f_args.argc == 0:
        f_args.argv = NULL
        return

    f_args.allocated = 1
    f_args.argv = <char**> stdlib.calloc(f_args.argc, sizeof(char*))

    if f_args.argv is NULL:
        cpython.exc.PyErr_NoMemory()

    try:
        for (i, el) in enumerate(args):
            PyBytes_AsStringAndSize(el, &arg, &size)
            f_args.argv[i] = <char*> stdlib.malloc((size+1)*sizeof(char))

            if f_args.argv[i] is NULL:
                cpython.exc.PyErr_NoMemory()

            string.strncpy(f_args.argv[i], arg, size+1)
    except:
        for i in range(f_args.argc):
            # Freeing a NULL pointer (if this element has not been allocated
            # yet) is fine.
            stdlib.free(f_args.argv[i])
        stdlib.free(f_args.argv)
        raise

cdef class Lock:
    '''
    This is the class of lock itself as well as a context manager to
    execute code while the global lock is being held.
    '''

    def __init__(self):
        raise TypeError('You should not instantiate this class, use the '
                        'provided instance instead.')

    def acquire(self, timeout=None):
        '''Acquire global lock

        If *timeout* is not None, and the lock could not be acquired
        after waiting for *timeout* seconds, return False. Otherwise
        return True.
        '''

        cdef int ret
        cdef int timeout_c

        if timeout is None:
            timeout_c = 0
        else:
            timeout_c = timeout

        with nogil:
            ret = acquire(timeout_c)

        if ret == 0:
            return True
        elif ret == ETIMEDOUT and timeout != 0:
            return False
        elif ret == EDEADLK:
            raise RuntimeError("Global lock cannot be acquired more than once")
        elif ret == EPROTO:
            raise RuntimeError("Lock still taken after receiving unlock notification")
        elif ret == EINVAL:
            raise RuntimeError("Lock not initialized")
        else:
            raise RuntimeError(strerror(ret))

    def release(self):
        '''Release global lock'''

        cdef int ret
        with nogil:
            ret = release()

        if ret == 0:
             return
        elif ret == EPERM:
            raise RuntimeError("Lock can only be released by the holding thread")
        elif ret == EINVAL:
            raise RuntimeError("Lock not initialized")
        else:
            raise RuntimeError(strerror(ret))

    def yield_(self, count=1):
        '''Yield global lock to a different thread

        The *count* argument may be used to yield the lock up to
        *count* times if there are still other threads waiting for the
        lock.
        '''

        cdef int ret
        cdef int count_c

        count_c = count
        with nogil:
            ret = c_yield(count_c)

        if ret == 0:
            return
        elif ret == EPERM:
            raise RuntimeError("Lock can only be released by the holding thread")
        elif ret == EPROTO:
            raise RuntimeError("Lock still taken after receiving unlock notification")
        elif ret == ENOMSG:
            raise RuntimeError("Other thread didn't take lock")
        elif ret == EINVAL:
            raise RuntimeError("Lock not initialized")
        else:
            raise RuntimeError(strerror(ret))

    def __enter__(self):
        self.acquire()

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.release()


cdef class NoLockManager:
    '''Context manager to execute code while the global lock is released'''

    def __init__(self):
        raise TypeError('You should not instantiate this class, use the '
                        'provided instance instead.')

    def __enter__ (self):
        lock.release()

    def __exit__(self, *a):
        lock.acquire()

def _notify_loop():
    '''Read notifications from queue and send to FUSE kernel module'''

    cdef ssize_t len_
    cdef fuse_ino_t ino
    cdef char *cname

    while True:
        req = _notify_queue.get()
        if req is None:
            return

        if isinstance(req, inval_inode_req):
            ino = req.inode
            if req.attr_only:
                with nogil:
                    fuse_lowlevel_notify_inval_inode(channel, ino, -1, 0)
            else:
                with nogil:
                    fuse_lowlevel_notify_inval_inode(channel, ino, 0, 0)
        elif isinstance(req, inval_entry_req):
            PyBytes_AsStringAndSize(req.name, &cname, &len_)
            ino = req.inode_p
            with nogil:
                fuse_lowlevel_notify_inval_entry(channel, ino, cname, len_)
        else:
            raise RuntimeError("Weird request received: %r", req)

cdef str2bytes(s):
    '''Convert *s* to bytes

    Under Python 2.x, just returns *s*. Under Python 3.x, converts
    to file system encoding using surrogateescape.
    '''

    if PY_MAJOR_VERSION < 3:
        return s
    else:
        return s.encode(fse, 'surrogateescape')

cdef bytes2str(s):
    '''Convert *s* to str

    Under Python 2.x, just returns *s*. Under Python 3.x, converts
    from file system encoding using surrogateescape.
    '''

    if PY_MAJOR_VERSION < 3:
        return s
    else:
        return s.decode(fse, 'surrogateescape')

cdef strerror(int errno):
    try:
        return os.strerror(errno)
    except ValueError:
        return 'errno: %d' % errno

class RequestContext:
    '''
    Instances of this class are passed to some `Operations` methods to
    provide information about the caller of the syscall that initiated
    the request.
    '''

    __slots__ = [ 'uid', 'pid', 'gid', 'umask' ]

    def __init__(self):
        for name in self.__slots__:
            setattr(self, name, None)

class EntryAttributes:
    '''
    Instances of this class store attributes of directory entries.
    Most of the attributes correspond to the elements of the ``stat``
    C struct as returned by e.g. ``fstat`` and should be
    self-explanatory.

    The access, modification and creation times may be specified
    either in nanoseconds (via the *st_Xtime_ns* attributes) or in
    seconds (via the *st_Xtime* attributes). When times are specified
    both in seconds and nanoseconds, the nanosecond representation
    takes precedence. If times are represented in seconds, floating
    point numbers may be used to achieve sub-second
    resolution. Nanosecond time stamps must be integers. Note that
    using integer nanoseconds is more accurately than using float
    seconds.

    Request handlers do not need to return objects that inherit from
    `EntryAttributes` directly as long as they provide the required
    attributes.
    '''

    # Attributes are documented in rst/data.rst

    __slots__ = [ 'st_ino', 'generation', 'entry_timeout',
                  'attr_timeout', 'st_mode', 'st_nlink', 'st_uid', 'st_gid',
                  'st_rdev', 'st_size', 'st_blksize', 'st_blocks',
                  'st_atime', 'st_atime_ns', 'st_mtime', 'st_mtime_ns',
                  'st_ctime', 'st_ctime_ns' ]

    def __init__(self):
        self.st_ino = None
        self.generation = 0
        self.entry_timeout = 300
        self.attr_timeout = 300
        self.st_mode = S_IFREG
        self.st_nlink = 1
        self.st_uid = 0
        self.st_gid = 0
        self.st_rdev = 0
        self.st_size = 0
        self.st_blksize = 4096
        self.st_blocks = 0
        self.st_atime = 0
        self.st_mtime = 0
        self.st_ctime = 0
        self.st_atime_ns = None
        self.st_mtime_ns = None
        self.st_ctime_ns = None

class StatvfsData:
    '''
    Instances of this class store information about the file system.
    The attributes correspond to the elements of the ``statvfs``
    struct, see :manpage:`statvfs(2)` for details.

    Request handlers do not need to return objects that inherit from
    `StatvfsData` directly as long as they provide the required
    attributes.
    '''

    # Attributes are documented in rst/operations.rst

    __slots__ = [ 'f_bsize', 'f_frsize', 'f_blocks', 'f_bfree',
                  'f_bavail', 'f_files', 'f_ffree', 'f_favail' ]

    def __init__(self):
        for name in self.__slots__:
            setattr(self, name, None)

class FUSEError(Exception):
    '''
    This exception may be raised by request handlers to indicate that
    the requested operation could not be carried out. The system call
    that resulted in the request (if any) will then fail with error
    code *errno_*.
    '''

    __slots__ = [ 'errno' ]

    def __init__(self, errno_):
        super(FUSEError, self).__init__()
        self.errno = errno_

    def __str__(self):
        return strerror(self.errno)
