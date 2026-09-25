//! Synchronization must be done externally through `mut`
//! unless the method is documented as "Thread-safe"

// NOTE: All "known" page/registers come from GBATEK; though some are wrong so their naming has been updated.
// Some other names come from matching data in the TSC2117 datasheet (even though it's not the *same* chip that is in the 3ds)
// And some other comes from what has been assumed by looking in other sysmodules; may be wrong or may be not!

pdn: PdnI2s,
gpio: Gpio,
spi: Spi,
cfg: Cfg,

system_model: Cfg.SystemModel,

sleep_wakeup_completed: horizon.Event,

irq_poll_timer: horizon.Timer,

headphones_irq: horizon.Event,
irq_stack_tls: []u8,
irq_thread: horizon.Thread,
irq_thread_stop: std.atomic.Value(bool),
irq_polls_with_same_state: u8,

was_touch_3ds: bool,
was_touch_enabled: bool,

forced_headphone_output: bool,

// These are atomic because we may not hold `mut` when accessing them.
force_headphone_on_shell_close: std.atomic.Value(bool),
sleeping: std.atomic.Value(bool),
headphones_connected: std.atomic.Value(bool),

all_touch_entries_were_available: bool,
last_circle_x: [4]u16,

/// Must be held for anything touching the codec
mut: horizon.AddressArbiter.Mutex,

pub fn init(codec: *Codec, srv: ServiceManager) void {
    const Bss = struct {
        var stack_tls: [env.thread_stack_size]u8 = undefined;
    };

    codec.* = .{
        .pdn = assertResult(PdnI2s.openWithResult(srv)),
        .gpio = assertResult(Gpio.openWithResult(srv, .cdc)),
        .spi = assertResult(Spi.openWithResult(srv, .cd2)),
        .cfg = assertResult(Cfg.openWithResult(srv, .system)),

        .system_model = .ctr,

        .sleep_wakeup_completed = assertResult(horizon.createEvent(.oneshot)),

        .irq_poll_timer = assertResult(horizon.createTimer(.oneshot)),
        .headphones_irq = assertResult(horizon.createEvent(.sticky)),
        .irq_stack_tls = &Bss.stack_tls,
        .irq_thread = undefined,
        .irq_thread_stop = .init(false),
        .irq_polls_with_same_state = 0,

        .sleeping = .init(false),
        .was_touch_3ds = false,
        .was_touch_enabled = false,

        .forced_headphone_output = false,
        .force_headphone_on_shell_close = .init(false),
        .headphones_connected = .init(false),

        .all_touch_entries_were_available = false,
        .last_circle_x = @splat(0),

        .mut = .init,
    };

    codec.system_model = assertResult(codec.cfg.sendWithResult(.GetSystemModel, {}, .{}));

    var cal: Calibration = undefined;

    if (!codec.cfg.sendWithResult(.GetConfigSystem, .init(Calibration, .codec, (&cal)[0..1]), .{}).code.isSuccess()) {
        cal = .default;
    }

    codec.initDevice(&cal);

    {
        const mcu: Mcu = assertResult(Mcu.openWithResult(srv));
        defer mcu.close();

        assertResult(mcu.sendWithResult(.Initialize, {}, .{}));
    }

    codec.irq_thread = assertResult(horizon.createThread(irqEntry, codec, codec.irq_stack_tls.ptr + codec.irq_stack_tls.len, .priority(21), .default));
    assertCode(horizon.setTimer(codec.irq_poll_timer, 16 * std.time.ns_per_ms, 16 * std.time.ns_per_ms));
}

pub fn deinit(codec: *Codec) void {
    codec.enterSleep();
    assertResult(codec.gpio.sendWithResult(.UnbindInterrupt, .init(.init(.{ .headphones_inserted = true }), codec.headphones_irq.int), .{}));

    codec.irq_thread_stop.store(true, .monotonic);
    assertCode(horizon.setTimer(codec.irq_poll_timer, 0, 0));
    assertCode(horizon.waitSynchronization(codec.irq_thread.sync, .none));
    codec.irq_thread.close();
    codec.irq_poll_timer.close();
    codec.sleep_wakeup_completed.close();
    codec.headphones_irq.close();

    // NOTE: These do *literally* nothing in the spi service
    _ = codec.spi.sendWithResult(.DeinitDevice, .power_management, .{});
    _ = codec.spi.sendWithResult(.DeinitDevice, .dsi_tsc, .{});
    _ = codec.spi.sendWithResult(.DeinitDevice, .@"3ds_tsc", .{});

    codec.cfg.close();
    codec.spi.close();
    codec.gpio.close();
    codec.pdn.close();
    codec.* = undefined;
}

/// Thread-safe
pub fn shellOpened(codec: *Codec) void {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (!codec.forced_headphone_output) return;

    codec.setHeadphoneOutput(codec.headphones_connected.load(.monotonic));
    codec.forced_headphone_output = false;
}

/// Thread-safe
pub fn shellClosed(codec: *Codec) void {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (!codec.force_headphone_on_shell_close.load(.monotonic)) return;
    codec.setHeadphoneOutput(true);
    codec.forced_headphone_output = true;
}

/// Thread-safe
pub fn enterSleep(codec: *Codec) void {
    codec.sleeping.store(true, .monotonic);

    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    codec.setOld3dsDepopEnabled(true);
    defer codec.setOld3dsDepopEnabled(false);

    codec.was_touch_3ds = codec.isTouch3DS();
    if (!codec.was_touch_3ds) codec.setTouch3ds(true);

    codec.writePageRegisterMasked(.reg(u8, 103, 0x25), 0, 3);
    codec.was_touch_enabled = codec.isTouchEnabled();
    codec.setTouchEnabled(false);

    codec.stopUnknown();
    codec.setI2s2Powered(false);

    i2sr.@"1".enable = false;
    i2sr.@"2".enable = false;
    assertResult(codec.pdn.sendWithResult(.SetEnabled2, false, .{}));
}

