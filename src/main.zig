pub const std_os_options: std.Options.OperatingSystem = horizon.default_std_os_options;
pub const panic = horizon.debug.simple_errdisp_panic;
pub const zitrus_options: zitrus.Options = .{
    .stack_size = switch (@import("builtin").mode) {
        .Debug => 64 * 1024, // We'll stack overflow otherwise
        .ReleaseSafe => 16 * 1024, // Just in case as I've been getting some stack overflows while developing
        .ReleaseSmall, .ReleaseFast => null, // Use the kernel-provided stack (4096 bytes in this case)
    },
};

pub fn main() void {
    env.arbiter = assertResult(horizon.createAddressArbiter());
    defer env.arbiter.close();

    const srv = assertResult(ServiceManager.openWithResult());
    defer srv.close();

    assertResult(srv.sendWithResult(.RegisterClient, .{}, .{}));

    var handles: [1 + service_names.len]horizon.Synchronization = undefined;
    var ports: std.ArrayList(Port.Server) = .initBuffer(@ptrCast(handles[1..][0..service_names.len]));
    defer for (ports.items) |port| port.close();

    handles[0] = @bitCast(assertResult(srv.sendWithResult(.EnableNotification, {}, .{})));
    defer handles[0].close();

    for (service_names) |name| ports.appendAssumeCapacity(assertResult(srv.sendWithResult(.RegisterService, .init(name, 1), .{})).wrapped);
    defer for (service_names) |name| assertResult(srv.sendWithResult(.UnregisterService, .embedded(name), .{}));

    for (subscribed_notifications) |notification| assertResult(srv.sendWithResult(.Subscribe, notification, .{}));
    defer for (subscribed_notifications) |notification| assertResult(srv.sendWithResult(.Unsubscribe, notification, .{}));

    const ptm: Ptm = assertResult(Ptm.openWithResult(srv, .system));
    defer ptm.close();

    const codec = &env.codec;

    codec.init(srv);
    defer codec.deinit();

    initContexts(ptm);
    defer deinitContexts();

    var running = true;
    while (running) {
        const idx: u32 = assertResult(horizon.waitSynchronizationMultiple(handles[0 .. 1 + ports.items.len], false, .none));

        switch (idx) {
            0 => switch (assertResult(srv.sendWithResult(.ReceiveNotification, {}, .{}))) {
                .must_terminate => running = false,
                .shell_opened => codec.shellOpened(),
                .shell_closed => codec.shellClosed(),
                .entering_sleep => {
                    codec.enterSleep();
                    assertResult(ptm.sendWithResult(.NotifySleepPreparationComplete, .init(0), .{}));
                },
                .waking_up => {
                    codec.exitSleep();
                    assertResult(ptm.sendWithResult(.NotifySleepPreparationComplete, .init(0), .{}));
                },
                else => {},
            },
            ports_begin...ports_end => {
                const port_idx = idx - ports_begin;
                const port = ports.items[port_idx];

                env.ctx[port_idx].acceptSession(assertResult(horizon.acceptSession(port)));
            },
            else => unreachable,
        }
    }
}

fn initContexts(ptm: Ptm) void {
    const is_new_model = assertResult(ptm.sendWithResult(.IsNew3ds, {}, .{}));
    const hid_handler_priority: horizon.Thread.Priority, const hid_handler_processor: horizon.Thread.Processor = if (is_new_model)
        .{ .priority(15), .@"3" }
    else
        .{ .priority(20), .default };

    comptime std.debug.assert(std.mem.eql(u8, service_names[0], "cdc:HID"));
    env.ctx[0].init(0, &hidHandler, &env.ctx_stack_tls[0], hid_handler_priority, hid_handler_processor);
    for (env.ctx[1..], env.ctx_stack_tls[1..], service_handlers[1..], 1..) |*ctx, *stack_tls, handler, i| {
        ctx.init(i, handler, stack_tls, .priority(20), .default);
    }
}

