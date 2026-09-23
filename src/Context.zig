//! Basically instead of creating and destroying threads; we keep the thread alive
//! and we wake it up when we want to do work.

tls_stack: []u8,
thread: horizon.Thread,

stop: bool,
work: horizon.AddressArbiter.Event,
current_session: horizon.Session.Server,

func: *const fn (session: horizon.Session.Server) void,
idx: u32,

pub fn init(st: *SessionThread, idx: u32, func: *const fn (session: horizon.Session.Server) void, tls_stack: []u8, priority: horizon.Thread.Priority, processor: horizon.Thread.Processor) void {
    if (horizon.tls.size() >= 2048 or horizon.tls.alignment() >= 4096) @panic("thread-local variables take too much space");

    st.* = .{
        .tls_stack = tls_stack,
        .thread = undefined,

        .work = .init(.oneshot, false),
        .current_session = undefined,
        .stop = false,

        .func = func,
        .idx = idx,
    };

    st.thread = assertResult(horizon.createThread(&entry, st, st.tls_stack.ptr + st.tls_stack.len, priority, processor));
}

pub fn deinit(st: *SessionThread) void {
    st.stop = true;
    st.work.signal(env.arbiter);
    assertCode(horizon.waitSynchronization(st.thread.sync, .none));
    st.thread.close();
    st.* = undefined;
}

pub fn acceptSession(st: *SessionThread, session: horizon.Session.Server) void {
    st.current_session = session;
    st.work.signal(env.arbiter);
}

fn entry(ctx: ?*anyopaque) callconv(.c) noreturn {
    const st: *SessionThread = @ptrCast(@alignCast(ctx.?));
    horizon.tls.initVariables(st.tls_stack);

    while (true) {
        st.work.wait(env.arbiter);
        if (st.stop) break;

        st.func(st.current_session);
    }

    horizon.exitThread();
}

const assertResult = ErrorDisplayManager.assertResult;
const assertCode = ErrorDisplayManager.assertCode;

const SessionThread = @This();

const env = @import("env.zig");

const std = @import("std");
const zitrus = @import("zitrus");
const horizon = zitrus.horizon;

const ErrorDisplayManager = horizon.ErrorDisplayManager;