/// Thread-safe
pub fn exitSleep(codec: *Codec) void {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    codec.setOld3dsDepopEnabled(true);
    defer codec.setOld3dsDepopEnabled(false);

    assertResult(codec.pdn.sendWithResult(.SetEnabled2, true, .{}));
    i2sr.@"1".enable = true;
    i2sr.@"2".enable = true;

    codec.headphones_connected.store(assertResult(codec.gpio.sendWithResult(.GetData, .init(.{ .headphones_inserted = true }), .{})).int() != 0, .monotonic);
    if (!codec.forced_headphone_output) codec.setHeadphoneOutput(codec.headphones_connected.load(.monotonic));

    codec.writePageRegisterMasked(.ctr_headset, .{ .detection = false }, 0x80);
    codec.writePageRegisterMasked(.ctr_headset, .{ .detection = true }, 0x80);

    codec.startUnknown();
    codec.setI2s2Powered(true);
    codec.writePageRegisterMasked(.reg(u8, 103, 0x25), 3, 3);
    codec.setTouch3ds(codec.was_touch_3ds);
    if (codec.was_touch_enabled) codec.setTouchEnabled(true);
    codec.sleeping.store(false, .monotonic);
    codec.sleep_wakeup_completed.signal();
}

/// Thread-safe
pub fn hidGetReport(codec: *Codec) horizon.Result(cdc.Hid.Report) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, std.mem.zeroes(cdc.Hid.Report));

    if (codec.pollHidReport()) |report| {
        return .of(.success, report);
    } else return .of(.codec_no_data, std.mem.zeroes(cdc.Hid.Report));
}

/// Thread-safe
pub fn hidInitialize(codec: *Codec) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});
    codec.setTouchEnabled(true);
    return .of(.success, {});
}

/// Thread-safe
pub fn hidDeinitialize(codec: *Codec) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});
    codec.setTouchEnabled(false);
    return .of(.success, {});
}

/// Thread-safe
pub fn micSetGain(codec: *Codec, gain: u7) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.setMicGain(gain);
    return .of(.success, {});
}

/// Thread-safe
pub fn micGetGain(codec: *Codec) horizon.Result(u7) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, 0);

    return .of(.success, codec.getMicGain());
}

/// Thread-safe
pub fn micSetPowered(codec: *Codec, powered: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.setMicPowered(powered);
    return .of(.success, {});
}

/// Thread-safe
pub fn micIsPowered(codec: *Codec) horizon.Result(bool) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, false);

    return .of(.success, codec.readPageRegister(.mic_bias).power != .down);
}

/// Thread-safe
pub fn micSetIirFilters(codec: *Codec, req: cdc.Mic.command.SetIirFilters.Request) horizon.Result(cdc.Mic.command.SetIirFilters.Response) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, req.data);

    // NOTE: This error is not in the original sysmodule
    if (req.data.slice.len != @sizeOf(i16) * 25) return .of(.codec_invalid_size, req.data);

    codec.setMicIirFilter(@ptrCast(@alignCast(req.data.slice[0 .. @sizeOf(u16) * 25])));
    return .of(.success, req.data);
}

/// Thread-safe
pub fn dspSetI2s1IirFilters(codec: *Codec, req: cdc.Dsp.command.SetI2s1IirFilters.Request) horizon.Result(cdc.Dsp.command.SetI2s1IirFilters.Response) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, req.data);

    if (req.data.slice.len >= 1) codec.setI2s1Filters(&req.data.slice[0]);
    return .of(.success, req.data);
}

/// Thread-safe
pub fn dspSetI2s2IirFilters(codec: *Codec, req: cdc.Dsp.command.SetI2s2IirFilters.Request) horizon.Result(cdc.Dsp.command.SetI2s2IirFilters.Response) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, req.data);

    if (req.data.slice.len >= 1) codec.setI2s2Filters(&req.data.slice[0]);
    return .of(.success, req.data);
}

/// Thread-safe
pub fn dspSetSinkIirFilters(codec: *Codec, req: cdc.Dsp.command.SetSinkIirFilters.Request) horizon.Result(cdc.Dsp.command.SetSinkIirFilters.Response) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, req.data);

    if (req.data.slice.len >= 1) codec.setSinkIirFilters(req.sink, &req.data.slice[0]);
    return .of(.success, req.data);
}

/// Thread-safe
pub fn dspRead3dsTsc(codec: *Codec, buffer: []u8, req: cdc.Dsp.command.Read3dsTsc.Request) horizon.Result(cdc.Dsp.command.Read3dsTsc.Response) {
    return codec.chkReadTsc(.@"3ds_tsc", req.page, req.register, buffer[0..@min(req.size, buffer.len)]);
}

/// Thread-safe
pub fn dspWrite3dsTsc(codec: *Codec, req: cdc.Dsp.command.Write3dsTsc.Request) horizon.Result(cdc.Dsp.command.Write3dsTsc.Response) {
    return codec.chkWriteTsc(.@"3ds_tsc", req.page, req.register, req.buffer.slice);
}

/// Thread-safe
pub fn dspIsHeadphoneConnected(codec: *Codec) horizon.Result(bool) {
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, false);
    return .of(.success, codec.headphones_connected.load(.monotonic));
}

/// Thread-safe
pub fn dspEnableVolumeOutput(codec: *Codec, enable: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    var cnt = i2sr.@"1";
    cnt.dsp_volume = if (enable) 0x20 else 0;
    i2sr.@"1" = cnt;
    return .of(.success, {});
}

/// Thread-safe
pub fn dspForceHeadphoneOutput(codec: *Codec, force: bool) horizon.Result(void) {
    codec.force_headphone_on_shell_close.store(force, .monotonic);
    return .of(.success, {});
}

/// Thread-safe
pub fn csnIgnoreVolumeSliderForceSpeakerOutput(codec: *Codec) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.writePageRegisterMasked(.gpi1_gpi2_control, .{ .gpi2 = .disabled, .gpi1 = .disabled }, 0x66);
    codec.writePageRegisterMasked(.reg(u8, 100, 0x31), 0x20, 0x20);
    return .of(.success, {});
}

