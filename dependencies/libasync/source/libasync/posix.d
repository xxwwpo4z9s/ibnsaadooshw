module libasync.posix;

version (Posix)  : import libasync.types;
import std.string : toStringz;
import std.conv : to;
import std.datetime : Duration, msecs, seconds, SysTime;
import std.traits : isIntegral;
import std.typecons : Tuple, tuple;
import std.container : Array;
import std.exception;

import core.stdc.errno;
import libasync.events;
import libasync.internals.path;
import core.sys.posix.signal;
import libasync.posix2;
import libasync.internals.logging;
import core.sync.mutex;
import memutils.utils;
import memutils.hashmap;

alias fd_t = int;

version (linux)
{
    import libasync.internals.epoll;

    const EPOLL = true;
    extern (C) nothrow @nogc
    {
        int __libc_current_sigrtmin();
        int __libc_current_sigrtmax();
    }
    bool g_signalsBlocked;
    package nothrow void blockSignals()
    {
        try
        {
            /// Block signals to reserve SIGRTMIN .. " +30 for AsyncSignal
            sigset_t mask;
            // todo: use more signals for more event loops per thread.. (is this necessary?)
            //foreach (j; __libc_current_sigrtmin() .. __libc_current_sigrtmax() + 1) {
            //import std.stdio : writeln;
            //try writeln("Blocked signal " ~ (__libc_current_sigrtmin() + j).to!string ~ " in instance " ~ m_instanceId.to!string); catch {}
            sigemptyset( & mask);
            sigaddset( & mask, cast(int) __libc_current_sigrtmin());
            pthread_sigmask(SIG_BLOCK,  & mask, null);
            //}
        }
        catch (Throwable)
        {
        }
    }
    static this()
    {
        blockSignals();
        g_signalsBlocked = true;
    }
}
version (OSX)
{
    import libasync.internals.kqueue;

    const EPOLL = false;
}
version (FreeBSD)
{
    import libasync.internals.kqueue;

    const EPOLL = false;
}

__gshared Mutex g_mutex;

static if (!EPOLL)
{
    private struct DWFileInfo
    {
        fd_t folder;
        Path path;
        SysTime lastModified;
        bool is_dir;
    }
}

private struct DWFolderInfo
{
    WatchInfo wi;
    fd_t fd;
}