fn deinitContexts() void {
    for (&env.ctx) |*ctx| ctx.deinit();
}

fn hidHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    ipc.packed_command.header = .none;
    loop: while (true) {
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.Hid.command.Id)) |id| switch (id) {
            .get_report => if (ipc.readRequest(cdc.Hid.command.GetReport)) |_|
                ipc.writeResponse(cdc.Hid.command.GetReport, codec.hidGetReport()),
            .initialize => if (ipc.readRequest(cdc.Hid.command.Initialize)) |_|
                ipc.writeResponse(cdc.Hid.command.Initialize, codec.hidInitialize()),
            .deinitialize => if (ipc.readRequest(cdc.Hid.command.Deinitialize)) |_|
                ipc.writeResponse(cdc.Hid.command.Deinitialize, codec.hidDeinitialize()),
        };
    }
}

fn lgyHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    ipc.packed_command.header = .none;
    loop: while (true) {
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.Legacy.command.Id)) |id| switch (id) {
            .initialize => if (ipc.readRequest(cdc.Legacy.command.Initialize)) |_|
                ipc.writeResponse(cdc.Legacy.command.Initialize, codec.lgyInitialize()),
            .set_touch_3ds => if (ipc.readRequest(cdc.Legacy.command.SetTouch3ds)) |req|
                ipc.writeResponse(cdc.Legacy.command.SetTouch3ds, codec.lgySetTouch3ds(req)),
            .set_mic_bias => if (ipc.readRequest(cdc.Legacy.command.SetMicBias)) |req|
                ipc.writeResponse(cdc.Legacy.command.SetMicBias, codec.lgySetMicBias(req)),
        };
    }
}

fn micHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    ipc.packed_command.header = .none;
    loop: while (true) {
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.Mic.command.Id)) |id| switch (id) {
            .set_gain => if (ipc.readRequest(cdc.Mic.command.SetGain)) |req|
                ipc.writeResponse(cdc.Mic.command.SetGain, codec.micSetGain(req)),
            .get_gain => if (ipc.readRequest(cdc.Mic.command.GetGain)) |_|
                ipc.writeResponse(cdc.Mic.command.GetGain, codec.micGetGain()),
            .set_powered => if (ipc.readRequest(cdc.Mic.command.SetPowered)) |req|
                ipc.writeResponse(cdc.Mic.command.SetPowered, codec.micSetPowered(req)),
            .is_powered => if (ipc.readRequest(cdc.Mic.command.IsPowered)) |_|
                ipc.writeResponse(cdc.Mic.command.IsPowered, codec.micIsPowered()),
            .set_iir_filters => if (ipc.readRequest(cdc.Mic.command.SetIirFilters)) |req|
                ipc.writeResponse(cdc.Mic.command.SetIirFilters, codec.micSetIirFilters(req)),
        };
    }
}