/// Thread-safe
pub fn csnStopIgnoreVolumeSliderForceSpeakerOutput(codec: *Codec) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.writePageRegisterMasked(.reg(u8, 100, 0x31), 0x00, 0x20);
    codec.writePageRegisterMasked(.gpi1_gpi2_control, .{ .gpi2 = .enabled_hp_sp_switch, .gpi1 = @enumFromInt(0b11) }, 0x66);
    return .of(.success, {});
}

/// Thread-safe
pub fn csnSetI2sVolume(codec: *Codec, req: cdc.CSnd.command.SetI2sVolume.Request) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.setI2sVolume(req.line, req.gain);
    return .of(.success, {});
}

/// Thread-safe
pub fn csnGetI2sVolume(codec: *Codec, req: cdc.CSnd.command.GetI2sVolume.Request) horizon.Result(hw.i2s.Gain) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, .gain(0));

    return .of(.success, codec.getI2sVolume(req));
}

/// Thread-safe
pub fn csnSetForceSpeakerOutput(codec: *Codec, force: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.writePageRegisterMasked(
        .gpi1_gpi2_control,
        if (force)
            .{ .gpi2 = .disabled, .gpi1 = .disabled }
        else
            .{ .gpi2 = .enabled_hp_sp_switch, .gpi1 = @enumFromInt(0b11) },
        0x66,
    );

    return .of(.success, {});
}

/// Thread-safe
pub fn csnIsForcingSpeakerOutput(codec: *Codec) horizon.Result(bool) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, false);

    const cnt = codec.readPageRegister(.gpi1_gpi2_control);
    return .of(.success, cnt.gpi1 == .disabled or cnt.gpi2 == .disabled);
}

/// Thread-safe
pub fn csnSetIgnoreVolumeSlider(codec: *Codec, ignore: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.writePageRegisterMasked(.reg(u8, 100, 0x31), @as(u8, @intFromBool(ignore)) << 5, 0x20);
    return .of(.success, {});
}

/// Thread-safe
pub fn csnIsIgnoringVolumeSlider(codec: *Codec) horizon.Result(bool) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, false);

    return .of(.success, (codec.readPageRegister(.reg(u8, 100, 0x31)) & 0x20) == 0x20);
}

/// Thread-safe
pub fn lgyInitialize(codec: *Codec) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.initLegacy();
    return .of(.success, {});
}

/// Thread-safe
pub fn lgySetTouch3ds(codec: *Codec, is_3ds: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.setTouch3ds(is_3ds);
    return .of(.success, {});
}

/// Thread-safe
pub fn lgySetMicBias(codec: *Codec, bias: bool) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.set3DSMicBias(bias);
    return .of(.success, {});
}

/// Thread-safe
pub fn chkReadDsiTsc(codec: *Codec, buffer: []u8, req: cdc.Check.command.ReadDsiTsc.Request) horizon.Result(cdc.Check.command.ReadDsiTsc.Response) {
    return codec.chkReadTsc(.dsi_tsc, req.page, req.register, buffer[0..@min(req.size, buffer.len)]);
}

/// Thread-safe
pub fn chkRead3dsTsc(codec: *Codec, buffer: []u8, req: cdc.Check.command.Read3dsTsc.Request) horizon.Result(cdc.Check.command.Read3dsTsc.Response) {
    return codec.chkReadTsc(.@"3ds_tsc", req.page, req.register, buffer[0..@min(req.size, buffer.len)]);
}

/// Thread-safe
pub fn chkWriteDsiTsc(codec: *Codec, req: cdc.Check.command.WriteDsiTsc.Request) horizon.Result(cdc.Check.command.WriteDsiTsc.Response) {
    return codec.chkWriteTsc(.dsi_tsc, req.page, req.register, req.buffer.slice);
}

/// Thread-safe
pub fn chkWrite3dsTsc(codec: *Codec, req: cdc.Check.command.Write3dsTsc.Request) horizon.Result(cdc.Check.command.Write3dsTsc.Response) {
    return codec.chkWriteTsc(.@"3ds_tsc", req.page, req.register, req.buffer.slice);
}

/// Thread-safe
pub fn chkReadPowerManagement(codec: *Codec, req: cdc.Check.command.ReadPowerManagement.Request) horizon.Result(cdc.Check.command.ReadPowerManagement.Response) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, 0);
    return .of(.success, codec.readPowerManagement(req.index));
}

/// Thread-safe
pub fn chkWritePowerManagement(codec: *Codec, req: cdc.Check.command.WritePowerManagement.Request) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);
    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});
    codec.writePowerManagement(req.index, req.value);
    return .of(.success, {});
}

/// Thread-safe
pub fn chkSetI2sVolume(codec: *Codec, req: cdc.Check.command.SetI2sVolume.Request) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.setI2sVolume(req.line, req.gain);
    return .of(.success, {});
}

/// Thread-safe
fn chkReadTsc(codec: *Codec, tsc: Spi.Device, page: u8, register: u8, buffer: []u8) horizon.Result(horizon.ipc.Static(u8, 0)) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, .static(&.{}));

    codec.rawReadPageRegisters(tsc, page, register, buffer);
    return .of(.success, .static(buffer));
}

/// Thread-safe
fn chkWriteTsc(codec: *Codec, tsc: Spi.Device, page: u8, register: u8, buffer: []const u8) horizon.Result(void) {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    if (codec.sleeping.load(.monotonic)) return .of(.codec_status_changed, {});

    codec.rawWritePageRegisters(tsc, page, register, buffer);
    return .of(.success, {});
}