package struct EventLoopImpl
{
    static if (EPOLL)
    {
        pragma(msg, "Using Linux EPOLL for events");
    }
    else /* if KQUEUE */
    {
        pragma(msg, "Using FreeBSD KQueue for events");
    }

    package : alias error_t = EPosix;

    nothrow : private : /// members
    EventLoop m_evLoop;
    ushort m_instanceId;
    bool m_started;
    StatusInfo m_status;
    error_t m_error = EPosix.EOK;
    EventInfo * m_evSignal;
    static if (EPOLL)
    {
        fd_t m_epollfd;
        HashMap!(Tuple!(fd_t, uint), DWFolderInfo) m_dwFolders; // uint = inotify_add_watch(Path)
    }
    else /* if KQUEUE */
    {
        fd_t m_kqueuefd;
        HashMap!(fd_t, EventInfo * ) m_watchers; // fd_t = id++ per AsyncDirectoryWatcher
        HashMap!(fd_t, DWFolderInfo) m_dwFolders; // fd_t = open(folder)
        HashMap!(fd_t, DWFileInfo) m_dwFiles; // fd_t = open(file)
        HashMap!(fd_t, Array!(DWChangeInfo) * ) m_changes; // fd_t = id++ per AsyncDirectoryWatcher

    }

    AsyncAcceptRequest.Queue m_completedSocketAccepts;
    AsyncReceiveRequest.Queue m_completedSocketReceives;
    AsyncSendRequest.Queue m_completedSocketSends;

    package : /// workaround for IDE indent bug on too big files
    mixin RunKill!();

    @property bool started() const
    {
        return m_started;
    }

    bool init(EventLoop evl) in 
    {
        assert(!m_started);
    }
    body
    {

        import core.atomic;

        shared static ushort i;
        string * failer = null;

        m_instanceId = i;
        static if (!EPOLL)
            g_threadId = new size_t(cast(size_t) m_instanceId);

        core.atomic.atomicOp!"+="(i, cast(ushort) 1);
        m_evLoop = evl;

        import core.thread;

        try
            Thread.getThis().priority = Thread.PRIORITY_MAX;
        catch (Exception e)
        {
            assert(false, "Could not set thread priority");
        }

        try
            if (!g_mutex)
                g_mutex = new Mutex;
        catch (Throwable)
        {
        }

        static if (EPOLL)
        {

            if (!g_signalsBlocked)
                blockSignals();
            assert(m_instanceId <= __libc_current_sigrtmax(),
                    "An additional event loop is unsupported due to SIGRTMAX restrictions in Linux Kernel");
            m_epollfd = epoll_create1(EPOLL_CLOEXEC);

            if (catchError!"epoll_create1"(m_epollfd))
                return false;

            import core.sys.linux.sys.signalfd;
            import core.thread : getpid;

            fd_t err;
            fd_t sfd;

            sigset_t mask;

            try
            {
                sigemptyset( & mask);
                sigaddset( & mask, __libc_current_sigrtmin());
                err = pthread_sigmask(SIG_BLOCK,  & mask, null);
                if (catchError!"sigprocmask"(err))
                {
                    m_status.code = Status.EVLOOP_FAILURE;
                    return false;
                }
            }
            catch (Throwable)
            {
            }

            sfd = signalfd( - 1,  & mask, SFD_NONBLOCK);
            assert(sfd > 0, "Failed to setup signalfd in epoll");

            EventType evtype;

            epoll_event _event;
            _event.events = EPOLLIN;
            evtype = EventType.Signal;
            try
                m_evSignal = ThreadMem.alloc!EventInfo(sfd, evtype,
                        EventObject.init, m_instanceId);
            catch (Exception e)
            {
                assert(false, "Allocation error");
            }
            _event.data.ptr = cast(void * ) m_evSignal;

            err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, sfd,  & _event);
            if (catchError!"EPOLL_CTL_ADD(sfd)"(err))
            {
                return false;
            }

        }
        else /* if KQUEUE */
        {
            try
            {
                if (!gs_queueMutex)
                {
                    gs_queueMutex = ThreadMem.alloc!ReadWriteMutex();
                    gs_signalQueue = Array!(Array!AsyncSignal)();
                    gs_idxQueue = Array!(Array!size_t)();
                }
                if (g_evIdxAvailable.empty)
                {
                    g_evIdxAvailable.reserve(32);

                    foreach (k; g_evIdxAvailable.length .. g_evIdxAvailable.capacity)
                    {
                        g_evIdxAvailable.insertBack(k + 1);
                    }
                    g_evIdxCapacity = 32;
                    g_idxCapacity = 32;
                }
            }
            catch (Throwable)
            {
                assert(false, "Initialization failed");
            }
            m_kqueuefd = kqueue();
            int err;
            try
            {
                sigset_t mask;
                sigemptyset( & mask);
                sigaddset( & mask, SIGXCPU);

                err = sigprocmask(SIG_BLOCK,  & mask, null);
            }
            catch (Throwable)
            {
            }

            EventType evtype = EventType.Signal;

            // use GC because ThreadMem fails at emplace for shared objects
            try
                m_evSignal = ThreadMem.alloc!EventInfo(SIGXCPU, evtype,
                        EventObject.init, m_instanceId);
            catch (Exception e)
            {
                assert(false, "Failed to allocate resources");
            }

            if (catchError!"siprocmask"(err))
                return 0;

            kevent_t _event;
            EV_SET( & _event, SIGXCPU, EVFILT_SIGNAL, EV_ADD | EV_ENABLE, 0, 0, m_evSignal);
            err = kevent(m_kqueuefd,  & _event, 1, null, 0, null);
            if (catchError!"kevent_add(SIGXCPU)"(err))
                assert(false, "Add SIGXCPU failed at kevent call");
        }

        static if (LOG)
            try
                log("init in thread " ~ Thread.getThis().name);
        catch (Throwable)
        {
        }

        return true;
    }

    void exit()
    {
        import core.sys.posix.unistd : close;

        static if (EPOLL)
        {
            close(m_epollfd); // not necessary?

            // not necessary:
            //try ThreadMem.free(m_evSignal);
            //catch (Exception e) { assert(false, "Failed to free resources"); }

        }
        else
            close(m_kqueuefd);
    }

    @property const(StatusInfo) status() const
    {
        return m_status;
    }

    @property string error() const
    {
        string * ptr;
        return ((ptr = (m_error in EPosixMessages)) !is null) ?  * ptr : string.init;
    }

    bool loop(Duration timeout = 0.seconds) //in { assert(Fiber.getThis() is null); }
    {
        import libasync.internals.memory;

        int num = void;

        static if (EPOLL)
        {
            static align(1) epoll_event[] events;
            if (events is null)
            {
                try
                    events = new epoll_event[128];
                catch (Exception e)
                {
                    assert(false, "Could not allocate events array: " ~ e.msg);
                }
            }
        }
        else /* if KQUEUE */
        {
            import core.sys.posix.time : time_t;
            import core.sys.posix.config : c_long;

            static kevent_t[] events;
            if (events.length == 0)
            {
                try
                    events = allocArray!kevent_t(manualAllocator(), 128);
                catch (Exception e)
                {
                    assert(false, "Could not allocate events array");
                }
            }
        }

        auto waitForEvents(Duration timeout)
        {
            static if (EPOLL)
            {
                int timeout_ms;
                if (timeout == 0.seconds) // return immediately
                    timeout_ms = 0;
                else if (timeout ==  - 1.seconds) // wait indefinitely
                    timeout_ms =  - 1;
                else
                    timeout_ms = cast(int) timeout.total!"msecs";
                /// Retrieve pending events
                scope (exit)
                    assert(events !is null && events.length <= 128);
                return epoll_wait(m_epollfd, cast(epoll_event * ) & events[0], 128, timeout_ms);
            }
            else /* if KQUEUE */
            {
                if (timeout !=  - 1.seconds)
                {
                    time_t secs = timeout.split!("seconds", "nsecs")().seconds;
                    c_long ns = timeout.split!("seconds", "nsecs")().nsecs;
                    auto tspec = libasync.internals.kqueue.timespec(secs, ns);

                    return kevent(m_kqueuefd, null, 0, cast(kevent_t * ) events,
                            cast(int) events.length,  & tspec);
                }
                else
                {
                    return kevent(m_kqueuefd, null, 0, cast(kevent_t * ) events,
                            cast(int) events.length, null);
                }
            }
        }

        auto handleEvents()
        {
            bool success = true;

            static Tuple!(int, Status)[] errors = [tuple(EINTR, Status.EVLOOP_TIMEOUT)];

            if (catchEvLoopErrors!"event_poll'ing"(num, errors))
                return false;

            if (num > 0)
                static if (LOG)
                    log("Got " ~ num.to!string ~ " event(s)");

            foreach (i; 0 .. num)
            {
                success = false;
                m_status = StatusInfo.init;
                static if (EPOLL)
                {
                    epoll_event _event = events[i];
                    static if (LOG)
                        try
                            log("Event " ~ i.to!string ~ " of: " ~ events.length.to!string);
                    catch
                    {
                    }
                    EventInfo * info = cast(EventInfo * ) _event.data.ptr;
                    int event_flags = cast(int) _event.events;
                }
                else /* if KQUEUE */
                {
                    kevent_t _event = events[i];
                    EventInfo * info = cast(EventInfo * ) _event.udata;
                    //log("Got info");
                    int event_flags = (_event.filter << 16) | (_event.flags & 0xffff);
                    //log("event flags");
                }

                //if (info.owner != m_instanceId)
                //	static if (LOG) try log("Event " ~ (cast(int)(info.evType)).to!string ~ " is invalid: supposidly created in instance #" ~ info.owner.to!string ~ ", received in " ~ m_instanceId.to!string ~ " event: " ~ event_flags.to!string);
                //	catch{}
                //log("owner");
                switch (info.evType)
                {
                case EventType.Event : if (info.fd == 0)
                        break;

                    import core.sys.posix.unistd : close;

                    success = onEvent(info.fd, info.evObj.eventHandler, event_flags);

                    if (!success)
                    {
                        close(info.fd);
                        assumeWontThrow(ThreadMem.free(info));
                    }
                    break;
                case EventType.Socket : auto socket = info.evObj.socket;
                    if (socket.passive)
                    {
                        success = onCOPSocketEvent(socket, event_flags);
                    }
                    else if (socket.connectionOriented)
                    {
                        success = onCOASocketEvent(socket, event_flags);
                    }
                    else
                    {
                        success = onCLSocketEvent(socket, event_flags);
                    }
                    break;
                case EventType.TCPAccept : if (info.fd == 0)
                        break;
                    success = onTCPAccept(info.fd, info.evObj.tcpAcceptHandler, event_flags);
                    break;

                case EventType.Notifier : static if (LOG)
                        log("Got notifier!");
                    try
                        info.evObj.notifierHandler();
                    catch (Exception e)
                    {
                        setInternalError!"notifierHandler"(Status.ERROR);
                    }
                    break;

                case EventType.DirectoryWatcher : static if (LOG)
                        log("Got DirectoryWatcher event!");
                    static if (!EPOLL)
                    {
                        // in KQUEUE all events will be consumed here, because they must be pre-processed
                        try
                        {
                            DWFileEvent fevent;
                            if (_event.fflags & (NOTE_LINK | NOTE_WRITE))
                                fevent = DWFileEvent.CREATED;
                            else if (_event.fflags & NOTE_DELETE)
                                fevent = DWFileEvent.DELETED;
                            else if (_event.fflags & (NOTE_ATTRIB | NOTE_EXTEND | NOTE_WRITE))
                                fevent = DWFileEvent.MODIFIED;
                            else if (_event.fflags & NOTE_RENAME)
                                fevent = DWFileEvent.MOVED_FROM;
                            else if (_event.fflags & NOTE_RENAME)
                                fevent = DWFileEvent.MOVED_TO;
                            else
                                assert(false, "No event found?");

                            DWFolderInfo fi = m_dwFolders.get(cast(fd_t) _event.ident,
                                    DWFolderInfo.init);

                            if (fi == DWFolderInfo.init)
                            {
                                DWFileInfo tmp = m_dwFiles.get(cast(fd_t) _event.ident,
                                        DWFileInfo.init);
                                assert(tmp != DWFileInfo.init, "The event loop returned an invalid file's file descriptor for the directory watcher");
                                fi = m_dwFolders.get(cast(fd_t) tmp.folder, DWFolderInfo.init);
                                assert(fi != DWFolderInfo.init, "The event loop returned an invalid folder file descriptor for the directory watcher");
                            }

                            // all recursive events will be generated here
                            if (!compareFolderFiles(fi, fevent))
                            {
                                continue;
                            }

                        }
                        catch (Exception e)
                        {
                            static if (LOG)
                                log("Could not process DirectoryWatcher event: " ~ e.msg);
                            break;
                        }

                    }

                    try
                        info.evObj.dwHandler();
                    catch (Exception e)
                    {
                        setInternalError!"dwHandler"(Status.ERROR);
                    }
                    break;

                case EventType.Timer : static if (LOG)
                        try
                            log("Got timer! " ~ info.fd.to!string);
                    catch
                    {
                    }
                    static if (EPOLL)
                    {
                        static long val;
                        import core.sys.posix.unistd : read;

                        read(info.evObj.timerHandler.ctxt.id,  & val, long.sizeof);
                    }
                    else
                    {
                    }
                    try
                        info.evObj.timerHandler();
                    catch (Exception e)
                    {
                        setInternalError!"timerHandler"(Status.ERROR);
                    }
                    static if (!EPOLL)
                    {
                        auto ctxt = info.evObj.timerHandler.ctxt;
                        if (ctxt && ctxt.oneShot && !ctxt.rearmed)
                        {
                            kevent_t __event;
                            EV_SET( & __event, ctxt.id, EVFILT_TIMER, EV_DELETE, 0, 0, null);
                            int err = kevent(m_kqueuefd,  & __event, 1, null, 0, null);
                            if (catchError!"kevent_del(timer)"(err))
                                return false;
                        }
                    }
                    break;

                case EventType.Signal : static if (LOG)
                        try
                            log("Got signal!");
                    catch
                    {
                    }

                    static if (EPOLL)
                    {

                        static if (LOG)
                            try
                                log(
                                        "Got signal: " ~ info.fd.to!string
                                        ~ " of type: " ~ info.evType.to!string);
                        catch
                        {
                        }
                        import core.sys.linux.sys.signalfd : signalfd_siginfo;
                        import core.sys.posix.unistd : read;

                        signalfd_siginfo fdsi;
                        fd_t err = cast(fd_t) read(info.fd,  & fdsi, fdsi.sizeof);
                        shared AsyncSignal sig = cast(shared AsyncSignal) cast(void * ) fdsi
                            .ssi_ptr;

                        try
                            sig.handler();
                        catch (Exception e)
                        {
                            setInternalError!"signal handler"(Status.ERROR);
                        }

                    }
                    else /* if KQUEUE */
                    {
                        static AsyncSignal[] sigarr;

                        if (sigarr.length == 0)
                        {
                            try
                                sigarr = new AsyncSignal[32];
                            catch (Exception e)
                            {
                                assert(false, "Could not allocate signals array");
                            }
                        }

                        bool more = popSignals(sigarr);
                        foreach (AsyncSignal sig; sigarr)
                        {
                            shared AsyncSignal ptr = cast(shared AsyncSignal) sig;
                            if (ptr is null)
                                break;
                            try
                                (cast(shared AsyncSignal) sig).handler();
                            catch (Exception e)
                            {
                                setInternalError!"signal handler"(Status.ERROR);
                            }
                        }
                    }
                    break;

                case EventType.UDPSocket : import core.sys.posix.unistd : close;

                    success = onUDPTraffic(info.fd, info.evObj.udpHandler, event_flags);

                    nothrow void abortHandler(bool graceful)
                    {

                        close(info.fd);
                        info.evObj.udpHandler.conn.socket = 0;
                        try
                            info.evObj.udpHandler(UDPEvent.ERROR);
                        catch (Exception e)
                        {
                        }
                        try
                            ThreadMem.free(info);
                        catch (Exception e)
                        {
                            assert(false, "Error freeing resources");
                        }
                    }

                    if (!success && m_status.code == Status.ABORT)
                    {
                        abortHandler(true);

                    }
                    else if (!success && m_status.code == Status.ERROR)
                    {
                        abortHandler(false);
                    }
                    break;
                case EventType.TCPTraffic : assert(info.evObj.tcpEvHandler.conn !is null,
                            "TCP Connection invalid");

                    success = onTCPTraffic(info.fd, info.evObj.tcpEvHandler,
                            event_flags, info.evObj.tcpEvHandler.conn);

                    nothrow void abortTCPHandler(bool graceful)
                    {

                        nothrow void closeAll()
                        {
                            static if (LOG)
                                try
                                    log("closeAll()");
                            catch
                            {
                            }
                            if (info.evObj.tcpEvHandler.conn.connected)
                                closeSocket(info.fd, true, true);

                            info.evObj.tcpEvHandler.conn.socket = 0;
                        }

                        /// Close the connection after an unexpected socket error
                        if (graceful)
                        {
                            try
                                info.evObj.tcpEvHandler(TCPEvent.CLOSE);
                            catch (Exception e)
                            {
                                static if (LOG)
                                    log("Close failure");
                            }
                            closeAll();
                        }

                        /// Kill the connection after an internal error
                        else
                        {
                            try
                                info.evObj.tcpEvHandler(TCPEvent.ERROR);
                            catch (Exception e)
                            {
                                static if (LOG)
                                    log("Error failure");
                            }
                            closeAll();
                        }

                        if (info.evObj.tcpEvHandler.conn.inbound)
                        {
                            static if (LOG)
                                log("Freeing inbound connection FD#" ~ info.fd.to!string);
                            try
                                ThreadMem.free(info.evObj.tcpEvHandler.conn);
                            catch (Exception e)
                            {
                                assert(false, "Error freeing resources");
                            }
                        }
                        try
                            ThreadMem.free(info);
                        catch (Exception e)
                        {
                            assert(false, "Error freeing resources");
                        }
                    }

                    if (!success && m_status.code == Status.ABORT)
                    {
                        abortTCPHandler(true);
                    }
                    else if (!success && m_status.code == Status.ERROR)
                    {
                        abortTCPHandler(false);
                    }
                    break;
                default : break;
                }

            }

            return success;
        }

        if (m_completedSocketAccepts.empty && m_completedSocketReceives.empty
                && m_completedSocketSends.empty)
        {
            num = waitForEvents(timeout);
            return handleEvents();
        }
        else
        {
            num = waitForEvents(0.seconds);
            if (num != 0 && !handleEvents())
                return false;

            foreach (request; m_completedSocketAccepts)
            {
                m_completedSocketAccepts.removeFront();
                auto socket = request.socket;
                auto peer = request.onComplete(request.peer, request.family,
                        socket.info.type, socket.info.protocol);
                assumeWontThrow(AsyncAcceptRequest.free(request));
                if (!peer.run)
                {
                    m_status.code = Status.ABORT;
                    peer.kill();
                    peer.handleError();
                    return false;
                }
            }

            foreach (request; m_completedSocketReceives)
            {
                if (request.socket.receiveContinuously)
                {
                    m_completedSocketReceives.removeFront();
                    assumeWontThrow(request.onComplete.get!0)(request.message.transferred);
                    if (request.socket.receiveContinuously && request.socket.alive)
                    {
                        request.message.count = 0;
                        submitRequest(request);
                    }
                    else
                    {
                        assumeWontThrow(NetworkMessage.free(request.message));
                        assumeWontThrow(AsyncReceiveRequest.free(request));
                    }
                }
                else
                {
                    m_completedSocketReceives.removeFront();
                    if (request.message)
                    {
                        assumeWontThrow(request.onComplete.get!0)(request.message.transferred);
                        assumeWontThrow(NetworkMessage.free(request.message));
                    }
                    else
                    {
                        assumeWontThrow(request.onComplete.get!1)();
                    }
                    assumeWontThrow(AsyncReceiveRequest.free(request));
                }
            }

            foreach (request; m_completedSocketSends)
            {
                m_completedSocketSends.removeFront();
                request.onComplete();
                assumeWontThrow(NetworkMessage.free(request.message));
                assumeWontThrow(AsyncSendRequest.free(request));
            }

            return true;
        }
    }

    bool setOption(T)(fd_t fd, TCPOption option, in T value)
    {
        m_status = StatusInfo.init;
        import std.traits : isIntegral;

        import libasync.internals.socket_compat : socklen_t, setsockopt,
            SO_REUSEADDR, SO_KEEPALIVE, SO_RCVBUF, SO_SNDBUF, SO_RCVTIMEO,
            SO_SNDTIMEO, SO_LINGER, SOL_SOCKET, IPPROTO_TCP, TCP_NODELAY,
            TCP_QUICKACK, TCP_KEEPCNT, TCP_KEEPINTVL, TCP_KEEPIDLE,
            TCP_CONGESTION, TCP_CORK, TCP_DEFER_ACCEPT;

        int err;
        nothrow bool errorHandler()
        {
            if (catchError!"setOption:"(err))
            {
                try
                    m_status.text ~= option.to!string;
                catch (Exception e)
                {
                    assert(false, "to!string conversion failure");
                }
                return false;
            }

            return true;
        }
        final switch (option)
        {
        case TCPOption.NODELAY :  // true/false
            static if (!is(T == bool))
                assert(false,
                        "NODELAY value type must be bool, not " ~ T.stringof);
            else
            {
                int val = value ? 1 : 0;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY,  & val, len);
                return errorHandler();
            }
        case TCPOption.REUSEADDR :  // true/false
            static if (!is(T == bool))
                assert(false,
                        "REUSEADDR value type must be bool, not " ~ T.stringof);
            else
            {
                int val = value ? 1 : 0;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,  & val, len);
                if (!errorHandler())
                    return false;
                version (Posix)
                {
                    version (linux)
                    {
                        return true;
                    }
                    else
                    {
                        // BSD systems have SO_REUSEPORT
                        import libasync.internals.socket_compat : SO_REUSEPORT;

                        err = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT,  & val, len);
                        return errorHandler();
                    }
                }
            }
        case TCPOption.REUSEPORT :  // true/false
            // use a standalone REUSEPORT option to handle SO_REUSEPORT on linux
            version (linux)
            {
                static if (!is(T == bool))
                    assert(false, "REUSEPORT value type must be bool, not " ~ T.stringof);
                else
                {
                    // BSD systems have SO_REUSEPORT
                    import libasync.internals.socket_compat : SO_REUSEPORT;

                    int val = value ? 1 : 0;
                    err = setsockopt(fd, SOL_SOCKET, SO_REUSEPORT,  & val, val.sizeof);

                    // Not all linux kernels support SO_REUSEPORT
                    // ignore invalid and not supported errors on linux
                    if (errno == EINVAL || errno == ENOPROTOOPT)
                    {
                        return true;
                    }

                    return errorHandler();
                }
            }
            else
                return true;
        case TCPOption.QUICK_ACK : static if (!is(T == bool))
                assert(false,
                        "QUICK_ACK value type must be bool, not " ~ T.stringof);
            else
            {
                static if (EPOLL)
                {
                    int val = value ? 1 : 0;
                    socklen_t len = val.sizeof;
                    err = setsockopt(fd, IPPROTO_TCP, TCP_QUICKACK,  & val, len);
                    return errorHandler();
                }
                else /* not linux */
                {
                    return false;
                }
            }
        case TCPOption.KEEPALIVE_ENABLE :  // true/false
            static if (!is(T == bool))
                assert(false,
                        "KEEPALIVE_ENABLE value type must be bool, not " ~ T.stringof);
            else
            {
                int val = value ? 1 : 0;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE,  & val, len);
                return errorHandler();
            }
        case TCPOption.KEEPALIVE_COUNT :  // ##
            static if (!isIntegral!T)
                assert(false,
                        "KEEPALIVE_COUNT value type must be integral, not " ~ T.stringof);
            else
            {
                int val = value.total!"msecs".to!uint;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT,  & val, len);
                return errorHandler();
            }
        case TCPOption.KEEPALIVE_INTERVAL :  // wait ## seconds
            static if (!is(T == Duration))
                assert(false,
                        "KEEPALIVE_INTERVAL value type must be Duration, not " ~ T.stringof);
            else
            {
                int val;
                try
                    val = value.total!"seconds".to!uint;
                catch
                {
                    return false;
                }
                socklen_t len = val.sizeof;
                err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL,  & val, len);
                return errorHandler();
            }
        case TCPOption.KEEPALIVE_DEFER :  // wait ## seconds until start
            static if (!is(T == Duration))
                assert(false,
                        "KEEPALIVE_DEFER value type must be Duration, not " ~ T.stringof);
            else
            {
                int val;
                try
                    val = value.total!"seconds".to!uint;
                catch
                {
                    return false;
                }
                socklen_t len = val.sizeof;
                err = setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE,  & val, len);
                return errorHandler();
            }
        case TCPOption.BUFFER_RECV :  // bytes
            static if (!isIntegral!T)
                assert(false,
                        "BUFFER_RECV value type must be integral, not " ~ T.stringof);
            else
            {
                int val = value.to!int;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_RCVBUF,  & val, len);
                return errorHandler();
            }
        case TCPOption.BUFFER_SEND :  // bytes
            static if (!isIntegral!T)
                assert(false,
                        "BUFFER_SEND value type must be integral, not " ~ T.stringof);
            else
            {
                int val = value.to!int;
                socklen_t len = val.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_SNDBUF,  & val, len);
                return errorHandler();
            }
        case TCPOption.TIMEOUT_RECV : static if (!is(T == Duration))
                assert(false,
                        "TIMEOUT_RECV value type must be Duration, not " ~ T.stringof);
            else
            {
                import core.sys.posix.sys.time : timeval;

                time_t secs = cast(time_t) value.split!("seconds", "usecs")().seconds;
                suseconds_t us;
                try
                    us = value.split!("seconds", "usecs")().usecs.to!suseconds_t;
                catch
                {
                }
                timeval t = timeval(secs, us);
                socklen_t len = t.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO,  & t, len);
                return errorHandler();
            }
        case TCPOption.TIMEOUT_SEND : static if (!is(T == Duration))
                assert(false,
                        "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
            else
            {
                import core.sys.posix.sys.time : timeval;

                auto timeout = value.split!("seconds", "usecs")();
                timeval t;
                try
                    t = timeval(timeout.seconds.to!time_t, timeout.usecs.to!suseconds_t);
                catch (Exception)
                {
                    return false;
                }
                socklen_t len = t.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,  & t, len);
                return errorHandler();
            }
        case TCPOption.TIMEOUT_HALFOPEN : static if (!is(T == Duration))
                assert(false,
                        "TIMEOUT_SEND value type must be Duration, not " ~ T.stringof);
            else
            {
                uint val;
                try
                    val = value.total!"msecs".to!uint;
                catch
                {
                    return false;
                }
                socklen_t len = val.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO,  & val, len);
                return errorHandler();
            }
        case TCPOption.LINGER :  // bool onOff, int seconds
            static if (!is(T == Tuple!(bool, int)))
                assert(false,
                        "LINGER value type must be Tuple!(bool, int), not " ~ T.stringof);
            else
            {
                linger l = linger(val[0] ? 1 : 0, val[1]);
                socklen_t llen = l.sizeof;
                err = setsockopt(fd, SOL_SOCKET, SO_LINGER,  & l, llen);
                return errorHandler();
            }
        case TCPOption.CONGESTION : static if (!isIntegral!T)
                assert(false,
                        "CONGESTION value type must be integral, not " ~ T.stringof);
            else
            {
                int val = value.to!int;
                len = int.sizeof;
                err = setsockopt(fd, IPPROTO_TCP, TCP_CONGESTION,  & val, len);
                return errorHandler();
            }
        case TCPOption.CORK : static if (!isIntegral!T)
                assert(false,
                        "CORK value type must be int, not " ~ T.stringof);
            else
            {
                static if (EPOLL)
                {
                    int val = value.to!int;
                    socklen_t len = val.sizeof;
                    err = setsockopt(fd, IPPROTO_TCP, TCP_CORK,  & val, len);
                    return errorHandler();
                }
                else /* if KQUEUE */
                {
                    int val = value.to!int;
                    socklen_t len = val.sizeof;
                    err = setsockopt(fd, IPPROTO_TCP, TCP_NOPUSH,  & val, len);
                    return errorHandler();

                }
            }
        case TCPOption.DEFER_ACCEPT :  // seconds
            static if (!isIntegral!T)
                assert(false,
                        "DEFER_ACCEPT value type must be integral, not " ~ T.stringof);
            else
            {
                static if (EPOLL)
                {
                    int val = value.to!int;
                    socklen_t len = val.sizeof;
                    err = setsockopt(fd, IPPROTO_TCP, TCP_DEFER_ACCEPT,  & val, len);
                    return errorHandler();
                }
                else /* if KQUEUE */
                {
                    // todo: Emulate DEFER_ACCEPT with ACCEPT_FILTER(9)
                    /*int val = value.to!int;
						 socklen_t len = val.sizeof;
						 err = setsockopt(fd, SOL_SOCKET, SO_ACCEPTFILTER, &val, len);
						 return errorHandler();
						 */
                    assert(false, "TCPOption.DEFER_ACCEPT is not implemented");
                }
            }
        }

    }

    uint recv(in fd_t fd, ubyte[] data)
    {
        static if (LOG)
            try
                log("Recv from FD: " ~ fd.to!string);
        catch
        {
        }
        m_status = StatusInfo.init;
        import libasync.internals.socket_compat : recv;

    retry:
        auto ret = cast(int) recv(fd, cast(void*) data.ptr, data.length, 0);

        static if (LOG)
            try
                log(
                        ".recv " ~ ret.to!string ~ " bytes of "
                        ~ data.length.to!string ~ " @ " ~ fd.to!string);
        catch
        {
        }
        if (catchError!".recv"(ret))
        {
            if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
            {
                m_status.code = Status.ASYNC;
            }
            else
                switch (m_error) with (EPosix)
            {
            case EINTR:
                goto retry;
            case EBADF, EFAULT, EINVAL, ENOTCONN, ENOTSOCK:
                // Encountering any of these in the wild means it's bug hunting season
                assert(false,
                        ".recv encountered terminal socket error "
                        ~ m_error.to!string ~ " @ " ~ fd.to!string);
            default:
                static if (LOG)
                    try
                        log(
                                ".recv encountered socket error "
                                ~ m_error.to!string ~ " @ " ~ fd.to!string);
                catch
                {
                }
                break;
            }

            return 0;
        }

        m_status.code = Status.OK;
        // FIXME: This may overflow
        return cast(uint) ret;
    }

    uint send(in fd_t fd, in ubyte[] data)
    {
        static if (LOG)
            try
                log("Send to FD: " ~ fd.to!string);
        catch
        {
        }
        m_status = StatusInfo.init;
        import libasync.internals.socket_compat : send;

    retry:
        auto ret = cast(int) send(fd, cast(const(void)*) data.ptr, data.length, 0);

        static if (LOG)
            try
                log("Sent: " ~ ret.to!string);
        catch
        {
        }
        if (catchError!".send"(ret))
        {
            if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
            {
                m_status.code = Status.ASYNC;
            }
            else
                switch (m_error) with (EPosix)
            {
            case EINTR:
                goto retry;
            case EBADF, ECONNRESET, EDESTADDRREQ, EFAULT, EINVAL, EISCONN,
                    EMSGSIZE, ENOTCONN, ENOTSOCK, EOPNOTSUPP, EPIPE:
                    // Encountering any of these in the wild means it's bug hunting season
                    assert(false,
                            ".send encountered terminal socket error "
                            ~ m_error.to!string ~ " @ " ~ fd.to!string);
            default:
                static if (LOG)
                    try
                        log(
                                ".send encountered socket error "
                                ~ m_error.to!string ~ " @ " ~ fd.to!string);
                catch
                {
                }
                break;
            }

            return 0;
        }

        m_status.code = Status.OK;
        // FIXME: This may overflow
        return cast(uint) ret;
    }

    size_t recvMsg(in fd_t fd, NetworkMessage* msg)
    {
        import libasync.internals.socket_compat : recvmsg, msghdr, iovec,
            sockaddr_storage;

        while (true)
        {
            auto err = recvmsg(fd, msg.header, 0);

            .tracef("recvmsg system call on FD %d returned %d", fd, err);
            if (err == SOCKET_ERROR)
            {
                m_error = lastError();

                if (m_error == EPosix.EINTR)
                {
                    .tracef("recvmsg system call on FD %d was interrupted before any transfer occured",
                            fd);
                    continue;
                }
                else if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
                {
                    .tracef("recvmsg system call on FD %d would have blocked", fd);
                    m_status.code = Status.ASYNC;
                    return 0;
                }
                else if (m_error == EBADF || m_error == EFAULT
                        || m_error == EINVAL || m_error == ENOTCONN || m_error == ENOTSOCK)
                {
                    .errorf("recvmsg system call on FD %d encountered fatal socket error: %s",
                            fd, this.error);
                    assert(false);
                }
                else if (catchError!"Receive message"(err))
                {
                    .errorf("recvmsg system call on FD %d encountered socket error: %s",
                            fd, this.error);
                    return 0;
                }
            }
            else
            {
                .tracef("Received %d bytes on FD %d", err, fd);
                m_status.code = Status.OK;
                return err;
            }
        }
    }

    size_t sendMsg(in fd_t fd, NetworkMessage* msg)
    {
        import libasync.internals.socket_compat : sendmsg;

        .tracef("Send message on FD %d with size %d", fd, msg.header.msg_iov.iov_len);
        m_status = StatusInfo.init;

        while (true)
        {
            auto err = sendmsg(fd, msg.header, 0);

            .tracef("sendmsg system call on FD %d returned %d", fd, err);
            if (err == SOCKET_ERROR)
            {
                m_error = lastError();

                if (m_error == EPosix.EINTR)
                {
                    .tracef("sendmsg system call on FD %d was interrupted before any transfer occured",
                            fd);
                    continue;
                }
                else if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
                {
                    .tracef("sendmsg system call on FD %d would have blocked", fd);
                    m_status.code = Status.ASYNC;
                    return 0;
                }
                else if (m_error == ECONNRESET || m_error == EPIPE)
                {
                    return 0;
                }
                else if (m_error == EBADF || m_error == EDESTADDRREQ || m_error == EFAULT || m_error == EINVAL
                        || m_error == EISCONN || m_error == ENOTSOCK || m_error == EOPNOTSUPP)
                {
                    .errorf("sendmsg system call on FD %d encountered fatal socket error: %s",
                            fd, this.error);
                    assert(false);
                    // ENOTCONN, EMSGSIZE
                }
                else if (catchError!"Send message"(err))
                {
                    .errorf("sendmsg system call on FD %d encountered socket error: %s",
                            fd, this.error);
                    return 0;
                }
            }
            else
            {
                .tracef("Sent %d bytes on FD %d", err, fd);
                m_status.code = Status.OK;
                return err;
            }
        }
    }

    uint recvFrom(in fd_t fd, ubyte[] data, ref NetworkAddress addr)
    {
        import libasync.internals.socket_compat : recvfrom, AF_INET6, AF_INET,
            socklen_t;

        m_status = StatusInfo.init;

    retry:
        auto addrLen = NetworkAddress.sockAddrMaxLen();
        auto ret = recvfrom(fd, cast(void*) data.ptr, data.length, 0, addr.sockAddr, &addrLen);

        static if (LOG)
            log(".recvFrom " ~ ret.to!string ~ " bytes @ " ~ fd.to!string);
        if (catchError!".recvFrom"(ret))
        {
            if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
            {
                m_status.code = Status.ASYNC;
            }
            else
                switch (m_error) with (EPosix)
            {
            case EINTR:
                goto retry;
            case EBADF, EFAULT, EINVAL, ENOTCONN, ENOTSOCK:
                // Encountering any of these in the wild means it's bug hunting season
                assert(false,
                        ".recvFrom encountered terminal socket error "
                        ~ m_error.to!string ~ " @ " ~ fd.to!string);
            default:
                static if (LOG)
                    try
                        log(
                                ".recvFrom encountered socket error "
                                ~ m_error.to!string ~ " @ " ~ fd.to!string);
                catch
                {
                }
                break;
            }

            return 0;
        }

        m_status.code = Status.OK;
        // FIXME: This may overflow
        return cast(uint) ret;
    }

    uint sendTo(in fd_t fd, in ubyte[] data, in NetworkAddress addr)
    {
        import libasync.internals.socket_compat : sendto;

        m_status = StatusInfo.init;

        static if (LOG)
            try
                log(".sendTo " ~ data.length.to!string ~ "bytes");
        catch
        {
        }
    retry:
        auto ret = sendto(fd, data.ptr, data.length, 0, addr.sockAddr, addr.sockAddrLen);

        if (catchError!".sendTo"(ret))
        {
            if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
            {
                m_status.code = Status.ASYNC;
            }
            else
                switch (m_error) with (EPosix)
            {
            case EINTR:
                goto retry;
            case EBADF, ECONNRESET, EDESTADDRREQ, EFAULT, EINVAL, EISCONN,
                    EMSGSIZE, ENOTCONN, ENOTSOCK, EOPNOTSUPP, EPIPE:
                    // Encountering any of these in the wild means it's bug hunting season
                    assert(false,
                            ".sendTo encountered terminal socket error "
                            ~ m_error.to!string ~ " @ " ~ fd.to!string);
            default:
                static if (LOG)
                    try
                        log(
                                ".sendTo encountered socket error "
                                ~ m_error.to!string ~ " @ " ~ fd.to!string);
                catch
                {
                }
                break;
            }

            return 0;
        }

        m_status.code = Status.OK;
        // FIXME: This may overflow
        return cast(uint) ret;
    }

    NetworkAddress localAddr(in fd_t fd, bool ipv6)
    {
        NetworkAddress ret;
        import libasync.internals.socket_compat : getsockname, AF_INET,
            AF_INET6, socklen_t, sockaddr;

        if (ipv6)
            ret.family = AF_INET6;
        else
            ret.family = AF_INET;

        socklen_t len = ret.sockAddrLen;
        int err = getsockname(fd, ret.sockAddr, &len);
        if (catchError!"getsockname"(err))
            return NetworkAddress.init;
        if (len > ret.sockAddrLen)
            ret.family = AF_INET6;

        return ret;
    }

    bool notify(in fd_t fd, AsyncNotifier ctxt)
    {
        static if (EPOLL)
        {
            import core.sys.posix.unistd : write;

            long val = 1;
            fd_t err = cast(fd_t) write(fd, &val, long.sizeof);

            if (catchError!"write(notify)"(err))
            {
                return false;
            }
            return true;
        }
        else /* if KQUEUE */
        {
            kevent_t _event;
            EV_SET(&_event, fd, EVFILT_USER, EV_ENABLE | EV_CLEAR,
                    NOTE_TRIGGER | 0x1, 0, ctxt.evInfo);
            int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);

            if (catchError!"kevent_notify"(err))
            {
                return false;
            }
            return true;
        }
    }

    bool notify(in fd_t fd, shared AsyncSignal ctxt)
    {
        static if (EPOLL)
        {

            sigval sigvl;
            fd_t err;
            sigvl.sival_ptr = cast(void*) ctxt;
            try
                err = pthread_sigqueue(ctxt.pthreadId, fd, sigvl);
            catch (Throwable)
            {
            }
            if (catchError!"sigqueue"(err))
            {
                return false;
            }
        }
        else /* if KQUEUE */
        {

            import core.thread : getpid;

            addSignal(ctxt);

            try
            {
                static if (LOG)
                    log("Notified fd: " ~ fd.to!string ~ " of PID " ~ getpid().to!string);
                int err = core.sys.posix.signal.kill(getpid(), SIGXCPU);
                if (catchError!"notify(signal)"(err))
                    assert(false, "Signal could not be raised");
            }
            catch (Throwable)
            {
            }
        }

        return true;
    }

    // no known uses
    uint read(in fd_t fd, ref ubyte[] data)
    {
        m_status = StatusInfo.init;
        return 0;
    }

    // no known uses
    uint write(in fd_t fd, in ubyte[] data)
    {
        m_status = StatusInfo.init;
        return 0;
    }

    uint watch(in fd_t fd, in WatchInfo info)
    {
        // note: info.wd is still 0 at this point.
        m_status = StatusInfo.init;
        import core.sys.linux.sys.inotify;
        import std.file : dirEntries, isDir, SpanMode;

        static if (EPOLL)
        {
            // Manually handle recursivity... All events show up under the same inotify
            uint events = info.events; // values for this API were pulled from inotify
            if (events & IN_DELETE)
                events |= IN_DELETE_SELF;
            if (events & IN_MOVED_FROM)
                events |= IN_MOVE_SELF;

            nothrow fd_t addFolderRecursive(Path path)
            {
                fd_t ret;
                try
                {
                    ret = inotify_add_watch(fd, path.toNativeString().toStringz, events);
                    if (catchError!"inotify_add_watch"(ret))
                        return fd_t.init;
                    static if (LOG)
                        try
                            log("inotify_add_watch(" ~ DWFolderInfo(WatchInfo(info.events,
                                    path, info.recursive, ret), fd).to!string ~ ")");
                    catch (Throwable)
                    {
                    }
                    assert(m_dwFolders.get(tuple(cast(fd_t) fd, cast(uint) ret), DWFolderInfo.init) == DWFolderInfo.init,
                            "Could not get a unique watch descriptor for path, got: " ~ m_dwFolders[tuple(cast(fd_t) fd,
                                cast(uint) ret)].to!string);
                    m_dwFolders[tuple(cast(fd_t) fd, cast(uint) ret)] = DWFolderInfo(WatchInfo(info.events,
                            path, info.recursive, ret), fd);
                }
                catch (Exception e)
                {
                    try
                        setInternalError!"inotify_add_watch"(Status.ERROR,
                                "Could not add directory " ~ path.toNativeString() ~ ": " ~ e.toString());
                    catch (Throwable)
                    {
                    }
                    return 0;
                }

                if (info.recursive)
                {
                    try
                    {
                        foreach (de; path.toNativeString().dirEntries(SpanMode.shallow))
                        {
                            Path de_path = Path(de.name);
                            if (!de_path.absolute)
                                de_path = path ~ Path(de.name);
                            if (isDir(de_path.toNativeString()))
                                if (addFolderRecursive(de_path) == 0)
                                    continue;
                        }
                    }
                    catch (Exception e)
                    {
                        try
                            setInternalError!"inotify_add_watch"(Status.ERROR,
                                    "Could not add sub-directories of " ~ path.toNativeString() ~ ": " ~ e.toString());
                        catch (Throwable)
                        {
                        }
                    }
                }

                return ret;
            }

            return addFolderRecursive(info.path);

        }
        else /* if KQUEUE */
        {
            /// Manually handle recursivity & file tracking. Each folder is an event!
            /// E.g. file creation shows up as a folder change, we must be prepared to seek the file.
            import core.sys.posix.fcntl;
            import libasync.internals.kqueue;

            uint events;
            if (info.events & DWFileEvent.CREATED)
                events |= NOTE_LINK | NOTE_WRITE;
            if (info.events & DWFileEvent.DELETED)
                events |= NOTE_DELETE;
            if (info.events & DWFileEvent.MODIFIED)
                events |= NOTE_ATTRIB | NOTE_EXTEND | NOTE_WRITE;
            if (info.events & DWFileEvent.MOVED_FROM)
                events |= NOTE_RENAME;
            if (info.events & DWFileEvent.MOVED_TO)
                events |= NOTE_RENAME;

            EventInfo* evinfo;
            try
            {
                evinfo = m_watchers[fd];
            }
            catch (Throwable)
            {
                assert(false, "Could retrieve event info, directory watcher was not initialized properly, or you are operating on a closed directory watcher.");
            }

            /// we need a file descriptor for the containers, so we open files but we don't monitor them
            /// todo: track indexes internally?
            nothrow fd_t addRecursive(Path path, bool is_dir)
            {
                int ret;
                try
                {
                    static if (LOG)
                        log("Adding path: " ~ path.toNativeString());

                    ret = open(path.toNativeString().toStringz, O_EVTONLY);
                    if (catchError!"open(watch)"(ret))
                        return 0;

                    if (is_dir)
                        m_dwFolders[ret] = DWFolderInfo(WatchInfo(info.events,
                                path, info.recursive, ret), fd);

                    kevent_t _event;

                    EV_SET(&_event, ret, EVFILT_VNODE, EV_ADD | EV_CLEAR,
                            events, 0, cast(void*) evinfo);

                    int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);

                    if (catchError!"kevent_timer_add"(err))
                        return 0;

                    if (is_dir)
                        foreach (de; dirEntries(path.toNativeString(), SpanMode.shallow))
                        {
                            Path filePath = Path(de.name);
                            if (!filePath.absolute)
                                filePath = path ~ filePath;
                            fd_t fwd;
                            if (info.recursive && isDir(filePath.toNativeString()))
                                fwd = addRecursive(filePath, true);
                            else
                            {
                                fwd = addRecursive(filePath, false); // gets an ID but will not scan
                                m_dwFiles[fwd] = DWFileInfo(ret, filePath,
                                        de.timeLastModified, isDir(filePath.toNativeString()));
                            }

                        }

                }
                catch (Exception e)
                {
                    try
                        setInternalError!"inotify_add_watch"(Status.ERROR,
                                "Could not add directory " ~ path.toNativeString() ~ ": " ~ e.msg);
                    catch (Throwable)
                    {
                    }
                    return 0;
                }
                return ret;
            }

            fd_t wd;

            try
            {
                wd = addRecursive(info.path, isDir(info.path.toNativeString()));

                if (wd == 0)
                    return 0;

            }
            catch (Exception e)
            {
                setInternalError!"dw.watch"(Status.ERROR, "Failed to watch directory: " ~ e.msg);
            }

            return cast(uint) wd;
        }
    }

    bool unwatch(in fd_t fd, in uint wd)
    {
        // the wd can be used with m_dwFolders to find the DWFolderInfo
        // and unwatch everything recursively.

        m_status = StatusInfo.init;
        static if (EPOLL)
        {
            /// If recursive, all subfolders must also be unwatched recursively by removing them
            /// from containers and from inotify
            import core.sys.linux.sys.inotify;

            nothrow bool removeAll(DWFolderInfo fi)
            {
                int err;
                try
                {

                    bool inotify_unwatch(uint wd)
                    {
                        err = inotify_rm_watch(fd, wd);

                        if (catchError!"inotify_rm_watch"(err))
                            return false;
                        return true;
                    }

                    if (!inotify_unwatch(fi.wi.wd))
                        return false;

                    /*foreach (ref const fd_t id, ref const DWFileInfo file; m_dwFiles)
					 {
					 if (file.folder == fi.wi.wd) {
					 inotify_unwatch(id);
					 m_dwFiles.remove(id);
					 }
					 }*/
                    m_dwFolders.remove(tuple(cast(fd_t) fd, fi.wi.wd));

                    if (fi.wi.recursive)
                    {
                        // find all subdirectories by comparing the path
                        Array!(Tuple!(fd_t, uint)) remove_list;
                        foreach (ref const key, ref const DWFolderInfo folder; m_dwFolders)
                        {
                            if (folder.fd == fi.fd && folder.wi.path.startsWith(fi.wi.path))
                            {

                                if (!inotify_unwatch(folder.wi.wd))
                                    return false;

                                remove_list.insertBack(key);
                            }
                        }
                        foreach (rm_wd; remove_list[])
                            m_dwFolders.remove(rm_wd);

                    }
                    return true;
                }
                catch (Exception e)
                {
                    try
                        setInternalError!"inotify_rm_watch"(Status.ERROR,
                                "Could not unwatch directory: " ~ e.toString());
                    catch (Throwable)
                    {
                    }
                    return false;
                }
            }

            DWFolderInfo info;

            try
            {
                info = m_dwFolders.get(tuple(cast(fd_t) fd, cast(uint) wd), DWFolderInfo.init);
                if (info == DWFolderInfo.init)
                {
                    setInternalError!"dwFolders.get(wd)"(Status.ERROR,
                            "Could not find watch info for wd " ~ wd.to!string);
                    return false;
                }
            }
            catch (Throwable)
            {
            }

            return removeAll(info);
        }
        else /* if KQUEUE */
        {

            /// Recursivity must be handled manually, so we must unwatch subfiles and subfolders
            /// recursively, remove the container entries, close the file descriptor, and disable the vnode events.

            nothrow bool removeAll(DWFolderInfo fi)
            {
                import core.sys.posix.unistd : close;

                bool event_unset(uint id)
                {
                    kevent_t _event;
                    EV_SET(&_event, cast(int) id, EVFILT_VNODE, EV_DELETE, 0, 0, null);
                    int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
                    if (catchError!"kevent_unwatch"(err))
                        return false;
                    return true;
                }

                bool removeFolder(uint wd)
                {
                    if (!event_unset(fi.wi.wd))
                        return false;
                    m_dwFolders.remove(fi.wi.wd);
                    int err = close(fi.wi.wd);
                    if (catchError!"close dir"(err))
                        return false;
                    return true;
                }

                try
                {
                    removeFolder(fi.wi.wd);

                    if (fi.wi.recursive)
                    {
                        import std.container.array;

                        Array!fd_t remove_list; // keep track of unwatched folders recursively
                        Array!fd_t remove_file_list;
                        // search for subfolders and unset them / close their wd
                        foreach (ref const DWFolderInfo folder; m_dwFolders)
                        {
                            if (folder.fd == fi.fd && folder.wi.path.startsWith(fi.wi.path))
                            {

                                if (!event_unset(folder.wi.wd))
                                    return false;

                                // search for subfiles, close their descriptors and remove them from the file list
                                foreach (ref const fd_t fwd, ref const DWFileInfo file;
                                        m_dwFiles)
                                {
                                    if (file.folder == folder.wi.wd)
                                    {
                                        close(fwd);
                                        remove_file_list.insertBack(fwd); // to be removed from m_dwFiles without affecting the loop
                                    }
                                }

                                remove_list.insertBack(folder.wi.wd); // to be removed from m_dwFolders without affecting the loop
                            }
                        }

                        foreach (wd; remove_file_list[])
                            m_dwFiles.remove(wd);

                        foreach (rm_wd; remove_list[])
                            removeFolder(rm_wd);

                    }
                }
                catch (Exception e)
                {
                    try
                        setInternalError!"dwFolders.get(wd)"(Status.ERROR,
                                "Could not close the folder " ~ fi.to!string ~ ": " ~ e.toString());
                    catch (Throwable)
                    {
                    }
                    return false;
                }

                return true;
            }

            DWFolderInfo info;
            try
                info = m_dwFolders.get(wd, DWFolderInfo.init);
            catch (Throwable)
            {
            }

            if (!removeAll(info))
                return false;
            return true;
        }
    }

    // returns the amount of changes
    uint readChanges(in fd_t fd, ref DWChangeInfo[] dst)
    {
        m_status = StatusInfo.init;

        static if (EPOLL)
        {
            assert(dst.length > 0, "DirectoryWatcher called with 0 length DWChangeInfo array");
            import core.sys.linux.sys.inotify;
            import core.sys.posix.unistd : read;
            import core.stdc.stdio : FILENAME_MAX;
            import core.stdc.string : strlen;

            ubyte[inotify_event.sizeof + FILENAME_MAX + 1] buf = void;
            ssize_t nread = read(fd, buf.ptr, cast(uint) buf.sizeof);
            if (catchError!"read()"(nread))
            {
                if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
                    m_status.code = Status.ASYNC;
                return 0;
            }
            assert(nread > 0);

            /// starts (recursively) watching all newly created folders in a recursive entry,
            /// creates events for additional files/folders founds, and unwatches all deleted folders
            void recurseInto(DWFolderInfo fi, DWFileEvent ev, ref Array!DWChangeInfo changes)
            {
                import std.file : dirEntries, SpanMode, isDir;

                assert(fi.wi.recursive);
                // get a list of stuff in the created/moved folder
                if (ev == DWFileEvent.CREATED || ev == DWFileEvent.MOVED_TO)
                {
                    foreach (de; dirEntries(fi.wi.path.toNativeString(), SpanMode.shallow))
                    {
                        Path entryPath = Path(de.name);
                        if (!entryPath.absolute)
                            entryPath = fi.wi.path ~ entryPath;

                        if (fi.wi.recursive && isDir(entryPath.toNativeString()))
                        {

                            watch(fd, WatchInfo(fi.wi.events, entryPath, fi.wi.recursive, 0));
                            void genEvents(Path subpath)
                            {
                                foreach (de; dirEntries(subpath.toNativeString(), SpanMode.shallow))
                                {
                                    auto subsubpath = Path(de.name);
                                    if (!subsubpath.absolute)
                                        subsubpath = subpath ~ subsubpath;
                                    changes.insertBack(DWChangeInfo(DWFileEvent.CREATED,
                                            subsubpath));
                                    if (isDir(subsubpath.toNativeString()))
                                        genEvents(subsubpath);
                                }
                            }

                            genEvents(entryPath);

                        }
                    }
                }
            }

            size_t i;
            do
            {
                for (auto p = buf.ptr; p < buf.ptr + nread;)
                {
                    inotify_event* ev = cast(inotify_event*) p;
                    p += inotify_event.sizeof + ev.len;

                    DWFileEvent evtype;
                    evtype = DWFileEvent.CREATED;
                    if (ev.mask & IN_CREATE)
                        evtype = DWFileEvent.CREATED;
                    if (ev.mask & IN_DELETE || ev.mask & IN_DELETE_SELF)
                        evtype = DWFileEvent.DELETED;
                    if (ev.mask & IN_MOVED_FROM || ev.mask & IN_MOVE_SELF)
                        evtype = DWFileEvent.MOVED_FROM;
                    if (ev.mask & (IN_MOVED_TO))
                        evtype = DWFileEvent.MOVED_TO;
                    if (ev.mask & IN_MODIFY)
                        evtype = DWFileEvent.MODIFIED;

                    import std.path : buildPath;
                    import core.stdc.string : strlen;

                    string name = cast(string) ev.name.ptr[0 .. cast(size_t) ev.name.ptr.strlen]
                        .idup;
                    DWFolderInfo fi;
                    Path path;
                    try
                    {
                        fi = m_dwFolders.get(tuple(cast(fd_t) fd,
                                cast(uint) ev.wd), DWFolderInfo.init);
                        if (fi == DWFolderInfo.init)
                        {
                            setInternalError!"m_dwFolders[ev.wd]"(Status.ERROR,
                                    "Could not retrieve wd index in folders: " ~ ev.wd.to!string);
                            continue;
                        }
                        path = fi.wi.path ~ Path(name);
                    }
                    catch (Exception e)
                    {
                        setInternalError!"m_dwFolders[ev.wd]"(Status.ERROR,
                                "Could not retrieve wd index in folders");
                        return 0;
                    }

                    dst[i] = DWChangeInfo(evtype, path);
                    import std.file : isDir;

                    bool is_dir;
                    try
                        is_dir = isDir(path.toNativeString());
                    catch (Throwable)
                    {
                    }
                    if (fi.wi.recursive && is_dir)
                    {

                        try
                        {
                            Array!DWChangeInfo changes;
                            recurseInto(fi, evtype, changes);
                            // stop watching if the folder was deleted
                            if (evtype == DWFileEvent.DELETED || evtype == DWFileEvent.MOVED_FROM)
                            {
                                unwatch(fi.fd, fi.wi.wd);
                            }
                            foreach (change; changes[])
                            {
                                i++;
                                if (dst.length <= i)
                                    dst ~= change;
                                else
                                    dst[i] = change;
                            }
                        }
                        catch (Exception e)
                        {
                            setInternalError!"recurseInto"(Status.ERROR,
                                    "Failed to watch/unwatch contents of folder recursively.");
                            return 0;
                        }

                    }

                    i++;
                    if (i >= dst.length)
                        return cast(uint) i;
                }
                static if (LOG)
                    foreach (j; 0 .. i)
                        {
                        static if (LOG)
                            try
                                log(
                                        "Change occured for FD#" ~ fd.to!string
                                        ~ ": " ~ dst[j].to!string);
                        catch
                        {
                        }
                    }
                nread = read(fd, buf.ptr, buf.sizeof);
                if (catchError!"read()"(nread))
                {
                    if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
                        m_status.code = Status.ASYNC;
                    return cast(uint) i;
                }
            }
            while (nread > 0);

            return cast(uint) i;
        }
        else /* if KQUEUE */
        {
            Array!(DWChangeInfo)* changes;
            size_t i;
            try
            {
                changes = m_changes[fd];
                import std.algorithm : min;

                size_t cnt = min(dst.length, changes.length);
                foreach (DWChangeInfo change; (*changes)[0 .. cnt])
                {
                    dst[i] = (*changes)[i];
                    i++;
                }
                changes.linearRemove((*changes)[0 .. cnt]);
            }
            catch (Exception e)
            {
                setInternalError!"watcher.readChanges"(Status.ERROR,
                        "Could not read directory changes: " ~ e.msg);
                return false;
            }
            return cast(uint) i;
        }
    }

    void submitRequest(AsyncAcceptRequest* request)
    {
        request.socket.m_pendingAccepts.insertBack(request);
        processPendingAccepts(request.socket);
    }

    void submitRequest(AsyncReceiveRequest* request)
    {
        request.socket.m_pendingReceives.insertBack(request);
        processPendingReceives(request.socket);
    }

    void submitRequest(AsyncSendRequest* request)
    {
        request.socket.m_pendingSends.insertBack(request);
        processPendingSends(request.socket);
    }

    bool broadcast(in fd_t fd, bool b)
    {
        m_status = StatusInfo.init;

        import libasync.internals.socket_compat : socklen_t, setsockopt,
            SO_BROADCAST, SOL_SOCKET;

        int val = b ? 1 : 0;
        socklen_t len = val.sizeof;
        int err = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &val, len);
        if (catchError!"setsockopt"(err))
            return false;

        return true;
    }

    private bool closeRemoteSocket(fd_t fd, bool forced)
    {

        int err;
        static if (LOG)
            log("shutdown");
        import libasync.internals.socket_compat : shutdown, SHUT_WR, SHUT_RDWR,
            SHUT_RD;

        if (forced)
            err = shutdown(fd, SHUT_RDWR);
        else
            err = shutdown(fd, SHUT_WR);

        static if (!EPOLL)
        {
            kevent_t[2] events;
            static if (LOG)
                try
                    log("!!DISC delete events");
            catch
            {
            }
            EV_SET(&(events[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
            EV_SET(&(events[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
            kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);
        }

        if (err == SOCKET_ERROR && errno == ENOTCONN)
        {
            // The socket has already been shut down, we can recover from that
        }
        else if (catchError!"shutdown"(err))
        {
            return false;
        }

        return true;
    }

    // for connected sockets
    bool closeSocket(fd_t fd, bool connected, bool forced = false)
    {
        static if (LOG)
            log("closeSocket");
        if (connected && !closeRemoteSocket(fd, forced) && !forced)
            return false;

        if (!connected || forced)
        {
            // todo: flush the socket here?

            import core.sys.posix.unistd : close;

            static if (LOG)
                log("close");
            int err = close(fd);
            if (catchError!"closesocket"(err))
                return false;
        }
        return true;
    }

    NetworkAddress getAddressFromIP(in string ipAddr, in ushort port = 0,
            in bool ipv6 = false, in bool tcp = true)
    {
        import libasync.internals.socket_compat : addrinfo, AI_NUMERICHOST,
            AI_NUMERICSERV;

        addrinfo hints;
        hints.ai_flags |= AI_NUMERICHOST | AI_NUMERICSERV; // Specific to an IP resolver!

        return getAddressInfo(ipAddr, port, ipv6, tcp, hints);
    }

    NetworkAddress getAddressFromDNS(in string host, in ushort port = 0,
            in bool ipv6 = true, in bool tcp = true) /*in {
		 debug import libasync.internals.validator : validateHost;
		 debug assert(validateHost(host), "Trying to connect to an invalid domain");
		 }
		body */
    {
        import libasync.internals.socket_compat : addrinfo;

        addrinfo hints;
        return getAddressInfo(host, port, ipv6, tcp, hints);
    }

    void setInternalError(string TRACE)(in Status s, string details = "",
            error_t error = cast(EPosix) errno())
    {
        if (details.length > 0)
            m_status.text = TRACE ~ ": " ~ details;
        else
            m_status.text = TRACE;
        m_error = error;
        m_status.code = s;
        static if (LOG)
            log(m_status);
    }

private:

    void processPendingAccepts(AsyncSocket socket)
    {
        if (socket.readBlocked)
            return;
        foreach (request; socket.m_pendingAccepts)
        {
            // Try to accept a single connection on the socket
            auto result = attemptConnectionAcceptance(socket);
            request.peer = result[0];
            request.family = result[1];

            if (status.code != Status.OK && !socket.readBlocked)
            {
                socket.kill();
                socket.handleError();
                return;
            }
            else if (request.peer != INVALID_SOCKET)
            {
                socket.m_pendingAccepts.removeFront();
                m_completedSocketAccepts.insertBack(request);
            }
            else
            {
                break;
            }
        }
    }

    void processPendingReceives(AsyncSocket socket)
    {
        if (socket.readBlocked)
            return;
        foreach (request; socket.m_pendingReceives)
        {
            // Try to fit all bytes available in the OS receive buffer
            // into the current request's message's buffer, or try a
            // a zero byte receive, should there be no such message.
            bool received = void;
            if (request.message)
                received = attemptMessageReception(socket, request.message);
            else
                received = attemptZeroByteReceive(socket);

            if (status.code != Status.OK && !socket.readBlocked)
            {
                if (received)
                    m_completedSocketReceives.insertBack(request);
                socket.kill();
                socket.handleError();
                return;
            }
            else if (request.exact)
            {
                if (request.message.receivedAll)
                {
                    socket.m_pendingReceives.removeFront();
                    m_completedSocketReceives.insertBack(request);
                }
                else
                {
                    break;
                }
                // New bytes or zero-sized connectionless datagram
            }
            else if (received || !socket.connectionOriented && !socket.readBlocked)
            {
                socket.m_pendingReceives.removeFront();
                m_completedSocketReceives.insertBack(request);
            }
            else
            {
                break;
            }
        }
    }

    void processPendingSends(AsyncSocket socket)
    {
        if (socket.writeBlocked)
            return;
        foreach (request; socket.m_pendingSends)
        {
            // Try to fit all bytes of the current request's buffer
            // into the OS send buffer.
            auto sent = attemptMessageTransmission(socket, request.message);

            if (status.code != Status.OK && !socket.writeBlocked)
            {
                socket.kill();
                socket.handleError();
                return;
            }
            else if (sent)
            {
                socket.m_pendingSends.removeFront();
                m_completedSocketSends.insertBack(request);
            }
            else
            {
                break;
            }
        }
    }

    auto attemptConnectionAcceptance(AsyncSocket socket)
    {
        import core.sys.posix.fcntl : O_NONBLOCK;
        import libasync.internals.socket_compat : accept, accept4,
            sockaddr_storage, socklen_t;

        fd_t peer = void;
        sockaddr_storage remote = void;
        socklen_t remoteLength = remote.sizeof;

        enum common = q{
			if (peer == SOCKET_ERROR) {
				m_error = lastError();

				if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN) {
					m_status.code = Status.ASYNC;
					socket.readBlocked = true;
					return tuple(INVALID_SOCKET, sockaddr.sa_family.init);
				} else if (m_error == EBADF ||
				           m_error == EINTR ||
				           m_error == EINVAL ||
				           m_error == ENOTSOCK ||
				           m_error == EOPNOTSUPP ||
				           m_error == EFAULT) {
					assert(false, "accept{4} system call on FD " ~ socket.handle.to!string ~ " encountered fatal socket error: " ~ this.error);
				} else if (catchError!"accept"(peer)) {
					.errorf("accept{4} system call on FD %d encountered socket error: %s", socket.handle, this.error);
					return tuple(INVALID_SOCKET, sockaddr.sa_family.init);
				}
			}
		};

        version (linux)
        {
            peer = accept4(socket.handle, cast(sockaddr*)&remote, &remoteLength, O_NONBLOCK);
            mixin(common);
        }
        else
        {
            peer = accept(socket.handle, cast(sockaddr*)&remote, &remoteLength);
            mixin(common);
            if (!setNonBlock(peer))
            {
                .error("Failed to set accepted peer socket non-blocking");
                return tuple(INVALID_SOCKET, sockaddr.sa_family.init);
            }
        }

        return tuple(peer, remote.ss_family);
    }

    bool attemptZeroByteReceive(AsyncSocket socket)
    {
        import libasync.internals.socket_compat : recv, MSG_PEEK;

        ubyte buffer = void;
        auto fd = socket.handle;

        while (true)
        {
            auto err = recv(fd, &buffer, 1, MSG_PEEK);

            .tracef("recv system call on FD %d returned %d", fd, err);
            if (err == SOCKET_ERROR)
            {
                m_error = lastError();

                if (m_error == EPosix.EINTR)
                {
                    .tracef("recv system call on FD %d was interrupted before any transfer occured",
                            fd);
                    continue;
                }
                else if (m_error == EPosix.EWOULDBLOCK || m_error == EPosix.EAGAIN)
                {
                    .tracef("recv system call on FD %d would have blocked", fd);
                    m_status.code = Status.ASYNC;
                    socket.readBlocked = true;
                    return false;
                }
                else if (m_error == EBADF || m_error == EFAULT
                        || m_error == EINVAL || m_error == ENOTCONN || m_error == ENOTSOCK)
                {
                    .errorf("recv system call on FD %d encountered fatal socket error: %s",
                            fd, this.error);
                    assert(false);
                }
                else if (catchError!"Receive message"(err))
                {
                    .errorf("recv system call on FD %d encountered socket error: %s",
                            fd, this.error);
                    return false;
                }
            }
            else
            {
                .tracef("Received %d bytes on FD %d", err, fd);
                m_status.code = Status.OK;
                if (socket.connectionOriented && !err)
                {
                    socket.readBlocked = true;
                }
                return err > 0;
            }
        }
    }

    /**
	 * Appends as much of the bytes currently available in the OS receive
	 * buffer to the given message's transferred bytes as the message's
	 * buffer's remaining free bytes and the state of the OS receive buffer
	 * allow for, advancing the message's count of transferred bytes in the process.
	 * Sets $(D readBlocked) on indication by the OS that there were
	 * not enough bytes available in the OS receive buffer.
	 * Returns: $(D true) if any bytes were transferred.
	 */
    bool attemptMessageReception(AsyncSocket socket, NetworkMessage* msg)
    in
    {
        assert(socket.connectionOriented && !msg.receivedAll
                || !msg.receivedAny, "Message already received");
    }
    body
    {
        bool received;
        size_t recvCount = void;

        if (socket.datagramOriented)
        {
            recvCount = recvMsg(socket.handle, msg);
            msg.count = msg.count + recvCount;
            received = received || recvCount > 0;
        }
        else
            do
            {
                recvCount = recvMsg(socket.handle, msg);
                msg.count = msg.count + recvCount;
                received = received || recvCount > 0;
            }
        while (recvCount > 0 && !msg.receivedAll);

        // More bytes may yet become available in the future
        if (status.code == Status.ASYNC)
        {
            socket.readBlocked = true;
            // Connection was shutdown in an orderly fashion by the remote peer
        }
        else if (socket.connectionOriented && status.code == Status.OK && !recvCount)
        {
            socket.readBlocked = true;
        }

        return received;
    }

    /**
	 * Transfers as much of the given message's untransferred bytes
	 * into the OS send buffer as the latter's state allows for,
	 * advancing the message's count of transferred bytes in the process.
	 * Sets $(DDOC_MEMBERS writeBlocked) on indication by the OS that
	 * there was not enough space available in the OS send buffer.
	 * Returns: $(D true) if all of the message's bytes
	 *          have been transferred.
	 */
    bool attemptMessageTransmission(AsyncSocket socket, NetworkMessage* msg)
    in
    {
        assert(!msg.sent, "Message already sent");
    }
    body
    {
        size_t sentCount = void;

        do
        {
            sentCount = sendMsg(socket.handle, msg);
            msg.count = msg.count + sentCount;
        }
        while (sentCount > 0 && !msg.sent);

        if (status.code == Status.ASYNC)
        {
            socket.writeBlocked = true;
        }

        return msg.sent;
    }

    /// For DirectoryWatcher
    /// In kqueue/vnode, all we get is the folder in which changes occured.
    /// We have to figure out what changed exactly and put the results in a container
    /// for the readChanges call.
    static if (!EPOLL)
        bool compareFolderFiles(DWFolderInfo fi, DWFileEvent events)
        {
            import std.file;
            import std.path : buildPath;

            try
            {
                Array!Path currFiles;
                auto wd = fi.wi.wd;
                auto path = fi.wi.path;
                auto fd = fi.fd;
                Array!(DWChangeInfo)* changes = m_changes.get(fd, null);
                assert(changes !is null, "Invalid wd, could not find changes array.");
                //import std.stdio : writeln;
                //writeln("Scanning path: ", path.toNativeString());
                //writeln("m_dwFiles length: ", m_dwFiles.length);

                // get a list of the folder
                foreach (de; dirEntries(path.toNativeString(), SpanMode.shallow))
                    {
                    //writeln(de.name);
                    Path entryPath = Path(de.name);
                    if (!entryPath.absolute)
                        entryPath = path ~ entryPath;
                    bool found;

                    if (!de.isDir())
                        {
                        // compare it to the cached list fixme: make it faster using another container?
                        foreach (ref const fd_t id, ref const DWFileInfo file; m_dwFiles)
                            {
                            if (file.folder != wd)
                                continue; // this file isn't in the evented folder
                            if (file.path == entryPath)
                                {
                                found = true;
                                static if (LOG)
                                    log("File modified? " ~ entryPath.toNativeString() ~ " at: "
                                            ~ de.timeLastModified.to!string
                                            ~ " vs: " ~ file.lastModified.to!string);
                                // Check if it was modified
                                if (!isDir(entryPath.toNativeString())
                                        && de.timeLastModified > file.lastModified)
                                    {
                                    DWFileInfo dwf = file;
                                    dwf.lastModified = de.timeLastModified;
                                    m_dwFiles[id] = dwf;
                                    changes.insertBack(DWChangeInfo(DWFileEvent.MODIFIED,
                                            file.path));
                                }
                                break;
                            }
                        }
                    }
                    else
                        {
                        foreach (ref const DWFolderInfo folder; m_dwFolders)
                            {
                            if (folder.wi.path == entryPath)
                                {
                                found = true;
                                break;
                            }
                        }
                    }

                    // This file/folder is new in the folder
                    if (!found)
                        {
                        changes.insertBack(DWChangeInfo(DWFileEvent.CREATED, entryPath));

                        if (fi.wi.recursive && de.isDir())
                            {
                            /// This is the complicated part. The folder needs to be watched, and all the events
                            /// generated for every file/folder found recursively inside it,
                            /// Useful e.g. when mkdir -p is used.
                            watch(fd, WatchInfo(fi.wi.events, entryPath, fi.wi.recursive, wd));
                            void genEvents(Path subpath)
                            {
                                foreach (de; dirEntries(subpath.toNativeString(), SpanMode.shallow))
                                    {
                                    auto subsubpath = Path(de.name);
                                    if (!subsubpath.absolute())
                                        subsubpath = subpath ~ subsubpath;
                                    changes.insertBack(DWChangeInfo(DWFileEvent.CREATED,
                                            subsubpath));
                                    if (isDir(subsubpath.toNativeString()))
                                        genEvents(subsubpath);
                                }
                            }

                            genEvents(entryPath);

                        }
                        else
                            {
                            EventInfo* evinfo;
                            try
                            {
                                evinfo = m_watchers[fd];
                            }
                            catch (Exception e)
                                {
                                assert(false, "Could retrieve event info, directory watcher was not initialized properly, or you are operating on a closed directory watcher.");
                            }

                            static if (LOG)
                                log("Adding path: " ~ path.toNativeString());

                            import core.sys.posix.fcntl : open;

                            fd_t fwd = open(entryPath.toNativeString().toStringz, O_EVTONLY);
                            if (catchError!"open(watch)"(fwd))
                                return 0;

                            kevent_t _event;

                            EV_SET(&_event, fwd, EVFILT_VNODE, EV_ADD | EV_CLEAR,
                                    fi.wi.events, 0, cast(void*) evinfo);

                            int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);

                            if (catchError!"kevent_timer_add"(err))
                                return 0;

                            m_dwFiles[fwd] = DWFileInfo(fi.wi.wd, entryPath,
                                    de.timeLastModified, false);

                        }
                    }

                    // This file/folder is now current. This avoids a deletion event.
                    currFiles.insert(entryPath);
                }

                /// Now search for files/folders that were deleted in this directory (no recursivity needed).
                /// Unwatch this directory and generate delete event only for the root dir
                foreach (ref const fd_t id, ref const DWFileInfo file; m_dwFiles)
                    {
                    if (file.folder != wd)
                        continue; // skip those files in another folder than the evented one
                    bool found;
                    foreach (Path curr; currFiles)
                        {
                        if (file.path == curr)
                            {
                            found = true;
                            break;
                        }
                    }
                    // this file/folder was in the folder but it's not there anymore
                    if (!found)
                        {
                        // writeln("Deleting: ", file.path.toNativeString());
                        kevent_t _event;
                        EV_SET(&_event, cast(int) id, EVFILT_VNODE, EV_DELETE, 0, 0, null);
                        int err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
                        if (catchError!"kevent_unwatch"(err))
                            return false;
                        import core.sys.posix.unistd : close;

                        err = close(id);
                        if (catchError!"close(dwFile)"(err))
                            return false;
                        changes.insert(DWChangeInfo(DWFileEvent.DELETED, file.path));

                        if (fi.wi.recursive && file.is_dir)
                            unwatch(fd, id);

                        m_dwFiles.remove(id);

                    }

                }
                if (changes.empty)
                    return false; // unhandled event, skip the callback

                // fixme: how to implement moved_from moved_to for rename?
            }
            catch (Exception e)
                {
                try
                    setInternalError!"compareFiles"(Status.ERROR,
                            "Fatal error in file comparison: " ~ e.toString());
                catch (Exception e)
                {
                }
                return false;
            }
            return true;
        }

    // socket must not be connected
    bool setNonBlock(fd_t fd)
    {
        import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;

        int flags = fcntl(fd, F_GETFL);
        flags |= O_NONBLOCK;
        int err = fcntl(fd, F_SETFL, flags);
        if (catchError!"F_SETFL O_NONBLOCK"(err))
        {
            closeSocket(fd, false);
            return false;
        }
        return true;
    }

    bool onTCPAccept(fd_t fd, TCPAcceptHandler del, int events)
    {
        import libasync.internals.socket_compat : AF_INET, AF_INET6, socklen_t,
            accept4, accept;

        enum O_NONBLOCK = 0x800; // octal    04000

        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool incoming = cast(bool)(epoll_events & EPOLLIN);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool incoming = cast(bool)(kqueue_events & EVFILT_READ);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
        }

        if (incoming)
        { // accept incoming connection
            do
            {
                NetworkAddress addr;
                addr.family = AF_INET;
                socklen_t addrlen = addr.sockAddrLen;

                bool ret;
                static if (EPOLL)
                {
                    /// Accept the connection and create a client socket
                    fd_t csock = accept4(fd, addr.sockAddr, &addrlen, O_NONBLOCK);

                    if (catchError!".accept"(csock))
                    {
                        return true; // this way we know there's nothing left to accept
                    }
                }
                else /* if KQUEUE */
                {
                    fd_t csock = accept(fd, addr.sockAddr, &addrlen);

                    if (catchError!".accept"(csock))
                    {
                        return true;
                    }

                    // Make non-blocking so subsequent calls to recv/send return immediately
                    if (!setNonBlock(csock))
                    {
                        continue;
                    }
                }

                // Set client address family based on address length
                if (addrlen > addr.sockAddrLen)
                    addr.family = AF_INET6;
                if (addrlen == socklen_t.init)
                {
                    setInternalError!"addrlen"(Status.ABORT);
                    import core.sys.posix.unistd : close;

                    close(csock);
                    continue;
                }

                // Allocate a new connection handler object
                AsyncTCPConnection conn;
                try
                    conn = ThreadMem.alloc!AsyncTCPConnection(m_evLoop);
                catch (Exception e)
                {
                    assert(false, "Allocation failure");
                }
                conn.peer = addr;
                conn.socket = csock;
                conn.inbound = true;

                nothrow void closeClient()
                {
                    try
                        ThreadMem.free(conn);
                    catch (Exception e)
                    {
                        assert(false, "Free failure");
                    }
                    closeSocket(csock, true, true);
                }

                // Get the connection handler from the callback
                TCPEventHandler evh;
                try
                {
                    evh = del(conn);
                    if (evh == TCPEventHandler.init || !initTCPConnection(csock, conn, evh, true))
                    {
                        static if (LOG)
                            try
                                log("Failed to connect");
                        catch
                        {
                        }
                        closeClient();
                        continue;
                    }
                    static if (LOG)
                        try
                            log("Connection Started with " ~ csock.to!string);
                    catch
                    {
                    }
                }
                catch (Exception e)
                {
                    static if (LOG)
                        log("Close socket");
                    closeClient();
                    continue;
                }

                // Announce connection state to the connection handler
                try
                {
                    static if (LOG)
                        log("Connected to: " ~ addr.toString());
                    evh.conn.connected = true;
                    evh(TCPEvent.CONNECT);
                }
                catch (Exception e)
                {
                    closeClient();
                    setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
                }
                /*if (m_status.code == Status.ABORT)
				{
					try evh(TCPEvent.ERROR);
					catch {}
				}*/
            }
            while (true);

        }

        if (error)
        { // socket failure
            m_status.text = "listen socket error";
            int err;
            import libasync.internals.socket_compat : getsockopt, socklen_t,
                SOL_SOCKET, SO_ERROR;

            socklen_t len = int.sizeof;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
            m_error = cast(error_t) err;
            m_status.code = Status.ABORT;
            static if (LOG)
                log(m_status);

            // call with null to announce a failure
            try
                del(null);
            catch (Exception e)
            {
                assert(false, "Failure calling TCPAcceptHandler(null)");
            }

            /// close the listener?
            // closeSocket(fd, false);
        }
        return true;
    }

    bool onUDPTraffic(fd_t fd, UDPHandler del, int events)
    {
        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool read = cast(bool)(epoll_events & EPOLLIN);
            const bool write = cast(bool)(epoll_events & EPOLLOUT);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool read = cast(bool)(kqueue_events & EVFILT_READ);
            const bool write = cast(bool)(kqueue_events & EVFILT_WRITE);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
        }

        if (read)
        {
            try
            {
                del(UDPEvent.READ);
            }
            catch (Exception e)
            {
                setInternalError!"del@UDPEvent.READ"(Status.ABORT);
                return false;
            }
        }

        if (write)
        {

            try
            {
                del(UDPEvent.WRITE);
            }
            catch (Exception e)
            {
                setInternalError!"del@UDPEvent.WRITE"(Status.ABORT);
                return false;
            }
        }

        if (error) // socket failure
        {

            import libasync.internals.socket_compat : socklen_t, getsockopt,
                SOL_SOCKET, SO_ERROR;
            import core.sys.posix.unistd : close;

            int err;
            socklen_t errlen = err.sizeof;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen);
            setInternalError!"EPOLLERR"(Status.ABORT, null, cast(error_t) err);
            close(fd);
            return false;
        }

        return true;
    }

    bool onEvent(fd_t fd, EventHandler del, int events)
    {
        bool connect = void, close = void;
        auto conn = del.ev;

        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool read = cast(bool)(epoll_events & EPOLLIN);
            const bool write = cast(bool)(epoll_events & EPOLLOUT);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
            if (conn.stateful)
            {
                connect = ((cast(bool)(epoll_events & EPOLLIN))
                        || (cast(bool)(epoll_events & EPOLLOUT)))
                    && !conn.disconnecting && !conn.connected;
                close = (cast(bool)(epoll_events & EPOLLRDHUP)) || (cast(bool)(events & EPOLLHUP));
            }
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool read = cast(bool)(kqueue_events & EVFILT_READ);
            const bool write = cast(bool)(kqueue_events & EVFILT_WRITE);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
            if (conn.stateful)
            {
                connect = cast(bool)((kqueue_events & EVFILT_READ
                        || kqueue_events & EVFILT_WRITE) && !conn.disconnecting && !conn.connected);
                close = cast(bool)(kqueue_flags & EV_EOF);
            }
        }

        if (write && (!conn.stateful || conn.connected && !conn.disconnecting && conn.writeBlocked))
        {
            if (conn.stateful)
                conn.writeBlocked = false;
            static if (LOG)
                try
                    log("!write");
            catch
            {
            }
            try
            {
                del(EventCode.WRITE);
            }
            catch (Exception e)
            {
                setInternalError!"del@Event.WRITE"(Status.ABORT);
                return false;
            }
        }

        if (read && (!conn.stateful || conn.connected && !conn.disconnecting))
        {
            static if (LOG)
                try
                    log("!read");
            catch
            {
            }
            try
            {
                del(EventCode.READ);
            }
            catch (Exception e)
            {
                setInternalError!"del@Event.READ"(Status.ABORT);
                return false;
            }
        }

        if (conn.stateful && close && conn.connected && !conn.disconnecting)
        {
            static if (LOG)
                try
                    log("!close");
            catch
            {
            }
            // todo: See if this hack is still necessary
            if (!conn.connected && conn.disconnecting)
                return true;

            try
                del(EventCode.CLOSE);
            catch (Exception e)
            {
                setInternalError!"del@Event.CLOSE"(Status.ABORT);
                return false;
            }

            // Careful here, the delegate might have closed the connection already
            if (conn.connected)
            {
                closeSocket(fd, !conn.disconnecting, conn.connected);

                m_status.code = Status.ABORT;
                conn.disconnecting = true;
                conn.connected = false;
                conn.writeBlocked = true;
                conn.id = 0;

                try
                    ThreadMem.free(conn.evInfo);
                catch (Exception e)
                {
                    assert(false, "Error freeing resources");
                }
            }
            return true;
        }

        if (error) // failure
        {
            setInternalError!"EPOLLERR"(Status.ABORT, null);
            try
            {
                del(EventCode.ERROR);
            }
            catch (Exception e)
            {
                setInternalError!"del@Event.ERROR"(Status.ABORT);
                // ignore failure...
            }
            return false;
        }

        if (conn.stateful && connect)
        {
            static if (LOG)
                try
                    log("!connect");
            catch
            {
            }
            conn.connected = true;
            try
                del(EventCode.CONNECT);
            catch (Exception e)
            {
                setInternalError!"del@Event.CONNECT"(Status.ABORT);
                return false;
            }
            return true;
        }

        return true;
    }

    /// Handle an event for a connectionless socket
    bool onCLSocketEvent(AsyncSocket socket, int events)
    {
        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool read = cast(bool)(epoll_events & EPOLLIN);
            const bool write = cast(bool)(epoll_events & EPOLLOUT);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool read = cast(bool)(kqueue_events & EVFILT_READ);
            const bool write = cast(bool)(kqueue_events & EVFILT_WRITE);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
        }

        if (read)
        {
            tracef("Read on FD %d", socket.handle);

            socket.readBlocked = false;
            processPendingReceives(socket);
        }

        if (write)
        {
            tracef("Write on FD %d", socket.handle);

            socket.writeBlocked = false;
            processPendingSends(socket);
        }

        if (error)
        {
            tracef("Error on FD %d", socket.handle);

            auto err = cast(error_t) socket.lastError;
            setInternalError!"AsyncSocket.ERROR"(Status.ABORT, null, cast(error_t) err);
            socket.kill();
            socket.handleError();
            return false;
        }

        return true;
    }

    /// Handle an event for a connection-oriented, active socket
    bool onCOASocketEvent(AsyncSocket socket, int events)
    {
        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            bool read = cast(bool)(epoll_events & EPOLLIN);
            bool write = cast(bool)(epoll_events & EPOLLOUT);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
            const bool connect = ((cast(bool)(epoll_events & EPOLLIN))
                    || (cast(bool)(epoll_events & EPOLLOUT)))
                && !socket.disconnecting && !socket.connected;
            const bool close = (cast(bool)(epoll_events & EPOLLRDHUP))
                || (cast(bool)(events & EPOLLHUP));
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            bool read = cast(bool)(kqueue_events & EVFILT_READ);
            bool write = cast(bool)(kqueue_events & EVFILT_WRITE);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
            const bool connect = cast(bool)((kqueue_events & EVFILT_READ
                    || kqueue_events & EVFILT_WRITE) && !socket.disconnecting && !socket.connected);
            const bool close = cast(bool)(kqueue_flags & EV_EOF);
        }

        tracef("AsyncSocket events: (read: %s, write: %s, error: %s, connect: %s, close: %s)",
                read, write, error, connect, close);

        if (error)
        {
            tracef("Error on FD %d", socket.handle);

            auto err = cast(error_t) socket.lastError;
            if (err == ECONNRESET || err == EPIPE)
            {
                socket.kill();
                socket.handleClose();
                return true;
            }

            setInternalError!"AsyncSocket.ERROR"(Status.ABORT, null, cast(error_t) err);
            socket.kill();
            socket.handleError();
            return false;
        }

        if (connect)
        {
            tracef("Connect on FD %d", socket.handle);

            socket.connected = true;
            socket.readBlocked = false;
            socket.writeBlocked = false;
            socket.handleConnect();
            read = false;
            write = false;
        }

        if (( /+read ||+/ write) && socket.connected && !socket.disconnecting && socket
                .writeBlocked)
        {
            tracef("Write on FD %d", socket.handle);

            socket.writeBlocked = false;
            processPendingSends(socket);
        } /+ else {
			read = true;
		}+/

        if (read && socket.connected && !socket.disconnecting && socket.readBlocked)
        {
            tracef("Read on FD %d", socket.handle);

            socket.readBlocked = false;
            processPendingReceives(socket);
        }

        if (close && socket.connected && !socket.disconnecting)
        {
            tracef("Close on FD %d", socket.handle);
            socket.kill();
            socket.handleClose();
            return true;
        }

        return true;
    }

    /// Handle an event for a connection-oriented, passive socket
    bool onCOPSocketEvent(AsyncSocket socket, int events)
    {
        import core.sys.posix.fcntl : O_NONBLOCK;
        import libasync.internals.socket_compat : accept, accept4, sockaddr,
            socklen_t;

        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool incoming = cast(bool)(epoll_events & EPOLLIN);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
        }
        else
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool incoming = cast(bool)(kqueue_events & EVFILT_READ);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
        }

        tracef("AsyncSocket events: (incoming: %s, error: %s)", incoming, error);

        if (incoming)
        {
            tracef("Incoming on FD %d", socket.handle);

            socket.readBlocked = false;
            processPendingAccepts(socket);
        }

        if (error)
        {
            tracef("Error on FD %d", socket.handle);

            auto err = cast(error_t) socket.lastError;
            setInternalError!"AsyncSocket.ERROR"(Status.ABORT, null, cast(error_t) err);
            socket.kill();
            socket.handleError();
            return false;
        }

        return true;
    }

    bool onTCPTraffic(fd_t fd, TCPEventHandler del, int events, AsyncTCPConnection conn)
    {
        //log("TCP Traffic at FD#" ~ fd.to!string);

        static if (EPOLL)
        {
            const uint epoll_events = cast(uint) events;
            const bool connect = ((cast(bool)(epoll_events & EPOLLIN))
                    || (cast(bool)(epoll_events & EPOLLOUT)))
                && !conn.disconnecting && !conn.connected;
            bool read = cast(bool)(epoll_events & EPOLLIN);
            const bool write = cast(bool)(epoll_events & EPOLLOUT);
            const bool error = cast(bool)(epoll_events & EPOLLERR);
            const bool close = (cast(bool)(epoll_events & EPOLLRDHUP))
                || (cast(bool)(events & EPOLLHUP));
        }
        else /* if KQUEUE */
        {
            const short kqueue_events = cast(short)(events >> 16);
            const ushort kqueue_flags = cast(ushort)(events & 0xffff);
            const bool connect = cast(bool)((kqueue_events & EVFILT_READ
                    || kqueue_events & EVFILT_WRITE) && !conn.disconnecting && !conn.connected);
            bool read = cast(bool)(kqueue_events & EVFILT_READ) && !connect;
            const bool write = cast(bool)(kqueue_events & EVFILT_WRITE);
            const bool error = cast(bool)(kqueue_flags & EV_ERROR);
            const bool close = cast(bool)(kqueue_flags & EV_EOF);
        }

        if (error)
        {
            import libasync.internals.socket_compat : socklen_t, getsockopt,
                SOL_SOCKET, SO_ERROR;

            int err;
            static if (LOG)
                try
                    log("Also got events: " ~ connect.to!string ~ " c "
                            ~ read.to!string ~ " r " ~ write.to!string ~ " write");
            catch
            {
            }
            socklen_t errlen = err.sizeof;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &errlen);
            setInternalError!"EPOLLERR"(Status.ABORT, null, cast(error_t) err);
            try
                del(TCPEvent.ERROR);
            catch (Exception e)
            {
                setInternalError!"del@TCPEvent.ERROR"(Status.ABORT);
                // ignore failure...
            }
            return false;
        }

        if (connect)
        {
            static if (LOG)
                try
                    log("!connect");
            catch
            {
            }
            conn.connected = true;
            try
                del(TCPEvent.CONNECT);
            catch (Exception e)
            {
                setInternalError!"del@TCPEvent.CONNECT"(Status.ABORT);
                return false;
            }
            return true;
        }

        if ((read || write) && conn.connected && !conn.disconnecting && conn.writeBlocked)
        {
            conn.writeBlocked = false;
            static if (LOG)
                try
                    log("!write");
            catch
            {
            }
            try
                del(TCPEvent.WRITE);
            catch (Exception e)
            {
                setInternalError!"del@TCPEvent.WRITE"(Status.ABORT);
                return false;
            }
        }
        else
        {
            read = true;
        }

        if (read && conn.connected && !conn.disconnecting)
        {
            static if (LOG)
                try
                    log("!read");
            catch
            {
            }
            try
                del(TCPEvent.READ);
            catch (Exception e)
            {
                setInternalError!"del@TCPEvent.READ"(Status.ABORT);
                return false;
            }
        }

        if (close && conn.connected && !conn.disconnecting)
        {
            static if (LOG)
                try
                    log("!close");
            catch
            {
            }
            // todo: See if this hack is still necessary
            if (!conn.connected && conn.disconnecting)
                return true;

            try
                del(TCPEvent.CLOSE);
            catch (Exception e)
            {
                setInternalError!"del@TCPEvent.CLOSE"(Status.ABORT);
                return false;
            }

            // Careful here, the delegate might have closed the connection already
            if (conn.connected)
            {
                closeSocket(fd, !conn.disconnecting, conn.connected);

                m_status.code = Status.ABORT;
                conn.disconnecting = true;
                conn.connected = false;
                conn.writeBlocked = true;
                del.conn.socket = 0;

                try
                    ThreadMem.free(del.conn.evInfo);
                catch (Exception e)
                {
                    assert(false, "Error freeing resources");
                }

                if (del.conn.inbound)
                {
                    static if (LOG)
                        log("Freeing inbound connection");
                    try
                        ThreadMem.free(del.conn);
                    catch (Exception e)
                    {
                        assert(false, "Error freeing resources");
                    }
                }
            }
        }
        return true;
    }

    bool initUDPSocket(fd_t fd, AsyncUDPSocket ctxt, UDPHandler del)
    {
        import libasync.internals.socket_compat : bind;
        import core.sys.posix.unistd;

        fd_t err;

        EventObject eo;
        eo.udpHandler = del;
        EventInfo* ev;
        try
            ev = ThreadMem.alloc!EventInfo(fd, EventType.UDPSocket, eo, m_instanceId);
        catch (Exception e)
        {
            assert(false, "Allocation error");
        }
        ctxt.evInfo = ev;
        nothrow bool closeAll()
        {
            try
                ThreadMem.free(ev);
            catch (Exception e)
            {
                assert(false, "Failed to free resources");
            }
            ctxt.evInfo = null;
            // socket will be closed by caller if return false
            return false;
        }

        static if (EPOLL)
        {
            epoll_event _event;
            _event.data.ptr = ev;
            _event.events = EPOLLIN | EPOLLOUT | EPOLLET;
            err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
            if (catchError!"epoll_ctl"(err))
            {
                return closeAll();
            }
            nothrow void deregisterEvent()
            {
                epoll_ctl(m_epollfd, EPOLL_CTL_DEL, fd, &_event);
            }
        }
        else /* if KQUEUE */
        {
            kevent_t[2] _event;
            EV_SET(&(_event[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, ev);
            EV_SET(&(_event[1]), fd, EVFILT_WRITE, EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, ev);
            err = kevent(m_kqueuefd, &(_event[0]), 2, null, 0, null);
            if (catchError!"kevent_add_udp"(err))
                return closeAll();

            nothrow void deregisterEvent()
            {
                EV_SET(&(_event[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
                EV_SET(&(_event[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
                kevent(m_kqueuefd, &(_event[0]), 2, null, 0,
                        cast(libasync.internals.kqueue.timespec*) null);
            }

        }

        /// Start accepting packets
        err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
        if (catchError!"bind"(err))
        {
            deregisterEvent();
            return closeAll();
        }

        return true;
    }

    bool initTCPListener(fd_t fd, AsyncTCPListener ctxt, TCPAcceptHandler del, bool reusing = false)
    in
    {
        assert(ctxt.local !is NetworkAddress.init);
    }
    body
    {
        import libasync.internals.socket_compat : bind, listen, SOMAXCONN;

        fd_t err;

        /// Create callback object
        EventObject eo;
        eo.tcpAcceptHandler = del;
        EventInfo* ev;

        try
            ev = ThreadMem.alloc!EventInfo(fd, EventType.TCPAccept, eo, m_instanceId);
        catch (Exception e)
        {
            assert(false, "Allocation error");
        }
        ctxt.evInfo = ev;
        nothrow bool closeAll()
        {
            try
                ThreadMem.free(ev);
            catch (Exception e)
            {
                assert(false, "Failed free");
            }
            ctxt.evInfo = null;
            // Socket is closed by run()
            //closeSocket(fd, false);
            return false;
        }

        /// Add socket to event loop
        static if (EPOLL)
        {
            epoll_event _event;
            _event.data.ptr = ev;
            _event.events = EPOLLIN | EPOLLET;
            err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
            if (catchError!"epoll_ctl_add"(err))
                return closeAll();

            nothrow void deregisterEvent()
            {
                // epoll cleans itself when closing the socket
            }
        }
        else /* if KQUEUE */
        {
            kevent_t _event;
            EV_SET(&_event, fd, EVFILT_READ, EV_ADD | EV_ENABLE, 0, 0, ev);
            err = kevent(m_kqueuefd, &_event, 1, null, 0, null);
            if (catchError!"kevent_add_listener"(err))
                return closeAll();

            nothrow void deregisterEvent()
            {
                EV_SET(&_event, fd, EVFILT_READ, EV_CLEAR | EV_DISABLE, 0, 0, null);
                kevent(m_kqueuefd, &_event, 1, null, 0, null);
                // wouldn't know how to deal with errors here...
            }
        }

        /// Bind and listen to socket
        if (!reusing)
        {
            err = bind(fd, ctxt.local.sockAddr, ctxt.local.sockAddrLen);
            if (catchError!"bind"(err))
            {
                deregisterEvent();
                return closeAll();
            }

            err = listen(fd, SOMAXCONN);
            if (catchError!"listen"(err))
            {
                deregisterEvent();
                return closeAll();
            }

        }
        return true;
    }

    bool initTCPConnection(fd_t fd, AsyncTCPConnection ctxt,
            TCPEventHandler del, bool inbound = false)
    in
    {
        assert(ctxt.peer.port != 0, "Connecting to an invalid port");
    }
    body
    {

        fd_t err;

        /// Create callback object
        import libasync.internals.socket_compat : connect;

        EventObject eo;
        eo.tcpEvHandler = del;
        EventInfo* ev;

        try
            ev = ThreadMem.alloc!EventInfo(fd, EventType.TCPTraffic, eo, m_instanceId);
        catch (Exception e)
        {
            assert(false, "Allocation error");
        }
        assert(ev !is null);
        ctxt.evInfo = ev;
        nothrow bool destroyEvInfo()
        {
            try
                ThreadMem.free(ev);
            catch (Exception e)
            {
                assert(false, "Failed to free resources");
            }
            ctxt.evInfo = null;

            // Socket will be closed by run()
            // closeSocket(fd, false);
            return false;
        }

        /// Add socket and callback object to event loop
        static if (EPOLL)
        {
            epoll_event _event = void;
            _event.data.ptr = ev;
            _event.events = 0 | EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP | EPOLLRDHUP | EPOLLET;
            err = epoll_ctl(m_epollfd, EPOLL_CTL_ADD, fd, &_event);
            static if (LOG)
                log("Connection FD#" ~ fd.to!string ~ " added to " ~ m_epollfd.to!string);
            if (catchError!"epoll_ctl_add"(err))
                return destroyEvInfo();

            nothrow void deregisterEvent()
            {
                // will be handled automatically when socket is closed
            }
        }
        else /* if KQUEUE */
        {
            kevent_t[2] events = void;
            static if (LOG)
                try
                    log("Register event ptr " ~ ev.to!string);
            catch
            {
            }
            assert(ev.evType == EventType.TCPTraffic, "Bad event type for TCP Connection");
            EV_SET(&(events[0]), fd, EVFILT_READ, EV_ADD | EV_ENABLE | EV_CLEAR,
                    0, 0, cast(void*) ev);
            EV_SET(&(events[1]), fd, EVFILT_WRITE,
                    EV_ADD | EV_ENABLE | EV_CLEAR, 0, 0, cast(void*) ev);
            assert((cast(EventInfo*) events[0].udata) == ev
                    && (cast(EventInfo*) events[1].udata) == ev);
            assert((cast(EventInfo*) events[0].udata).owner == m_instanceId
                    && (cast(EventInfo*) events[1].udata).owner == m_instanceId);
            err = kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);
            if (catchError!"kevent_add_tcp"(err))
                return destroyEvInfo();

            // todo: verify if this allocates on the GC?
            nothrow void deregisterEvent()
            {
                EV_SET(&(events[0]), fd, EVFILT_READ, EV_DELETE | EV_DISABLE, 0, 0, null);
                EV_SET(&(events[1]), fd, EVFILT_WRITE, EV_DELETE | EV_DISABLE, 0, 0, null);
                kevent(m_kqueuefd, &(events[0]), 2, null, 0, null);
                // wouldn't know how to deal with errors here...
            }
        }

        // Inbound objects are already connected
        if (inbound)
            return true;

        // Connect is blocking, but this makes the socket non-blocking for send/recv
        if (!setNonBlock(fd))
        {
            deregisterEvent();
            return destroyEvInfo();
        }

        /// Start the connection
        err = connect(fd, ctxt.peer.sockAddr, ctxt.peer.sockAddrLen);
        if (catchErrorsEq!"connect"(err, [tuple(cast(fd_t) SOCKET_ERROR,
                EPosix.EINPROGRESS, Status.ASYNC)]))
            return true;
        if (catchError!"connect"(err))
        {
            deregisterEvent();
            return destroyEvInfo();
        }

        return true;
    }

    pragma(inline, true) bool catchError(string TRACE, T)(T val, T cmp = SOCKET_ERROR)
            if (isIntegral!T)
    {
        if (val == cmp)
        {
            m_status.text = TRACE;
            m_error = lastError();
            m_status.code = Status.ABORT;
            static if (LOG)
                log(m_status);
            return true;
        }
        return false;
    }

    pragma(inline, true) bool catchSocketError(string TRACE)(fd_t fd)
    {
        m_status.text = TRACE;
        int err;
        import libasync.internals.socket_compat : getsockopt, socklen_t,
            SOL_SOCKET, SO_ERROR;

        socklen_t len = int.sizeof;
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
        m_error = cast(error_t) err;
        if (m_error != EPosix.EOK)
        {
            m_status.code = Status.ABORT;
            static if (LOG)
                log(m_status);
            return true;
        }

        return false;
    }

    bool catchEvLoopErrors(string TRACE, T)(T val, Tuple!(T, Status)[] cmp...)
            if (isIntegral!T)
    {
        if (val == SOCKET_ERROR)
        {
            int err = errno;
            foreach (validator; cmp)
            {
                if (errno == validator[0])
                {
                    m_status.text = TRACE;
                    m_error = lastError();
                    m_status.code = validator[1];
                    static if (LOG)
                        log(m_status);
                    return true;
                }
            }

            m_status.text = TRACE;
            m_status.code = Status.EVLOOP_FAILURE;
            m_error = lastError();
            static if (LOG)
                log(m_status);
            return true;
        }
        return false;
    }

    /**
	 * If the value at val matches the tuple first argument T, get the last error,
	 * and if the last error matches tuple second argument error_t, set the Status as
	 * tuple third argument Status.
	 *
	 * Repeats for each comparison tuple until a match in which case returns true.
	 */
    bool catchErrorsEq(string TRACE, T)(T val, Tuple!(T, error_t, Status)[] cmp...)
            if (isIntegral!T)
    {
        error_t err;
        foreach (validator; cmp)
        {
            if (val == validator[0])
            {
                if (err is EPosix.init)
                    err = lastError();
                if (err == validator[1])
                {
                    m_status.text = TRACE;
                    m_status.code = validator[2];
                    if (m_status.code == Status.EVLOOP_TIMEOUT)
                    {
                        static if (LOG)
                            log(m_status);
                        break;
                    }
                    m_error = lastError();
                    static if (LOG)
                        log(m_status);
                    return true;
                }
            }
        }
        return false;
    }

    pragma(inline, true) error_t lastError()
    {
        try
        {
            return cast(error_t) errno;
        }
        catch (Exception e)
        {
            return EPosix.EACCES;
        }

    }

    void log(StatusInfo val)
    {
        static if (LOG)
        {
            import std.stdio;

            try
            {
                writeln("Backtrace: ", m_status.text);
                writeln(" | Status:  ", m_status.code);
                writeln(" | Error: ", m_error);
                if ((m_error in EPosixMessages) !is null)
                    writeln(" | Message: ", EPosixMessages[m_error]);
            }
            catch (Exception e)
            {
                return;
            }
        }
    }

    void log(T)(T val)
    {
        static if (LOG)
        {
            import std.stdio;

            try
            {
                writeln(val);
            }
            catch (Exception e)
            {
                return;
            }
        }
    }

    NetworkAddress getAddressInfo(addrinfo)(in string host, ushort port, bool ipv6,
            bool tcp, ref addrinfo hints)
    {
        m_status = StatusInfo.init;
        import libasync.internals.socket_compat : AF_INET, AF_INET6, SOCK_DGRAM,
            SOCK_STREAM, IPPROTO_TCP, IPPROTO_UDP, freeaddrinfo, getaddrinfo;

        NetworkAddress addr;
        addrinfo* infos;
        error_t err;
        if (ipv6)
        {
            addr.family = AF_INET6;
            hints.ai_family = AF_INET6;
        }
        else
        {
            addr.family = AF_INET;
            hints.ai_family = AF_INET;
        }
        if (tcp)
        {
            hints.ai_socktype = SOCK_STREAM;
            hints.ai_protocol = IPPROTO_TCP;
        }
        else
        {
            hints.ai_socktype = SOCK_DGRAM;
            hints.ai_protocol = IPPROTO_UDP;
        }

        static if (LOG)
        {
            log("Resolving " ~ host ~ ":" ~ port.to!string);
        }

        auto chost = host.toStringz();

        if (port != 0)
        {
            addr.port = port;
            const(char)* cPort = cast(const(char)*) port.to!string.toStringz;
            err = cast(error_t) getaddrinfo(chost, cPort, &hints, &infos);
        }
        else
        {
            err = cast(error_t) getaddrinfo(chost, null, &hints, &infos);
        }

        if (err != EPosix.EOK)
        {
            setInternalError!"getAddressInfo"(Status.ERROR, string.init, err);
            return NetworkAddress.init;
        }
        ubyte* pAddr = cast(ubyte*) infos.ai_addr;
        ubyte* data = cast(ubyte*) addr.sockAddr;
        data[0 .. infos.ai_addrlen] = pAddr[0 .. infos.ai_addrlen]; // perform bit copy
        freeaddrinfo(infos);
        return addr;
    }

}

static if (!EPOLL)
{
    import std.container : Array;
    import core.sync.mutex : Mutex;
    import core.sync.rwmutex : ReadWriteMutex;

    size_t g_evIdxCapacity;
    Array!size_t g_evIdxAvailable;

    // called on run
    nothrow size_t createIndex()
    {
        size_t idx;
        import std.algorithm : max;

        try
        {

            size_t getIdx()
            {

                if (!g_evIdxAvailable.empty)
                {
                    immutable size_t ret = g_evIdxAvailable.back;
                    g_evIdxAvailable.removeBack();
                    return ret;
                }
                return 0;
            }

            idx = getIdx();
            if (idx == 0)
            {
                import std.range : iota;

                g_evIdxAvailable.insert(iota(g_evIdxCapacity, max(32, g_evIdxCapacity * 2), 1));
                g_evIdxCapacity = max(32, g_evIdxCapacity * 2);
                idx = getIdx();
            }

        }
        catch (Throwable e)
        {
            static if (DEBUG)
            {
                import std.stdio : writeln;

                try
                    writeln(e.toString());
                catch
                {
                }
            }

        }
        return idx;
    }

    nothrow void destroyIndex(AsyncNotifier ctxt)
    {
        try
        {
            g_evIdxAvailable.insert(ctxt.id);
        }
        catch (Exception e)
        {
            assert(false, "Error destroying index: " ~ e.msg);
        }
    }

    nothrow void destroyIndex(AsyncTimer ctxt)
    {
        try
        {
            g_evIdxAvailable.insert(ctxt.id);
        }
        catch (Exception e)
        {
            assert(false, "Error destroying index: " ~ e.msg);
        }
    }

    size_t* g_threadId;
    size_t g_idxCapacity;
    Array!size_t g_idxAvailable;

    __gshared ReadWriteMutex gs_queueMutex;
    __gshared Array!(Array!AsyncSignal) gs_signalQueue;
    __gshared Array!(Array!size_t) gs_idxQueue; // signals notified

    // loop
    nothrow bool popSignals(ref AsyncSignal[] sigarr)
    {
        bool more;
        try
        {
            foreach (ref AsyncSignal sig; sigarr)
            {
                if (!sig)
                    break;
                sig = null;
            }
            size_t len;
            synchronized (gs_queueMutex.reader)
            {

                if (gs_idxQueue.length <= *g_threadId || gs_idxQueue[*g_threadId].empty)
                    return false;

                len = gs_idxQueue[*g_threadId].length;
                import std.stdio;

                if (sigarr.length < len)
                {
                    more = true;
                    len = sigarr.length;
                }

                size_t i;
                foreach (size_t idx; gs_idxQueue[*g_threadId][0 .. len])
                {
                    sigarr[i] = gs_signalQueue[*g_threadId][idx];
                    i++;
                }
            }

            synchronized (gs_queueMutex.writer)
            {
                gs_idxQueue[*g_threadId].linearRemove(gs_idxQueue[*g_threadId][0 .. len]);
            }
        }
        catch (Exception e)
        {
            assert(false, "Could not get pending signals: " ~ e.msg);
        }
        return more;
    }

    // notify
    nothrow void addSignal(shared AsyncSignal ctxt)
    {
        try
        {
            size_t thread_id = ctxt.threadId;
            bool must_resize;
            import std.stdio;

            synchronized (gs_queueMutex.writer)
            {
                if (gs_idxQueue.empty || gs_idxQueue.length < thread_id + 1)
                {
                    gs_idxQueue.reserve(thread_id + 1);
                    foreach (i; gs_idxQueue.length .. gs_idxQueue.capacity)
                    {
                        gs_idxQueue.insertBack(Array!size_t.init);
                    }
                }
                if (gs_idxQueue[thread_id].empty)
                {
                    gs_idxQueue[thread_id].reserve(32);
                }

                gs_idxQueue[thread_id].insertBack(ctxt.id);

            }

        }
        catch (Exception e)
        {
            assert(false, "Array error: " ~ e.msg);
        }
    }

    // called on run
    nothrow size_t createIndex(shared AsyncSignal ctxt)
    {
        size_t idx;
        import std.algorithm : max;

        try
        {
            bool must_resize;

            synchronized (gs_queueMutex.reader)
            {
                if (gs_signalQueue.length < *g_threadId)
                    must_resize = true;
            }

            /// make sure the signal queue is big enough for this thread ID
            if (must_resize)
            {
                synchronized (gs_queueMutex.writer)
                {
                    while (gs_signalQueue.length <= *g_threadId)
                        gs_signalQueue.insertBack(Array!AsyncSignal.init);
                }
            }

            size_t getIdx()
            {

                if (!g_idxAvailable.empty)
                {
                    immutable size_t ret = g_idxAvailable.back;
                    g_idxAvailable.removeBack();
                    return ret;
                }
                return 0;
            }

            idx = getIdx();
            if (idx == 0)
            {
                import std.range : iota;

                g_idxAvailable.insert(iota(g_idxCapacity + 1, max(32, g_idxCapacity * 2), 1));
                g_idxCapacity = g_idxAvailable[$ - 1];
                idx = getIdx();
            }

            synchronized (gs_queueMutex.writer)
            {
                if (gs_signalQueue.empty || gs_signalQueue.length < *g_threadId + 1)
                {

                    gs_signalQueue.reserve(*g_threadId + 1);
                    foreach (i; gs_signalQueue.length .. gs_signalQueue.capacity)
                    {
                        gs_signalQueue.insertBack(Array!AsyncSignal.init);
                    }

                }

                if (gs_signalQueue[*g_threadId].empty
                        || gs_signalQueue[*g_threadId].length < idx + 1)
                {

                    gs_signalQueue[*g_threadId].reserve(idx + 1);
                    foreach (i; gs_signalQueue[*g_threadId].length
                            .. gs_signalQueue[*g_threadId].capacity)
                    {
                        gs_signalQueue[*g_threadId].insertBack(cast(AsyncSignal) null);
                    }

                }

                gs_signalQueue[*g_threadId][idx] = cast(AsyncSignal) ctxt;
            }
        }
        catch (Exception e)
        {
        }

        return idx;
    }

    // called on kill
    nothrow void destroyIndex(shared AsyncSignal ctxt)
    {
        try
        {
            g_idxAvailable.insert(ctxt.id);
            synchronized (gs_queueMutex.writer)
            {
                gs_signalQueue[*g_threadId][ctxt.id] = null;
            }
        }
        catch (Exception e)
        {
            assert(false, "Error destroying index: " ~ e.msg);
        }
    }
}

mixin template COSocketMixins()
{

    private CleanupData m_impl;

    struct CleanupData
    {
        EventInfo* evInfo;
        bool connected;
        bool disconnecting;
        bool writeBlocked;
        bool readBlocked;
    }

    @property bool disconnecting() const @safe pure @nogc
    {
        return m_impl.disconnecting;
    }

    @property void disconnecting(bool b) @safe pure @nogc
    {
        m_impl.disconnecting = b;
    }

    @property bool connected() const @safe pure @nogc
    {
        return m_impl.connected;
    }

    @property void connected(bool b) @safe pure @nogc
    {
        m_impl.connected = b;
    }

    @property bool writeBlocked() const @safe pure @nogc
    {
        return m_impl.writeBlocked;
    }

    @property void writeBlocked(bool b) @safe pure @nogc
    {
        m_impl.writeBlocked = b;
    }

    @property bool readBlocked() const @safe pure @nogc
    {
        return m_impl.readBlocked;
    }

    @property void readBlocked(bool b) @safe pure @nogc
    {
        m_impl.readBlocked = b;
    }

    @property EventInfo* evInfo() @safe pure @nogc
    {
        return m_impl.evInfo;
    }

    @property void evInfo(EventInfo* info) @safe pure @nogc
    {
        m_impl.evInfo = info;
    }

}

mixin template EvInfoMixinsShared()
{

    private CleanupData m_impl;

    shared struct CleanupData
    {
        EventInfo* evInfo;
    }

    static if (EPOLL)
    {
        import core.sys.posix.pthread : pthread_t;

        private pthread_t m_pthreadId;
        synchronized @property pthread_t pthreadId()
        {
            return cast(pthread_t) m_pthreadId;
        }
        /* todo: support multiple event loops per thread?
		 private ushort m_sigId;
		 synchronized @property ushort sigId() {
		 return cast(ushort)m_loopId;
		 }
		 synchronized @property void sigId(ushort id) {
		 m_loopId = cast(shared)id;
		 }
		 */
    }
    else /* if KQUEUE */
    {
        private shared(size_t)* m_owner_id;
        synchronized @property size_t threadId()
        {
            return cast(size_t)*m_owner_id;
        }
    }

    @property shared(EventInfo*) evInfo()
    {
        return m_impl.evInfo;
    }

    @property void evInfo(shared(EventInfo*) info)
    {
        m_impl.evInfo = info;
    }

}

mixin template EvInfoMixins()
{

    private CleanupData m_impl;

    struct CleanupData
    {
        EventInfo* evInfo;
    }

    @property EventInfo* evInfo()
    {
        return m_impl.evInfo;
    }

    @property void evInfo(EventInfo* info)
    {
        m_impl.evInfo = info;
    }
}

union EventObject
{
    TCPAcceptHandler tcpAcceptHandler;
    TCPEventHandler tcpEvHandler;
    AsyncSocket socket;
    TimerHandler timerHandler;
    DWHandler dwHandler;
    UDPHandler udpHandler;
    NotifierHandler notifierHandler;
    EventHandler eventHandler;
}

enum EventType : char
{
    TCPAccept,
    TCPTraffic,
    UDPSocket,
    Socket,
    Notifier,
    Signal,
    Timer,
    DirectoryWatcher,
    Event // custom
}

struct EventInfo
{
    fd_t fd;
    EventType evType;
    EventObject evObj;
    ushort owner;
}