fn dspHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;

    ipc.packed_command.header = .none;
    loop: while (true) {
        ipc.static.buffers[0] = .init(u8, &write_buffer, 0);
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.Dsp.command.Id)) |id| switch (id) {
            .set_i2s1_iir_filters => if (ipc.readRequest(cdc.Dsp.command.SetI2s1IirFilters)) |req|
                ipc.writeResponse(cdc.Dsp.command.SetI2s1IirFilters, codec.dspSetI2s1IirFilters(req)),
            .set_i2s2_iir_filters => if (ipc.readRequest(cdc.Dsp.command.SetI2s2IirFilters)) |req|
                ipc.writeResponse(cdc.Dsp.command.SetI2s2IirFilters, codec.dspSetI2s2IirFilters(req)),
            .set_sink_iir_filters => if (ipc.readRequest(cdc.Dsp.command.SetSinkIirFilters)) |req|
                ipc.writeResponse(cdc.Dsp.command.SetSinkIirFilters, codec.dspSetSinkIirFilters(req)),
            .read_3ds_tsc => if (ipc.readRequest(cdc.Dsp.command.Read3dsTsc)) |req|
                ipc.writeResponse(cdc.Dsp.command.Read3dsTsc, codec.dspRead3dsTsc(&read_buffer, req)),
            .write_3ds_tsc => if (ipc.readRequest(cdc.Dsp.command.Write3dsTsc)) |req|
                ipc.writeResponse(cdc.Dsp.command.Write3dsTsc, codec.dspWrite3dsTsc(req)),
            .is_headphone_connected => if (ipc.readRequest(cdc.Dsp.command.IsHeadphoneConnected)) |_|
                ipc.writeResponse(cdc.Dsp.command.IsHeadphoneConnected, codec.dspIsHeadphoneConnected()),
            .enable_volume_output => if (ipc.readRequest(cdc.Dsp.command.EnableVolumeOutput)) |req|
                ipc.writeResponse(cdc.Dsp.command.EnableVolumeOutput, codec.dspEnableVolumeOutput(req)),
            .force_headphone_output => if (ipc.readRequest(cdc.Dsp.command.ForceHeadphoneOutput)) |req|
                ipc.writeResponse(cdc.Dsp.command.ForceHeadphoneOutput, codec.dspForceHeadphoneOutput(req)),
        };
    }
}

fn csnHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    ipc.packed_command.header = .none;
    loop: while (true) {
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.CSnd.command.Id)) |id| switch (id) {
            .ignore_volume_slider_forcing_speaker_output => if (ipc.readRequest(cdc.CSnd.command.IgnoreVolumeSliderForceSpeakerOutput)) |_|
                ipc.writeResponse(cdc.CSnd.command.IgnoreVolumeSliderForceSpeakerOutput, codec.csnIgnoreVolumeSliderForceSpeakerOutput()),
            .stop_ignore_volume_slider_force_speaker_output => if (ipc.readRequest(cdc.CSnd.command.StopIgnoreVolumeSliderForceSpeakerOutput)) |_|
                ipc.writeResponse(cdc.CSnd.command.StopIgnoreVolumeSliderForceSpeakerOutput, codec.csnStopIgnoreVolumeSliderForceSpeakerOutput()),
            .set_i2s_volume => if (ipc.readRequest(cdc.CSnd.command.SetI2sVolume)) |req|
                ipc.writeResponse(cdc.CSnd.command.SetI2sVolume, codec.csnSetI2sVolume(req)),
            .get_i2s_volume => if (ipc.readRequest(cdc.CSnd.command.GetI2sVolume)) |req|
                ipc.writeResponse(cdc.CSnd.command.GetI2sVolume, codec.csnGetI2sVolume(req)),
            .set_force_speaker_output => if (ipc.readRequest(cdc.CSnd.command.SetForceSpeakerOutput)) |req|
                ipc.writeResponse(cdc.CSnd.command.SetForceSpeakerOutput, codec.csnSetForceSpeakerOutput(req)),
            .is_forcing_speaker_output => if (ipc.readRequest(cdc.CSnd.command.IsForcingSpeakerOutput)) |_|
                ipc.writeResponse(cdc.CSnd.command.IsForcingSpeakerOutput, codec.csnIsForcingSpeakerOutput()),
            .set_ignore_volume_slider => if (ipc.readRequest(cdc.CSnd.command.SetIgnoreVolumeSlider)) |req|
                ipc.writeResponse(cdc.CSnd.command.SetIgnoreVolumeSlider, codec.csnSetIgnoreVolumeSlider(req)),
            .is_ignoring_volume_slider => if (ipc.readRequest(cdc.CSnd.command.IsIgnoringVolumeSlider)) |_|
                ipc.writeResponse(cdc.CSnd.command.IsIgnoringVolumeSlider, codec.csnIsIgnoringVolumeSlider()),
            .get_wakeup_completed_event => if (ipc.readRequest(cdc.CSnd.command.GetWakeupCompletedEvent)) |_|
                ipc.writeResponse(cdc.CSnd.command.GetWakeupCompletedEvent, .of(.success, codec.sleep_wakeup_completed)),
        };
    }
}