fn initDevice(codec: *Codec, cal: *Calibration) void {
    assertResult(codec.spi.sendWithResult(.InitDeviceWithRate, .init(.power_management, .@"2Mhz"), .{}));
    assertResult(codec.spi.sendWithResult(.InitDeviceWithRate, .init(.dsi_tsc, .@"4Mhz"), .{}));
    assertResult(codec.spi.sendWithResult(.InitDeviceWithRate, .init(.@"3ds_tsc", .@"4Mhz"), .{}));

    assertResult(codec.spi.sendWithResult(.EnableNewBusWithRate, .init(.power_management, true, .@"2Mhz"), .{}));
    assertResult(codec.spi.sendWithResult(.EnableNewBusWithRate, .init(.@"3ds_tsc", true, .@"16Mhz"), .{}));

    assertResult(codec.pdn.sendWithResult(.SetEnabled2, true, .{}));

    codec.writePageRegister(.ctr_soft_reset, true);
    horizon.sleepThread(40 * std.time.ns_per_ms);
    codec.selectPage(.@"3ds_tsc", 0);

    // NOTE: The TSC2117 timings are based on a 1Mhz reference clock.
    codec.writePageRegister(.ctr_headset, .{
        .button_debounce = .@"8ms",
        .detection_debounce = .@"256ms",
    });

    codec.writePageRegisterMasked(.i2s2_dac_volume_control, .{ .mode = .left_uses_right }, 0x01);

    codec.writePageRegisterMasked(.gpi1_gpi2_control, .{ .gpi2 = .enabled_hp_sp_switch, .gpi1 = @enumFromInt(0b11) }, 0x66);

    codec.writePageRegister(.reg(u8, 101, 0x7a), 1);
    codec.writePageRegisterMasked(.reg(u8, 100, 0x22), 0x18, 0x18);

    assertResult(codec.gpio.sendWithResult(.SetDirection, .init(.init(.{ .headphones_inserted = .input }), .init(.{ .headphones_inserted = true })), .{}));
    assertResult(codec.gpio.sendWithResult(.SetInterruptConfiguration, .init(.init(.{ .headphones_inserted = .rising }), .init(.{ .headphones_inserted = true })), .{}));
    assertResult(codec.gpio.sendWithResult(.SetInterruptEnabled, .init(.init(.{ .headphones_inserted = true }), .init(.{ .headphones_inserted = true })), .{}));
    assertResult(codec.gpio.sendWithResult(.BindInterrupt, .init(.init(.{ .headphones_inserted = true }), 8, codec.headphones_irq.int), .{}));

    codec.headphones_connected.store(assertResult(codec.gpio.sendWithResult(.GetData, .init(.{ .headphones_inserted = true }), .{})).int() != 0, .monotonic);
    if (!codec.forced_headphone_output) codec.setHeadphoneOutput(codec.headphones_connected.load(.monotonic));

    codec.writePageRegisterMasked(.ctr_headset, .{ .detection = false }, 0x80);
    codec.writePageRegisterMasked(.ctr_headset, .{ .detection = true }, 0x80);

    codec.writePageRegister(.dac_ndac, .{ .divisor = .divisor(7), .powered = true });

    codec.writePageRegisterMasked(.mic_m_input_selection, .{ .cm = .@"10kOhm" }, 0xC0);
    codec.writePageRegisterMasked(.reg(u8, 100, 0x7c), 0, 0x01);
    codec.writePageRegisterMasked(.reg(u8, 100, 0x22), 0, 0x04);

    {
        comptime var iir: hw.Iir = .{
            .n = .{ .ofSaturating(0.999053955078125), .ofSaturating(-0.999053955078125) },
            .d = .ofSaturating(0.998077392578125),
        };
        comptime std.mem.byteSwapAllFields(hw.Iir, &iir);

        codec.writePageRegister(.mic_adc_iir, iir);
    }

    std.mem.byteSwapAllFields(hw.IirBiquad, &cal.microphone_filter_32);
    codec.writePageRegister(.mic_32khz_iir_biquads, cal.microphone_filter_32);
    std.mem.byteSwapAllFields(hw.IirBiquad, &cal.microphone_filter_47);
    codec.writePageRegister(.mic_47khz_iir_biquads, cal.microphone_filter_47);

    codec.writePageRegisterMasked(.mic_p_input_selection, .{ .mic = .@"10kOhm" }, 0xC0);
    codec.writePageRegisterMasked(.mic_m_input_selection, .{ .cm = .@"10kOhm" }, 0xC0);

    codec.writePageRegister(.reg(u8, 101, 0x33), cal.microphone_bias);
    codec.waitPageRegisterMaskedValue(.@"3ds_tsc", 101, 0x41, cal.microphone_pga_gain, 0x3f);
    codec.waitPageRegisterMaskedValue(.@"3ds_tsc", 101, 0x42, cal.quick_charge, 0x03);
    codec.setMicGain(0x2b);
    codec.writePageRegisterMasked(.reg(u8, 100, 0x31), 0x44, 0x44);

    codec.writePageRegister(.dac_left_volume, .gain(cal.shutter_volume[0]));
    codec.writePageRegister(.dac_right_volume, .gain(cal.shutter_volume[0]));

    codec.writePageRegister(.reg(i8, 100, 0x7b), cal.shutter_volume[1]);
    codec.setOld3dsDepopEnabled(true);

    // Basically ensure it's not enabled; mask freq & master clock
    // then set freq to 32Khz and master clock to 16Mhz
    {
        var cnt = i2sr.@"1";
        cnt.enable = false;
        i2sr.@"1" = cnt;

        cnt = i2sr.@"1";
        cnt.gba_volume = 0x20;
        i2sr.@"1" = cnt;

        cnt = i2sr.@"1";
        cnt.frequency = .@"32.728498046875Khz";
        cnt.master_clock = .@"8.3784955Mhz";
        i2sr.@"1" = cnt;

        cnt = i2sr.@"1";
        cnt.frequency = .@"32.728498046875Khz";
        cnt.master_clock = .@"16.756991Mhz";
        i2sr.@"1" = cnt;

        cnt = i2sr.@"1";
        cnt.enable = true;
        i2sr.@"1" = cnt;
    }

    // Same as above but set freq to ~48Khz instead
    {
        var cnt = i2sr.@"2";
        cnt.enable = false;
        i2sr.@"2" = cnt;

        cnt = i2sr.@"2";
        cnt.frequency = .@"32.728498046875Khz";
        cnt.master_clock = .@"8.3784955Mhz";
        i2sr.@"2" = cnt;

        cnt = i2sr.@"2";
        cnt.frequency = .@"47.605088068181818181818Khz";
        cnt.master_clock = .@"16.756991Mhz";
        i2sr.@"2" = cnt;

        cnt = i2sr.@"2";
        cnt.enable = true;
        i2sr.@"2" = cnt;
    }

    codec.writePageRegisterMasked(.reg(u8, 101, 0x11), 0x10, 0x1c);

    codec.setI2sVolume(.@"1", .gain(0));
    codec.setI2sVolume(.@"2", .gain(0));

    codec.setI2s1Filters(&cal.i2s_filter);
    codec.setI2s2Filters(&cal.i2s_filter);
    codec.setSinkIirFilters(.speakers_32khz, &cal.speakers_filter_32);
    codec.setSinkIirFilters(.speakers_47khz, &cal.speakers_filter_47);
    codec.setSinkIirFilters(.headphones_32khz, &cal.headphones_filter_32);
    codec.setSinkIirFilters(.headphones_47khz, &cal.headphones_filter_47);
    codec.setI2s2Powered(true);

    codec.writePageRegister(.reg(u8, 101, 0x0a), 0x0a);

    codec.writePageRegisterMasked(.dac_setup, .{ .left_powered = true, .right_powered = true }, 0xc0);
    codec.writePageRegisterMasked(.dac_volume_control, .{ .left_muted = false, .right_muted = false }, 0x0c);
    codec.writePageRegisterMasked(.i2s2_dac_volume_control, .{ .left_muted = false, .right_muted = false }, 0x0c);

    const undoc0 = codec.readPageRegister(.reg(u8, 0, 0x02));
    const undoc1 = codec.readPageRegister(.reg(u8, 0, 0x03));

    if ((undoc0 & 0xF) < 2 and ((undoc1 & 0x70) >> 4) < 3) {
        codec.writePageRegister(.reg(u8, 101, 0x0b), 0x3c);
    } else {
        codec.writePageRegister(.reg(u8, 101, 0x0b), 0x1c);
    }

    // This looks really similar to bits in TSC2117 Page 1 Register 36-40 but are not the same.
    codec.writePageRegister(.reg(u8, 101, 0x0c), cal.headphones_gain << 3 | 4);
    codec.writePageRegister(.reg([2]u8, 101, 0x16), @splat(cal.headphones_analog_volume));

    codec.writePageRegisterMasked(.reg(u8, 101, 0x11), 0xc0, 0xc0);

    codec.writePageRegister(.reg([2]u8, 101, 0x12), @splat((cal.speakers_gain << 2) | 2));
    codec.writePageRegister(.reg([2]u8, 101, 0x1b), @as([2]u8, @splat(cal.speakers_analog_volume)));

    horizon.sleepThread(38 * std.time.ns_per_ms);
    codec.setOld3dsDepopEnabled(false);

    // this is for the analog stick/circle pad & touchscreen
    codec.writePageRegister(.reg(u8, 103, 0x24), 0x98);
    codec.writePageRegister(.reg(u8, 103, 0x26), 0);
    codec.writePageRegister(.reg(u8, 103, 0x25), 0x43);
    codec.writePageRegister(.reg(u8, 103, 0x24), 0x18);
    codec.writePageRegister(.reg(u8, 103, 0x17), (cal.analog_precharge << 4) | cal.analog_sense);
    codec.writePageRegister(.reg(u8, 103, 0x19), (cal.analog_xp_pullup << 4) | cal.analog_stabilize);
    codec.writePageRegister(.reg(u8, 103, 0x1b), (cal.ym_driver << 7) | cal.analog_debounce);
    codec.writePageRegister(.reg(u8, 103, 0x27), cal.analog_interval | 0x10);
    codec.writePageRegister(.reg(u8, 103, 0x26), 0xec);
    codec.writePageRegister(.reg(u8, 103, 0x24), 0x18);
    codec.writePageRegister(.reg(u8, 103, 0x25), 0x53);
}

fn setI2s2Powered(codec: *Codec, powered: bool) void {
    codec.writePageRegisterMasked(.i2s2_dac_setup, .{ .left_powered = powered, .right_powered = powered }, 0xc0);
    horizon.sleepThread(@as(u32, if (powered) 10 else 30) * std.time.ns_per_ms);

    var poll: usize = 0;
    while (poll < 100) : (poll += 1) {
        const i2s2_dac_status = codec.readPageRegister(.i2s2_dac_status);
        if (i2s2_dac_status.right_powered == powered and i2s2_dac_status.left_powered == powered) break;
        horizon.sleepThread(1 * std.time.ns_per_ms);
    }
}

fn stopUnknown(codec: *Codec) void {
    codec.writePageRegisterMasked(.reg(u8, 101, 0x22), 2, 2);
    horizon.sleepThread(30 * std.time.ns_per_ms);

    var poll: usize = 0;
    while (poll < 100) : (poll += 1) {
        if ((codec.readPageRegister(.reg(u8, 100, 0x22)) & 1) != 0) break;
        horizon.sleepThread(1 * std.time.ns_per_ms);
    }
}

fn startUnknown(codec: *Codec) void {
    codec.writePageRegisterMasked(.reg(u8, 101, 0x22), 0, 2);
    horizon.sleepThread(40 * std.time.ns_per_ms);

    var poll: usize = 0;
    while (poll < 40) : (poll += 1) {
        if ((codec.readPageRegister(.reg(u8, 100, 0x22)) & 1) == 0) break;
        horizon.sleepThread(1 * std.time.ns_per_ms);
    }
}

// May turn on/off the Mic?
pub fn set3DSMicBias(codec: *Codec, bias: bool) void {
    codec.writePageRegisterMasked(.reg(u8, 101, 0x33), if (bias) 0x10 else 0x00, 0x30);
}

pub fn setMicPowered(codec: *Codec, powered: bool) void {
    if (powered) {
        codec.writePageRegister(.mic_bias, .{ .power = .avdd });
        codec.setMicAdcPower(true, 100);
        codec.writePageRegisterMasked(.mic_volume_fine, .{ .adc_muted = false }, 0x80);
        return;
    }

    codec.writePageRegisterMasked(.mic_volume_fine, .{ .adc_muted = true }, 0x80);
    codec.setMicAdcPower(false, 0);
    codec.writePageRegister(.mic_bias, .{ .power = .down });
}