fn chkHandler(session: horizon.Session.Server) void {
    const tls = horizon.tls.get();
    const ipc = &tls.ipc;
    const codec = &env.codec;

    var read_buffer: [64]u8 = undefined;
    var write_buffer: [64]u8 = undefined;

    ipc.packed_command.header = .none;
    loop: while (true) {
        ipc.static.buffers[0] = .init(u8, &write_buffer, 0);
        const res = horizon.replyAndReceive(@ptrCast(&session), session);

        switch (res.code) {
            .os_session_closed_by_remote => {
                session.close();
                break :loop;
            },
            else => assertCode(res.code),
        }

        if (ipc.readRequestId(cdc.Check.command.Id)) |id| switch (id) {
            .read_dsi_tsc => if (ipc.readRequest(cdc.Check.command.ReadDsiTsc)) |req|
                ipc.writeResponse(cdc.Check.command.ReadDsiTsc, codec.chkReadDsiTsc(&read_buffer, req)),
            .read_3ds_tsc => if (ipc.readRequest(cdc.Check.command.Read3dsTsc)) |req|
                ipc.writeResponse(cdc.Check.command.Read3dsTsc, codec.chkRead3dsTsc(&read_buffer, req)),
            .write_dsi_tsc => if (ipc.readRequest(cdc.Check.command.WriteDsiTsc)) |req|
                ipc.writeResponse(cdc.Check.command.WriteDsiTsc, codec.chkWriteDsiTsc(req)),
            .write_3ds_tsc => if (ipc.readRequest(cdc.Check.command.Write3dsTsc)) |req|
                ipc.writeResponse(cdc.Check.command.Write3dsTsc, codec.chkWrite3dsTsc(req)),
            .read_power_management => if (ipc.readRequest(cdc.Check.command.ReadPowerManagement)) |req|
                ipc.writeResponse(cdc.Check.command.ReadPowerManagement, codec.chkReadPowerManagement(req)),
            .write_power_management => if (ipc.readRequest(cdc.Check.command.WritePowerManagement)) |req|
                ipc.writeResponse(cdc.Check.command.WritePowerManagement, codec.chkWritePowerManagement(req)),
            .set_i2s_volume => if (ipc.readRequest(cdc.Check.command.SetI2sVolume)) |req|
                ipc.writeResponse(cdc.Check.command.SetI2sVolume, codec.chkSetI2sVolume(req)),
        };
    }
}

const assertResult = ErrorDisplayManager.assertResult;
const assertCode = ErrorDisplayManager.assertCode;

const service_names: []const []const u8 = &.{ "cdc:HID", "cdc:MIC", "cdc:CSN", "cdc:DSP", "cdc:LGY", "cdc:CHK" };
const service_handlers: []const *const fn (session: horizon.Session.Server) void = &.{
    &hidHandler,
    &micHandler,
    &csnHandler,
    &dspHandler,
    &lgyHandler,
    &chkHandler,
};

const ports_begin = 1;
const ports_end = 1 + service_names.len - 1;

const subscribed_notifications: []const horizon.ServiceManager.Notification = &.{
    .shell_opened,
    .shell_closed,
    .entering_sleep,
    .waking_up,
};

const Codec = @import("Codec.zig");
const env = @import("env.zig");

const std = @import("std");
const zitrus = @import("zitrus");

const hardware = zitrus.hardware;

const horizon = zitrus.horizon;
const ServiceManager = horizon.ServiceManager;
const ErrorDisplayManager = horizon.ErrorDisplayManager;

const Ptm = horizon.services.Ptm;
const cdc = horizon.services.cdc;

const Port = horizon.Port;
const Session = horizon.Session;
const Code = horizon.result.Code;