pub fn setMicAdcPower(codec: *Codec, powered: bool, wait: usize) void {
    codec.writePageRegisterMasked(.mic_control, .{ .adc_powered = powered }, 0x80);

    var poll: usize = 0;
    while (poll < wait) : (poll += 1) {
        if (codec.readPageRegister(.mic_adc_status).adc_powered == powered) break;
        horizon.sleepThread(1 * std.time.ns_per_ms);
    }
}

pub fn setMicGain(codec: *Codec, gain: u7) void {
    codec.writePageRegister(.mic_pga, .{ .gain = .gain(gain), .disabled = false });
}

pub fn getMicGain(codec: *Codec) u7 {
    return @intFromEnum(codec.readPageRegister(.mic_pga).gain);
}

pub fn setMicIirFilter(codec: *Codec, filter: *const [5]hw.Biquad) void {
    var be_filter: [5]hw.Biquad = filter.*;
    std.mem.byteSwapAllElements(hw.Biquad, &be_filter);

    const was_powered = codec.readPageRegister(.mic_control).adc_powered;

    codec.writePageRegisterMasked(.mic_volume_fine, .{ .adc_muted = true }, 0x80);
    codec.setMicAdcPower(false, 20);

    codec.writePageRegister(.mic_adc_biquad_abcde, be_filter);

    if (was_powered) {
        codec.setMicAdcPower(true, 100);
        codec.writePageRegisterMasked(.mic_volume_fine, .{ .adc_muted = false }, 0x80);
    }
}

pub fn setHeadphoneOutput(codec: *Codec, enable: bool) void {
    codec.writePageRegisterMasked(.reg(u8, 100, 0x45), (@as(u8, (@intFromBool(enable))) << 4) | 0x20, 0x30);
}

pub fn initLegacy(codec: *Codec) void {
    codec.setMicPowered(true);
    codec.writePageRegister(.reg(u8, 3, 0x03), 0);
    codec.writePageRegisterMasked(.mic_volume_fine, .{ .adc_muted = true }, 0x80);
    codec.writePageRegisterMasked(.mic_control, .{ .adc_powered = false }, 0x80);
    codec.writePageRegister(.reg(u8, 255, 0x05), 0);
}

pub fn setI2sVolume(codec: *Codec, line: zitrus.hardware.i2s.Line, gain: hw.i2s.Gain) void {
    switch (line) {
        .@"1" => codec.writePageRegister(.i2s1_volume, gain),
        .@"2" => codec.writePageRegister(.i2s2_volume, gain),
    }
}

pub fn getI2sVolume(codec: *Codec, line: zitrus.hardware.i2s.Line) hw.i2s.Gain {
    return switch (line) {
        .@"1" => codec.readPageRegister(.i2s1_volume),
        .@"2" => codec.readPageRegister(.i2s2_volume),
    };
}

pub fn setOld3dsDepopEnabled(codec: *Codec, enable: bool) void {
    if (codec.system_model == .ctr) {
        assertResult(codec.gpio.sendWithResult(.SetDirection, .init(.init(.{ .@"ctr_depop/new_hid" = .output }), .init(.{ .@"ctr_depop/new_hid" = true })), .{}));
        assertResult(codec.gpio.sendWithResult(.SetData, .init(.init(.{ .@"ctr_depop/new_hid" = enable }), .init(.{ .@"ctr_depop/new_hid" = true })), .{}));
    }

    const sleep_ms: u32 = if (enable) 10 else 18;
    horizon.sleepThread(sleep_ms * std.time.ns_per_ms);
}

pub fn setSinkIirFilters(codec: *Codec, sink: cdc.Dsp.Sink, filter: *const [3]Calibration.Biquad) void {
    var be_filter: [3]Calibration.Biquad = filter.*;
    std.mem.byteSwapAllElements(Calibration.Biquad, &be_filter);

    switch (sink) {
        .headphones_32khz => {
            codec.writePageRegister(.headphones_left_32khz_biquads, be_filter);
            codec.writePageRegister(.headphones_right_32khz_biquads, be_filter);
        },
        .headphones_47khz => {
            codec.writePageRegister(.headphones_left_47khz_biquads, be_filter);
            codec.writePageRegister(.headphones_right_47khz_biquads, be_filter);
        },
        .speakers_32khz => {
            codec.writePageRegister(.speakers_left_32khz_biquads, be_filter);
            codec.writePageRegister(.speakers_right_32khz_biquads, be_filter);
        },
        .speakers_47khz => {
            codec.writePageRegister(.speakers_left_47khz_biquads, be_filter);
            codec.writePageRegister(.speakers_right_47khz_biquads, be_filter);
        },
    }
}

pub fn setI2s1Filters(codec: *Codec, filter: *const Calibration.IirBiquad) void {
    const volume: hw.dac.Gain.Control = codec.readPageRegister(.dac_volume_control);

    var be_filter: Calibration.IirBiquad = filter.*;
    std.mem.byteSwapAllFields(Calibration.IirBiquad, &be_filter);

    codec.writePageRegisterMasked(.dac_setup, .{ .left_powered = false, .right_powered = false }, 0xc0);
    codec.writePageRegisterMasked(.dac_volume_control, .{ .left_muted = true, .right_muted = true }, 0x0c);

    {
        var poll: usize = 0;
        while (poll < 100) : (poll += 1) {
            const i2s_status = codec.readPageRegister(.i2s_status);
            if ((i2s_status.i2s1_left_muted and i2s_status.i2s1_right_muted)) break;
            horizon.sleepThread(1 * std.time.ns_per_ms);
        }
    }

    codec.writePageRegister(.dac_left_iir, be_filter.iir);
    codec.writePageRegister(.dac_left_biquad_bcdef, be_filter.biquads);

    codec.writePageRegister(.dac_right_iir, be_filter.iir);
    codec.writePageRegister(.dac_right_biquad_bcdef, be_filter.biquads);

    if (!(volume.left_muted and volume.right_muted)) {
        codec.writePageRegisterMasked(.dac_setup, .{ .left_powered = true, .right_powered = true }, 0xc0);
        codec.writePageRegisterMasked(.dac_volume_control, .{ .left_muted = false, .right_muted = false }, 0x0c);
    }
}

fn setI2s2Filters(codec: *Codec, filter: *const hw.IirBiquad) void {
    const i2s2_cnt = codec.readPageRegister(.i2s2_dac_volume_control);

    var be_filter: Calibration.IirBiquad = filter.*;
    std.mem.byteSwapAllFields(hw.IirBiquad, &be_filter);

    codec.writePageRegisterMasked(.i2s2_dac_volume_control, .{ .left_muted = true, .right_muted = true }, 0x0c);

    {
        var poll: usize = 0;
        while (poll < 100) : (poll += 1) {
            const i2s_status = codec.readPageRegister(.i2s_status);
            if ((i2s_status.i2s2_left_muted and i2s_status.i2s2_right_muted)) break;
            horizon.sleepThread(1 * std.time.ns_per_ms);
        }
    }

    codec.writePageRegister(.i2s2_iir, be_filter.iir);
    codec.writePageRegister(.i2s2_biquads, be_filter.biquads);

    if (!(i2s2_cnt.left_muted and i2s2_cnt.right_muted)) {
        codec.writePageRegisterMasked(.i2s2_dac_volume_control, .{ .left_muted = false, .right_muted = false }, 0x0c);
    }
}

pub fn setTouchEnabled(codec: *Codec, enable: bool) void {
    if (enable) {
        codec.writePageRegisterMasked(.reg(u8, 103, 0x24), 0x00, 0x80);
        codec.writePageRegisterMasked(.reg(u8, 103, 0x26), 0x80, 0x80);
        codec.writePageRegisterMasked(.reg(u8, 103, 0x25), 0x10, 0x3c);
        return;
    }

    codec.writePageRegisterMasked(.reg(u8, 103, 0x26), 0x00, 0x80);
    codec.writePageRegisterMasked(.reg(u8, 103, 0x24), 0x80, 0x80);
}

pub fn isTouchEnabled(codec: *Codec) bool {
    return (codec.readPageRegister(.reg(u8, 103, 0x24)) & 0x80) == 0;
}

pub fn setTouch3ds(codec: *Codec, is_3ds: bool) void {
    if (is_3ds) {
        pdnr.legacy.emulated_gpio_mask.touch_released = true;
        pdnr.legacy.emulated_gpio.touch_released = true;
        codec.writePageRegisterMasked(.reg(u8, 103, 0x25), 0x40, 0x40);
        return;
    }

    pdnr.legacy.emulated_gpio_mask.touch_released = false;
    codec.writePageRegisterMasked(.reg(u8, 103, 0x25), 0x00, 0x40);
}

pub fn isTouch3DS(codec: *Codec) bool {
    return (codec.readPageRegister(.reg(u8, 103, 0x25)) & 0x40) != 0;
}

pub fn pollHidReport(codec: *Codec) ?cdc.Hid.Report {
    const Report = cdc.Hid.Report;

    var final: Report = undefined;
    if ((codec.readPageRegister(.reg(u8, 103, 0x26)) & 2) != 0) {
        codec.selectPage(.@"3ds_tsc", 0);
        return null;
    }

    var report: hw.CircleTouchReport = codec.readPageRegister(.reg(hw.CircleTouchReport, 251, 0x01));

    const all_available: bool = all: for (&report.touch_x, &report.touch_y) |x, y| {
        if ((x & 0x00F0) != 0 or (y & 0x00F0) != 0) break :all false;
    } else true;

    const available = codec.all_touch_entries_were_available and all_available;
    final.touch = .{ .x = 0, .y = 0, .down = available, .inaccurate = !available };
    codec.all_touch_entries_were_available = all_available;

    if (final.touch.down) touch: {
        std.mem.byteSwapAllElements(u16, &report.touch_x);
        std.mem.byteSwapAllElements(u16, &report.touch_y);

        const any_up: bool = any: for (&report.touch_x, &report.touch_y) |x, y| {
            if (x == 0xFFF or y == 0xFFF) break :any true;
        } else false;

        // ? this doesn't make much sense but ok
        if (any_up or std.mem.eql(u16, &codec.last_circle_x, report.touch_x[0..codec.last_circle_x.len])) {
            final.touch = .{ .x = 0, .y = 0, .down = true, .inaccurate = true };
            break :touch;
        }

        var touches_sampled: u32 = 0;
        var acc_x: u32 = 0;
        var acc_y: u32 = 0;
        for (0..4) |i| {
            const first_x = report.touch_x[i];
            const first_y = report.touch_y[i];

            touches_sampled = 0;
            acc_x = first_x;
            acc_y = first_y;

            for (&report.touch_x, &report.touch_y, 0..) |x, y, j| {
                if (i == j) continue;

                const diff_x = (@as(i32, first_x) - x);
                const diff_y = (@as(i32, first_y) - y);

                if (diff_x < -19 or diff_x > 19 or diff_y < -19 or diff_y > 19) continue;

                touches_sampled += 1;
                acc_x += x;
                acc_y += y;
            }

            if (touches_sampled >= 2) break;
        }

        const avg_x: u12 = @truncate(acc_x / (touches_sampled + 1));
        const avg_y: u12 = @truncate(acc_y / (touches_sampled + 1));

        final.touch = .{
            .x = avg_x,
            .y = avg_y,
            .down = true,
            .inaccurate = touches_sampled < 2,
        };
    }

    var acc_x: u32 = 0;
    var acc_y: u32 = 0;
    for (&report.circle_x, &report.circle_y) |*x, *y| {
        x.* = (@byteSwap(x.*) & 0xFFF);
        y.* = (@byteSwap(y.*) & 0xFFF);

        acc_x += x.*;
        acc_y += y.*;
    }

    // ? this doesn't make much sense but ok
    @memcpy(&codec.last_circle_x, report.circle_x[4..][0..codec.last_circle_x.len]);

    final.circle = .{
        .x = ~@as(u12, @truncate(acc_x >> 3)),
        .y = @truncate(acc_y >> 3),
    };

    return final;
}

pub fn waitPageRegisterMaskedValue(codec: *Codec, dev: Spi.Device, page: u8, register: u8, value: u8, mask: u8) void {
    var i: usize = 0;

    codec.selectPage(dev, page);

    var register_value: u8 = undefined;

    while (i < 64) : (i += 1) {
        register_value = codec.spi.sendWithResult(.SendCommandRead, .init(dev, &.{register << 1 | 1}, 1), .{}).value.slice[0];
        _ = codec.spi.sendWithResult(.SendCommandWrite, .init(dev, &.{register << 1}, &.{(value & mask) | (register_value & ~mask)}), .{});
        register_value = codec.spi.sendWithResult(.SendCommandRead, .init(dev, &.{register << 1 | 1}, 1), .{}).value.slice[0];

        if ((register_value & mask) == value) break;
    }
}

pub fn readPageRegister(codec: *Codec, comptime register: hw.Register) register.type.* {
    // TODO: use toBackingInt in zig 0.17.0
    var value: register.type.* = undefined;
    codec.rawReadPageRegisters(.@"3ds_tsc", register.page, register.register, @ptrCast(&value));
    return value;
}

pub fn writePageRegister(codec: *Codec, comptime register: hw.Register, value: register.type.*) void {
    const as_u8: []const u8 = @ptrCast(&value);
    codec.rawWritePageRegisters(.@"3ds_tsc", register.page, register.register, as_u8);
}

pub fn writePageRegisterMasked(codec: *Codec, comptime register: hw.Register, value: register.type.*, mask: u8) void {
    comptime std.debug.assert(@sizeOf(register.type.*) == 1); // Must be 1 byte to mask!

    // TODO: use fromBackingInt in zig 0.17.0
    const as_u8: u8 = switch (@typeInfo(register.type.*)) {
        .@"enum" => @intFromEnum(value),
        else => @bitCast(value),
    };

    codec.rawWritePageRegisterMasked(.@"3ds_tsc", register.page, register.register, as_u8, mask);
}

pub fn selectPage(codec: *Codec, dev: Spi.Device, page: u8) void {
    _ = codec.spi.sendWithResult(.SendCommandWrite, .init(dev, &.{0}, &.{page}), .{});
}

pub fn rawReadPageRegisters(codec: *Codec, dev: Spi.Device, page: u8, register: u8, buffer: []u8) void {
    codec.selectPage(dev, page);
    @memcpy(buffer, codec.spi.sendWithResult(.SendCommandRead, .init(dev, &.{register << 1 | 1}, buffer.len), .{}).value.slice[0..buffer.len]);
}

pub fn rawWritePageRegisterMasked(codec: *Codec, dev: Spi.Device, page: u8, register: u8, value: u8, mask: u8) void {
    codec.selectPage(dev, page);
    const register_value: u8 = codec.spi.sendWithResult(.SendCommandRead, .init(dev, &.{register << 1 | 1}, 1), .{}).value.slice[0];
    _ = codec.spi.sendWithResult(.SendCommandWrite, .init(dev, &.{register << 1}, &.{(value & mask) | (register_value & ~mask)}), .{});
}

pub fn rawWritePageRegisters(codec: *Codec, dev: Spi.Device, page: u8, register: u8, values: []const u8) void {
    codec.selectPage(dev, page);
    _ = codec.spi.sendWithResult(.SendCommandWrite, .init(dev, &.{register << 1}, values), .{});
}

pub fn readPowerManagement(codec: *Codec, index: u8) u8 {
    return codec.spi.sendWithResult(.SendCommandRead, .init(.power_management, &.{0x80 | index}, 1), .{}).value.slice[0];
}

pub fn writePowerManagement(codec: *Codec, index: u8, value: u8) void {
    _ = codec.spi.sendWithResult(.SendCommandWrite, .init(.power_management, &.{index}, &.{value}), .{});
}

fn irqEntry(ctx: ?*anyopaque) callconv(.c) noreturn {
    const codec: *Codec = @ptrCast(@alignCast(ctx));
    horizon.tls.initVariables(codec.irq_stack_tls);

    while (true) {
        assertCode(horizon.waitSynchronization(codec.irq_poll_timer.sync, .none));
        if (codec.irq_thread_stop.load(.monotonic)) break;

        codec.updateSink();
    }

    horizon.exitThread();
}

fn updateSink(codec: *Codec) void {
    codec.mut.lock(env.arbiter);
    defer codec.mut.unlock(env.arbiter);

    const sync_res = horizon.waitSynchronization(codec.headphones_irq.int.sync, .fromNanoseconds(0));
    assertCode(sync_res);

    if (sync_res.description != .timeout) {
        assertCode(horizon.clearEvent(codec.headphones_irq));

        codec.writePageRegisterMasked(.ctr_headset, .{ .detection = false }, 0x80);
        codec.writePageRegisterMasked(.ctr_headset, .{ .detection = true }, 0x80);
    }

    const headphones_connected = assertResult(codec.gpio.sendWithResult(.GetData, .init(.{ .headphones_inserted = true }), .{})).int() != 0;

    if (codec.headphones_connected.load(.monotonic) == headphones_connected) {
        codec.irq_polls_with_same_state = 0;
        return;
    }

    codec.irq_polls_with_same_state += 1;
    if (codec.irq_polls_with_same_state > 4) {
        codec.headphones_connected.store(headphones_connected, .monotonic);
        codec.irq_polls_with_same_state = 0;

        if (!codec.forced_headphone_output) codec.setHeadphoneOutput(headphones_connected);
    }
}

const Codec = @This();

const Calibration = horizon.fmt.hwcal.Codec;

const assertResult = ErrorDisplayManager.assertResult;
const assertCode = ErrorDisplayManager.assertCode;

const env = @import("env.zig");

const std = @import("std");
const zitrus = @import("zitrus");
const horizon = zitrus.horizon;
const ServiceManager = horizon.ServiceManager;
const ErrorDisplayManager = horizon.ErrorDisplayManager;

const Spi = horizon.services.Spi;
const Cfg = horizon.services.Cfg;
const Gpio = horizon.services.Gpio;
const PdnI2s = horizon.services.pdn.I2s;
const Mcu = horizon.services.mcu.Codec;
const cdc = horizon.services.cdc;

const hw = zitrus.hardware.codec;
const i2sr = horizon.memory.i2s;
const pdnr = horizon.memory.pdn;
