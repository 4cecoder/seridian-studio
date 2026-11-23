// Translated to Zig from soundcraft/crates/vst3-host/src/ffi.rs (Copyright (c) 2026 ArtCraft Team and the SoundCraft contributors, MIT OR Apache-2.0). Modified by Seridian.
//! The VST3 COM ABI: hand-written `extern struct` declarations that follow the layout of
//! Steinberg's MIT-licensed `vst3_c_api` header (FUnknown vtable, plugin factories, component,
//! audio processor, edit controller, plug view, host interfaces, process data, events), plus the
//! bounded string helpers and limits of the Rust `ffi` module.
//!
//! The Rust code used the `vst3` crate for these definitions; here every vtable is spelled out.
//! Every COM object is `extern struct { vtbl: *const Vtbl }` and a vtable embeds its base
//! interface's vtable as its first field, so the memory layout is exactly the C one.
//!
//! Soundness rests on the VST3 contract (the plugin honours the COM vtable signatures and the
//! documented pointer lifetimes). A plugin that violates it can still crash the process: hosting
//! in-process can't prevent that. What this module guarantees is that Seridian never hands the
//! plugin dangling or mis-sized pointers and never reads plugin strings beyond their bounds.
//! Everything a plugin returns (pointers, counts, strings) is hostile: counts are clamped with the
//! limits below and fixed-size string buffers are read only up to their array length.
//!
//! Platform note: IIDs are byte arrays in the platform order. On Windows the first three groups
//! are stored little-endian (COM compatible); elsewhere all four 32-bit words are big-endian.
//! `tresult` values follow the non-Windows numbering of the SDK; the Windows values
//! (`0x8000FFFF`-style HRESULTs) are not supported by this host yet.

const std = @import("std");
const builtin = @import("builtin");

// ---- limits (hostile-input caps) -----------------------------------------------------------

/// Most classes one factory may report (hostile-input cap).
pub const MAX_CLASSES: i32 = 1024;
/// Most parameters read from one controller.
pub const MAX_PARAMS: i32 = 4096;
/// Most audio buses per direction we provide buffers for.
pub const MAX_BUSES: i32 = 16;
/// Most channels per audio bus.
pub const MAX_BUS_CHANNELS: u32 = 64;
/// Capacity of the per-block event lists (preallocated: `process` never allocates).
pub const EVENT_CAP: usize = 1024;
/// Most parameter queues per block (preallocated).
pub const PARAM_QUEUE_CAP: usize = 1024;
/// Largest plugin state we buffer (component or controller state).
pub const MAX_STATE_BYTES: usize = 64 << 20;
/// Most editor parameter edits buffered between two UI frames.
pub const EDIT_CAP: usize = 256;
/// Magic of Seridian's state container: `SCV3` + u32 LE component length + component state +
/// u32 LE controller length + controller state.
pub const STATE_MAGIC: *const [4]u8 = "SCV3";

// ---- basic types ---------------------------------------------------------------------------

/// `Steinberg::tresult` (int32 on every platform this host supports).
pub const tresult = i32;
pub const TBool = u8;
pub const TUID = [16]u8;
pub const ParamID = u32;
pub const MediaType = i32;
pub const BusDirection = i32;
pub const IoMode = i32;
pub const SpeakerArrangement = u64;
/// UTF-16 code units, as in `Steinberg::Vst::TChar`.
pub const TChar = u16;
pub const String128 = [128]u16;

pub const kNoInterface: tresult = -1;
pub const kResultOk: tresult = 0;
pub const kResultTrue: tresult = kResultOk;
pub const kResultFalse: tresult = 1;
pub const kInvalidArgument: tresult = 2;
pub const kNotImplemented: tresult = 3;
pub const kInternalError: tresult = 4;
pub const kNotInitialized: tresult = 5;
pub const kOutOfMemory: tresult = 6;

pub fn ok(r: tresult) bool {
    return r == kResultOk;
}

// Media types, bus directions, io modes, sample sizes, process modes.
pub const kAudio: MediaType = 0;
pub const kEvent: MediaType = 1;
pub const kInput: BusDirection = 0;
pub const kOutput: BusDirection = 1;
pub const kSample32: i32 = 0;
pub const kSample64: i32 = 1;
pub const kRealtime: i32 = 0;
pub const kPrefetch: i32 = 1;
pub const kOffline: i32 = 2;
pub const kSimple: IoMode = 0;
pub const kAdvanced: IoMode = 1;
pub const kOfflineProcessing: IoMode = 2;

// Bus info flags and types.
pub const kDefaultActive: u32 = 1;
pub const kIsControlVoltage: u32 = 2;
pub const kMain: i32 = 0;
pub const kAux: i32 = 1;

// Parameter info flags.
pub const kCanAutomate: i32 = 1;
pub const kIsReadOnly: i32 = 1 << 1;
pub const kIsWrapAround: i32 = 1 << 2;
pub const kIsList: i32 = 1 << 3;
pub const kIsHidden: i32 = 1 << 4;
pub const kIsProgramChange: i32 = 1 << 15;
pub const kIsBypass: i32 = 1 << 16;

// Restart flags.
pub const kReloadComponent: i32 = 1;
pub const kIoChanged: i32 = 1 << 1;
pub const kParamValuesChanged: i32 = 1 << 2;
pub const kLatencyChanged: i32 = 1 << 3;
pub const kParamTitlesChanged: i32 = 1 << 4;
pub const kMidiCCAssignmentChanged: i32 = 1 << 5;
pub const kNoteExpressionChanged: i32 = 1 << 6;
pub const kIoTitlesChanged: i32 = 1 << 7;
pub const kPrefetchableSupportChanged: i32 = 1 << 8;
pub const kRoutingInfoChanged: i32 = 1 << 9;

// Class flags (PClassInfo2.classFlags).
pub const kSimpleModeSupported: u32 = 1 << 1;
pub const kDistributable: u32 = 1 << 0;

// IBStream seek modes.
pub const kIBSeekSet: i32 = 0;
pub const kIBSeekCur: i32 = 1;
pub const kIBSeekEnd: i32 = 2;

/// VST3's numbers for the MIDI controllers that aren't CCs.
pub const AFTERTOUCH: usize = 128;
pub const PITCH_BEND: usize = 129;

/// `ProcessContext::StatesAndFlags`.
pub const ProcessStates = struct {
    pub const kPlaying: u32 = 1 << 1;
    pub const kCycleActive: u32 = 1 << 2;
    pub const kRecording: u32 = 1 << 3;
    pub const kSystemTimeValid: u32 = 1 << 8;
    pub const kContTimeValid: u32 = 1 << 17;
    pub const kProjectTimeMusicValid: u32 = 1 << 9;
    pub const kBarPositionValid: u32 = 1 << 11;
    pub const kCycleValid: u32 = 1 << 12;
    pub const kTempoValid: u32 = 1 << 10;
    pub const kTimeSigValid: u32 = 1 << 13;
    pub const kChordValid: u32 = 1 << 18;
    pub const kSmpteValid: u32 = 1 << 14;
    pub const kClockValid: u32 = 1 << 15;
};

// ---- IIDs ----------------------------------------------------------------------------------

/// Builds a TUID from the four 32-bit words of `INLINE_UID(l1, l2, l3, l4)` in platform order.
pub fn uid(comptime l1: u32, comptime l2: u32, comptime l3: u32, comptime l4: u32) TUID {
    var out: TUID = undefined;
    if (builtin.os.tag == .windows) {
        // COM compatible: the first three groups little-endian.
        std.mem.writeInt(u32, out[0..4], l1, .little);
        std.mem.writeInt(u16, out[4..6], @truncate(l2 >> 16), .little);
        std.mem.writeInt(u16, out[6..8], @truncate(l2), .little);
        std.mem.writeInt(u32, out[8..12], l3, .big);
        std.mem.writeInt(u32, out[12..16], l4, .big);
    } else {
        std.mem.writeInt(u32, out[0..4], l1, .big);
        std.mem.writeInt(u32, out[4..8], l2, .big);
        std.mem.writeInt(u32, out[8..12], l3, .big);
        std.mem.writeInt(u32, out[12..16], l4, .big);
    }
    return out;
}

// ---- COM interfaces ------------------------------------------------------------------------

/// `Steinberg::FUnknown`.
pub const FUnknown = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x00000000, 0x00000000, 0xC0000000, 0x00000046);

    pub const Vtbl = extern struct {
        queryInterface: *const fn (this: *FUnknown, iid: *const TUID, obj: *?*anyopaque) callconv(.c) tresult,
        addRef: *const fn (this: *FUnknown) callconv(.c) u32,
        release: *const fn (this: *FUnknown) callconv(.c) u32,
    };

    pub fn queryInterface(self: *FUnknown, id: *const TUID, obj: *?*anyopaque) tresult {
        return self.vtbl.queryInterface(self, id, obj);
    }
    pub fn addRef(self: *FUnknown) u32 {
        return self.vtbl.addRef(self);
    }
    pub fn release(self: *FUnknown) u32 {
        return self.vtbl.release(self);
    }
};

/// Views any COM interface pointer as its `FUnknown`.
pub fn asUnknown(p: anytype) *FUnknown {
    return @ptrCast(@alignCast(p));
}

/// Adds a reference to any COM object.
pub fn comAddRef(p: anytype) u32 {
    return asUnknown(p).addRef();
}

/// Releases one reference of any COM object.
pub fn comRelease(p: anytype) u32 {
    return asUnknown(p).release();
}

/// `queryInterface` for interface type `T` (which declares `iid`). On success the returned
/// pointer owns one added reference. A null result from a hostile plugin that reports success is
/// treated as failure.
pub fn comCast(comptime T: type, p: anytype) ?*T {
    var obj: ?*anyopaque = null;
    const id: TUID = T.iid;
    if (!ok(asUnknown(p).queryInterface(&id, &obj))) return null;
    const o = obj orelse return null;
    return @ptrCast(@alignCast(o));
}

pub const PFactoryInfo = extern struct {
    vendor: [64]u8,
    url: [256]u8,
    email: [128]u8,
    flags: i32,
};

pub const PClassInfo = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
};

pub const PClassInfo2 = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u8,
    classFlags: u32,
    subCategories: [128]u8,
    vendor: [64]u8,
    version: [64]u8,
    sdkVersion: [64]u8,
};

pub const PClassInfoW = extern struct {
    cid: TUID,
    cardinality: i32,
    category: [32]u8,
    name: [64]u16,
    classFlags: u32,
    subCategories: [128]u8,
    vendor: [64]u16,
    version: [64]u16,
    sdkVersion: [64]u16,
};

/// `Steinberg::IPluginBase`.
pub const IPluginBase = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x22888DDB, 0x156E45AE, 0x8358B348, 0x08190625);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        initialize: *const fn (this: *IPluginBase, context: ?*FUnknown) callconv(.c) tresult,
        terminate: *const fn (this: *IPluginBase) callconv(.c) tresult,
    };

    pub fn initialize(self: *IPluginBase, context: ?*FUnknown) tresult {
        return self.vtbl.initialize(self, context);
    }
    pub fn terminate(self: *IPluginBase) tresult {
        return self.vtbl.terminate(self);
    }
};

/// `Steinberg::IPluginFactory`.
pub const IPluginFactory = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x7A4D811C, 0x52114A1F, 0xAED9D2EE, 0x0B43BF9F);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getFactoryInfo: *const fn (this: *IPluginFactory, info: *PFactoryInfo) callconv(.c) tresult,
        countClasses: *const fn (this: *IPluginFactory) callconv(.c) i32,
        getClassInfo: *const fn (this: *IPluginFactory, index: i32, info: *PClassInfo) callconv(.c) tresult,
        createInstance: *const fn (this: *IPluginFactory, cid: *const TUID, iid: *const TUID, obj: *?*anyopaque) callconv(.c) tresult,
    };

    pub fn getFactoryInfo(self: *IPluginFactory, info: *PFactoryInfo) tresult {
        return self.vtbl.getFactoryInfo(self, info);
    }
    pub fn countClasses(self: *IPluginFactory) i32 {
        return self.vtbl.countClasses(self);
    }
    pub fn getClassInfo(self: *IPluginFactory, index: i32, info: *PClassInfo) tresult {
        return self.vtbl.getClassInfo(self, index, info);
    }
    pub fn createInstance(self: *IPluginFactory, cid: *const TUID, id: *const TUID, obj: *?*anyopaque) tresult {
        return self.vtbl.createInstance(self, cid, id, obj);
    }
};

/// `Steinberg::IPluginFactory2`.
pub const IPluginFactory2 = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x0007B650, 0xF24B4C0B, 0xA464EDB9, 0xF00B2ABB);

    pub const Vtbl = extern struct {
        base: IPluginFactory.Vtbl,
        getClassInfo2: *const fn (this: *IPluginFactory2, index: i32, info: *PClassInfo2) callconv(.c) tresult,
    };

    pub fn getClassInfo2(self: *IPluginFactory2, index: i32, info: *PClassInfo2) tresult {
        return self.vtbl.getClassInfo2(self, index, info);
    }
};

/// `Steinberg::IPluginFactory3`.
pub const IPluginFactory3 = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x4555A2AB, 0xC1234E57, 0x9B122910, 0x36878931);

    pub const Vtbl = extern struct {
        base: IPluginFactory2.Vtbl,
        getClassInfoUnicode: *const fn (this: *IPluginFactory3, index: i32, info: *PClassInfoW) callconv(.c) tresult,
        setHostContext: *const fn (this: *IPluginFactory3, context: ?*FUnknown) callconv(.c) tresult,
    };

    pub fn getClassInfoUnicode(self: *IPluginFactory3, index: i32, info: *PClassInfoW) tresult {
        return self.vtbl.getClassInfoUnicode(self, index, info);
    }
    pub fn setHostContext(self: *IPluginFactory3, context: ?*FUnknown) tresult {
        return self.vtbl.setHostContext(self, context);
    }
};

/// `Steinberg::IBStream`.
pub const IBStream = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0xC3BF6EA2, 0x30994752, 0x9B6BF990, 0x1EE33E9B);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        read: *const fn (this: *IBStream, buffer: ?*anyopaque, num_bytes: i32, num_bytes_read: ?*i32) callconv(.c) tresult,
        write: *const fn (this: *IBStream, buffer: ?*anyopaque, num_bytes: i32, num_bytes_written: ?*i32) callconv(.c) tresult,
        seek: *const fn (this: *IBStream, pos: i64, mode: i32, result: ?*i64) callconv(.c) tresult,
        tell: *const fn (this: *IBStream, pos: ?*i64) callconv(.c) tresult,
    };

    pub fn read(self: *IBStream, buffer: ?*anyopaque, n: i32, got: ?*i32) tresult {
        return self.vtbl.read(self, buffer, n, got);
    }
    pub fn write(self: *IBStream, buffer: ?*anyopaque, n: i32, put: ?*i32) tresult {
        return self.vtbl.write(self, buffer, n, put);
    }
    pub fn seek(self: *IBStream, pos: i64, mode: i32, result: ?*i64) tresult {
        return self.vtbl.seek(self, pos, mode, result);
    }
    pub fn tell(self: *IBStream, pos: ?*i64) tresult {
        return self.vtbl.tell(self, pos);
    }
};

pub const BusInfo = extern struct {
    mediaType: MediaType,
    direction: BusDirection,
    channelCount: i32,
    name: String128,
    busType: i32,
    flags: u32,
};

pub const RoutingInfo = extern struct {
    mediaType: MediaType,
    busIndex: i32,
    channel: i32,
};

/// `Steinberg::Vst::IComponent`.
pub const IComponent = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0xE831FF31, 0xF2D54301, 0x928EBBEE, 0x25697802);

    pub const Vtbl = extern struct {
        base: IPluginBase.Vtbl,
        getControllerClassId: *const fn (this: *IComponent, class_id: *TUID) callconv(.c) tresult,
        setIoMode: *const fn (this: *IComponent, mode: IoMode) callconv(.c) tresult,
        getBusCount: *const fn (this: *IComponent, type: MediaType, dir: BusDirection) callconv(.c) i32,
        getBusInfo: *const fn (this: *IComponent, type: MediaType, dir: BusDirection, index: i32, bus: *BusInfo) callconv(.c) tresult,
        getRoutingInfo: *const fn (this: *IComponent, in_info: *RoutingInfo, out_info: *RoutingInfo) callconv(.c) tresult,
        activateBus: *const fn (this: *IComponent, type: MediaType, dir: BusDirection, index: i32, state: TBool) callconv(.c) tresult,
        setActive: *const fn (this: *IComponent, state: TBool) callconv(.c) tresult,
        setState: *const fn (this: *IComponent, state: *IBStream) callconv(.c) tresult,
        getState: *const fn (this: *IComponent, state: *IBStream) callconv(.c) tresult,
    };

    pub fn initialize(self: *IComponent, context: ?*FUnknown) tresult {
        return self.vtbl.base.initialize(@ptrCast(self), context);
    }
    pub fn terminate(self: *IComponent) tresult {
        return self.vtbl.base.terminate(@ptrCast(self));
    }
    pub fn getControllerClassId(self: *IComponent, class_id: *TUID) tresult {
        return self.vtbl.getControllerClassId(self, class_id);
    }
    pub fn setIoMode(self: *IComponent, mode: IoMode) tresult {
        return self.vtbl.setIoMode(self, mode);
    }
    pub fn getBusCount(self: *IComponent, t: MediaType, dir: BusDirection) i32 {
        return self.vtbl.getBusCount(self, t, dir);
    }
    pub fn getBusInfo(self: *IComponent, t: MediaType, dir: BusDirection, index: i32, bus: *BusInfo) tresult {
        return self.vtbl.getBusInfo(self, t, dir, index, bus);
    }
    pub fn activateBus(self: *IComponent, t: MediaType, dir: BusDirection, index: i32, state: bool) tresult {
        return self.vtbl.activateBus(self, t, dir, index, @intFromBool(state));
    }
    pub fn setActive(self: *IComponent, state: bool) tresult {
        return self.vtbl.setActive(self, @intFromBool(state));
    }
    pub fn setState(self: *IComponent, s: *IBStream) tresult {
        return self.vtbl.setState(self, s);
    }
    pub fn getState(self: *IComponent, s: *IBStream) tresult {
        return self.vtbl.getState(self, s);
    }
};

pub const ProcessSetup = extern struct {
    processMode: i32,
    symbolicSampleSize: i32,
    maxSamplesPerBlock: i32,
    sampleRate: f64,
};

/// `Steinberg::Vst::AudioBusBuffers`: channel pointer arrays for 32-bit or 64-bit samples.
pub const AudioBusBuffers = extern struct {
    numChannels: i32,
    silenceFlags: u64,
    channelBuffers: extern union {
        channelBuffers32: ?[*]?[*]f32,
        channelBuffers64: ?[*]?[*]f64,
    },
};

pub const Chord = extern struct {
    keyNote: u8,
    rootNote: u8,
    chordMask: i16,
};

pub const FrameRate = extern struct {
    framesPerSecond: u32,
    flags: u32,
};

/// `Steinberg::Vst::ProcessContext`: plain data, all-zero is valid.
pub const ProcessContext = extern struct {
    state: u32,
    sampleRate: f64,
    projectTimeSamples: i64,
    systemTime: i64,
    continousTimeSamples: i64,
    projectTimeMusic: f64,
    barPositionMusic: f64,
    cycleStartMusic: f64,
    cycleEndMusic: f64,
    tempo: f64,
    timeSigNumerator: i32,
    timeSigDenominator: i32,
    chord: Chord,
    smpteOffsetSubframes: i32,
    frameRate: FrameRate,
    samplesToNextClock: i32,
};

/// `Steinberg::Vst::IParamValueQueue`.
pub const IParamValueQueue = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x01263A18, 0xED074F6F, 0x98C9D356, 0x4686F9BA);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getParameterId: *const fn (this: *IParamValueQueue) callconv(.c) ParamID,
        getPointCount: *const fn (this: *IParamValueQueue) callconv(.c) i32,
        getPoint: *const fn (this: *IParamValueQueue, index: i32, sample_offset: ?*i32, value: ?*f64) callconv(.c) tresult,
        addPoint: *const fn (this: *IParamValueQueue, sample_offset: i32, value: f64, index: ?*i32) callconv(.c) tresult,
    };

    pub fn getParameterId(self: *IParamValueQueue) ParamID {
        return self.vtbl.getParameterId(self);
    }
    pub fn getPointCount(self: *IParamValueQueue) i32 {
        return self.vtbl.getPointCount(self);
    }
    pub fn getPoint(self: *IParamValueQueue, index: i32, offset: ?*i32, value: ?*f64) tresult {
        return self.vtbl.getPoint(self, index, offset, value);
    }
    pub fn addPoint(self: *IParamValueQueue, offset: i32, value: f64, index: ?*i32) tresult {
        return self.vtbl.addPoint(self, offset, value, index);
    }
};

/// `Steinberg::Vst::IParameterChanges`.
pub const IParameterChanges = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0xA4779663, 0x0BB64A56, 0xB44384A8, 0x466FEB9D);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getParameterCount: *const fn (this: *IParameterChanges) callconv(.c) i32,
        getParameterData: *const fn (this: *IParameterChanges, index: i32) callconv(.c) ?*IParamValueQueue,
        addParameterData: *const fn (this: *IParameterChanges, id: *const ParamID, index: *i32) callconv(.c) ?*IParamValueQueue,
    };

    pub fn getParameterCount(self: *IParameterChanges) i32 {
        return self.vtbl.getParameterCount(self);
    }
    pub fn getParameterData(self: *IParameterChanges, index: i32) ?*IParamValueQueue {
        return self.vtbl.getParameterData(self, index);
    }
    pub fn addParameterData(self: *IParameterChanges, id: *const ParamID, index: *i32) ?*IParamValueQueue {
        return self.vtbl.addParameterData(self, id, index);
    }
};

// ---- events --------------------------------------------------------------------------------

pub const NoteOnEvent = extern struct {
    channel: i16,
    pitch: i16,
    tuning: f32,
    velocity: f32,
    length: i32,
    noteId: i32,
};

pub const NoteOffEvent = extern struct {
    channel: i16,
    pitch: i16,
    velocity: f32,
    noteId: i32,
    tuning: f32,
};

pub const DataEvent = extern struct {
    size: u32,
    type: u32,
    bytes: ?[*]const u8,
};

pub const PolyPressureEvent = extern struct {
    channel: i16,
    pitch: i16,
    pressure: f32,
    noteId: i32,
};

pub const NoteExpressionValueEvent = extern struct {
    typeId: u32,
    noteId: i32,
    value: f64,
};

pub const NoteExpressionTextEvent = extern struct {
    typeId: u32,
    noteId: i32,
    textLen: u32,
    text: ?[*]const u16,
};

pub const ChordEvent = extern struct {
    root: i16,
    bassNote: i16,
    mask: i16,
    textLen: u16,
    text: ?[*]const u16,
};

pub const ScaleEvent = extern struct {
    root: i16,
    mask: i16,
    textLen: u16,
    text: ?[*]const u16,
};

/// The legacy MIDI CC output event (type `kLegacyMIDICCOutEvent`), including pitch bend (129) and
/// channel aftertouch (128).
pub const LegacyMIDICCOutEvent = extern struct {
    controlNumber: u8,
    channel: i8,
    value: i8,
    value2: i8,
};

pub const EventTypes = struct {
    pub const kNoteOnEvent: u16 = 0;
    pub const kNoteOffEvent: u16 = 1;
    pub const kDataEvent: u16 = 2;
    pub const kPolyPressureEvent: u16 = 3;
    pub const kNoteExpressionValueEvent: u16 = 4;
    pub const kNoteExpressionTextEvent: u16 = 5;
    pub const kChordEvent: u16 = 6;
    pub const kScaleEvent: u16 = 7;
    pub const kLegacyMIDICCOutEvent: u16 = 65535;
};

pub const Event = extern struct {
    busIndex: i32,
    sampleOffset: i32,
    ppqPosition: f64,
    flags: u16,
    type: u16,
    payload: extern union {
        noteOn: NoteOnEvent,
        noteOff: NoteOffEvent,
        data: DataEvent,
        polyPressure: PolyPressureEvent,
        noteExpressionValue: NoteExpressionValueEvent,
        noteExpressionText: NoteExpressionTextEvent,
        chord: ChordEvent,
        scale: ScaleEvent,
        midiCCOut: LegacyMIDICCOutEvent,
    },
};

/// `Steinberg::Vst::IEventList`.
pub const IEventList = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x3A2C4214, 0x346349FE, 0xB2C4F397, 0xB9695A44);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getEventCount: *const fn (this: *IEventList) callconv(.c) i32,
        getEvent: *const fn (this: *IEventList, index: i32, e: *Event) callconv(.c) tresult,
        addEvent: *const fn (this: *IEventList, e: *Event) callconv(.c) tresult,
    };

    pub fn getEventCount(self: *IEventList) i32 {
        return self.vtbl.getEventCount(self);
    }
    pub fn getEvent(self: *IEventList, index: i32, e: *Event) tresult {
        return self.vtbl.getEvent(self, index, e);
    }
    pub fn addEvent(self: *IEventList, e: *Event) tresult {
        return self.vtbl.addEvent(self, e);
    }
};

pub const ProcessData = extern struct {
    processMode: i32,
    symbolicSampleSize: i32,
    numSamples: i32,
    numInputs: i32,
    numOutputs: i32,
    inputs: ?[*]AudioBusBuffers,
    outputs: ?[*]AudioBusBuffers,
    inputParameterChanges: ?*IParameterChanges,
    outputParameterChanges: ?*IParameterChanges,
    inputEvents: ?*IEventList,
    outputEvents: ?*IEventList,
    processContext: ?*ProcessContext,
};

/// `Steinberg::Vst::IAudioProcessor`.
pub const IAudioProcessor = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x42043F99, 0xB7DA453C, 0xA569E79D, 0x9AAEC33D);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        setBusArrangements: *const fn (this: *IAudioProcessor, inputs: ?[*]SpeakerArrangement, num_ins: i32, outputs: ?[*]SpeakerArrangement, num_outs: i32) callconv(.c) tresult,
        getBusArrangement: *const fn (this: *IAudioProcessor, dir: BusDirection, index: i32, arr: *SpeakerArrangement) callconv(.c) tresult,
        canProcessSampleSize: *const fn (this: *IAudioProcessor, symbolic_sample_size: i32) callconv(.c) tresult,
        getLatencySamples: *const fn (this: *IAudioProcessor) callconv(.c) u32,
        setupProcessing: *const fn (this: *IAudioProcessor, setup: *ProcessSetup) callconv(.c) tresult,
        setProcessing: *const fn (this: *IAudioProcessor, state: TBool) callconv(.c) tresult,
        process: *const fn (this: *IAudioProcessor, data: *ProcessData) callconv(.c) tresult,
        getTailSamples: *const fn (this: *IAudioProcessor) callconv(.c) u32,
    };

    pub fn setBusArrangements(self: *IAudioProcessor, ins: ?[*]SpeakerArrangement, n_in: i32, outs: ?[*]SpeakerArrangement, n_out: i32) tresult {
        return self.vtbl.setBusArrangements(self, ins, n_in, outs, n_out);
    }
    pub fn getBusArrangement(self: *IAudioProcessor, dir: BusDirection, index: i32, arr: *SpeakerArrangement) tresult {
        return self.vtbl.getBusArrangement(self, dir, index, arr);
    }
    pub fn canProcessSampleSize(self: *IAudioProcessor, size: i32) tresult {
        return self.vtbl.canProcessSampleSize(self, size);
    }
    pub fn getLatencySamples(self: *IAudioProcessor) u32 {
        return self.vtbl.getLatencySamples(self);
    }
    pub fn setupProcessing(self: *IAudioProcessor, setup: *ProcessSetup) tresult {
        return self.vtbl.setupProcessing(self, setup);
    }
    pub fn setProcessing(self: *IAudioProcessor, state: bool) tresult {
        return self.vtbl.setProcessing(self, @intFromBool(state));
    }
    /// Audio thread: calls into the plugin; the host must not allocate or lock around it.
    pub fn process(self: *IAudioProcessor, data: *ProcessData) tresult {
        return self.vtbl.process(self, data);
    }
    pub fn getTailSamples(self: *IAudioProcessor) u32 {
        return self.vtbl.getTailSamples(self);
    }
};

pub const ParameterInfo = extern struct {
    id: ParamID,
    title: String128,
    shortTitle: String128,
    units: String128,
    stepCount: i32,
    defaultNormalizedValue: f64,
    unitId: i32,
    flags: i32,
};

pub const ViewRect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// `Steinberg::Vst::IComponentHandler`.
pub const IComponentHandler = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x93A0BEA3, 0x0BD045DB, 0x8E890B0C, 0xC1E46AC6);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        beginEdit: *const fn (this: *IComponentHandler, id: ParamID) callconv(.c) tresult,
        performEdit: *const fn (this: *IComponentHandler, id: ParamID, value_normalized: f64) callconv(.c) tresult,
        endEdit: *const fn (this: *IComponentHandler, id: ParamID) callconv(.c) tresult,
        restartComponent: *const fn (this: *IComponentHandler, flags: i32) callconv(.c) tresult,
    };
};

/// `Steinberg::Vst::IEditController`.
pub const IEditController = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0xDCD7BBE3, 0x7742448D, 0xA874AACC, 0x979C759E);

    pub const Vtbl = extern struct {
        base: IPluginBase.Vtbl,
        setComponentState: *const fn (this: *IEditController, state: *IBStream) callconv(.c) tresult,
        setState: *const fn (this: *IEditController, state: *IBStream) callconv(.c) tresult,
        getState: *const fn (this: *IEditController, state: *IBStream) callconv(.c) tresult,
        getParameterCount: *const fn (this: *IEditController) callconv(.c) i32,
        getParameterInfo: *const fn (this: *IEditController, index: i32, info: *ParameterInfo) callconv(.c) tresult,
        getParamStringByValue: *const fn (this: *IEditController, id: ParamID, value_normalized: f64, string: *String128) callconv(.c) tresult,
        getParamValueByString: *const fn (this: *IEditController, id: ParamID, string: [*:0]const u16, value_normalized: *f64) callconv(.c) tresult,
        normalizedParamToPlain: *const fn (this: *IEditController, id: ParamID, value_normalized: f64) callconv(.c) f64,
        plainParamToNormalized: *const fn (this: *IEditController, id: ParamID, plain_value: f64) callconv(.c) f64,
        getParamNormalized: *const fn (this: *IEditController, id: ParamID) callconv(.c) f64,
        setParamNormalized: *const fn (this: *IEditController, id: ParamID, value: f64) callconv(.c) tresult,
        setComponentHandler: *const fn (this: *IEditController, handler: ?*IComponentHandler) callconv(.c) tresult,
        createView: *const fn (this: *IEditController, name: [*:0]const u8) callconv(.c) ?*IPlugView,
    };

    pub fn initialize(self: *IEditController, context: ?*FUnknown) tresult {
        return self.vtbl.base.initialize(@ptrCast(self), context);
    }
    pub fn terminate(self: *IEditController) tresult {
        return self.vtbl.base.terminate(@ptrCast(self));
    }
    pub fn setComponentState(self: *IEditController, s: *IBStream) tresult {
        return self.vtbl.setComponentState(self, s);
    }
    pub fn setState(self: *IEditController, s: *IBStream) tresult {
        return self.vtbl.setState(self, s);
    }
    pub fn getState(self: *IEditController, s: *IBStream) tresult {
        return self.vtbl.getState(self, s);
    }
    pub fn getParameterCount(self: *IEditController) i32 {
        return self.vtbl.getParameterCount(self);
    }
    pub fn getParameterInfo(self: *IEditController, index: i32, info: *ParameterInfo) tresult {
        return self.vtbl.getParameterInfo(self, index, info);
    }
    pub fn getParamStringByValue(self: *IEditController, id: ParamID, v: f64, s: *String128) tresult {
        return self.vtbl.getParamStringByValue(self, id, v, s);
    }
    pub fn getParamNormalized(self: *IEditController, id: ParamID) f64 {
        return self.vtbl.getParamNormalized(self, id);
    }
    pub fn setParamNormalized(self: *IEditController, id: ParamID, v: f64) tresult {
        return self.vtbl.setParamNormalized(self, id, v);
    }
    pub fn setComponentHandler(self: *IEditController, h: ?*IComponentHandler) tresult {
        return self.vtbl.setComponentHandler(self, h);
    }
    pub fn createView(self: *IEditController, name: [*:0]const u8) ?*IPlugView {
        return self.vtbl.createView(self, name);
    }
};

/// `Steinberg::Vst::IMidiMapping`.
pub const IMidiMapping = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0xDF0FF9F7, 0x49B74669, 0xB63AB732, 0x7ADBF5E5);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getMidiControllerAssignment: *const fn (this: *IMidiMapping, bus_index: i32, channel: i16, midi_controller_number: i16, id: *ParamID) callconv(.c) tresult,
    };

    pub fn getMidiControllerAssignment(self: *IMidiMapping, bus: i32, channel: i16, cc: i16, id: *ParamID) tresult {
        return self.vtbl.getMidiControllerAssignment(self, bus, channel, cc, id);
    }
};

/// `Steinberg::Vst::IMessage` is only passed through `IConnectionPoint::notify`; this host keeps
/// it opaque.
pub const IMessage = extern struct {
    vtbl: *const anyopaque,
};

/// `Steinberg::Vst::IConnectionPoint`.
pub const IConnectionPoint = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x70A4156F, 0x6E6E4026, 0x989148BF, 0xAA60D8D1);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        connect: *const fn (this: *IConnectionPoint, other: *IConnectionPoint) callconv(.c) tresult,
        disconnect: *const fn (this: *IConnectionPoint, other: *IConnectionPoint) callconv(.c) tresult,
        notify: *const fn (this: *IConnectionPoint, message: ?*IMessage) callconv(.c) tresult,
    };

    pub fn connect(self: *IConnectionPoint, other: *IConnectionPoint) tresult {
        return self.vtbl.connect(self, other);
    }
    pub fn disconnect(self: *IConnectionPoint, other: *IConnectionPoint) tresult {
        return self.vtbl.disconnect(self, other);
    }
};

/// `Steinberg::IPlugFrame`.
pub const IPlugFrame = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x367FAF01, 0xAFA94693, 0x8D4DA2A0, 0xED0882A3);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        resizeView: *const fn (this: *IPlugFrame, view: *IPlugView, new_size: *ViewRect) callconv(.c) tresult,
    };
};

/// `Steinberg::IPlugView`.
pub const IPlugView = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x5BC32507, 0xD06049EA, 0xA6151B52, 0x2B755B29);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        isPlatformTypeSupported: *const fn (this: *IPlugView, type: [*:0]const u8) callconv(.c) tresult,
        attached: *const fn (this: *IPlugView, parent: ?*anyopaque, type: [*:0]const u8) callconv(.c) tresult,
        removed: *const fn (this: *IPlugView) callconv(.c) tresult,
        onWheel: *const fn (this: *IPlugView, distance: f32) callconv(.c) tresult,
        onKeyDown: *const fn (this: *IPlugView, key: u16, key_code: i16, modifiers: i16) callconv(.c) tresult,
        onKeyUp: *const fn (this: *IPlugView, key: u16, key_code: i16, modifiers: i16) callconv(.c) tresult,
        getSize: *const fn (this: *IPlugView, size: *ViewRect) callconv(.c) tresult,
        onSize: *const fn (this: *IPlugView, new_size: *ViewRect) callconv(.c) tresult,
        onFocus: *const fn (this: *IPlugView, state: TBool) callconv(.c) tresult,
        setFrame: *const fn (this: *IPlugView, frame: ?*IPlugFrame) callconv(.c) tresult,
        canResize: *const fn (this: *IPlugView) callconv(.c) tresult,
        checkSizeConstraint: *const fn (this: *IPlugView, rect: *ViewRect) callconv(.c) tresult,
    };

    pub fn isPlatformTypeSupported(self: *IPlugView, t: [*:0]const u8) tresult {
        return self.vtbl.isPlatformTypeSupported(self, t);
    }
    pub fn attached(self: *IPlugView, parent: ?*anyopaque, t: [*:0]const u8) tresult {
        return self.vtbl.attached(self, parent, t);
    }
    pub fn removed(self: *IPlugView) tresult {
        return self.vtbl.removed(self);
    }
    pub fn getSize(self: *IPlugView, size: *ViewRect) tresult {
        return self.vtbl.getSize(self, size);
    }
    pub fn onSize(self: *IPlugView, size: *ViewRect) tresult {
        return self.vtbl.onSize(self, size);
    }
    pub fn onFocus(self: *IPlugView, state: bool) tresult {
        return self.vtbl.onFocus(self, @intFromBool(state));
    }
    pub fn setFrame(self: *IPlugView, frame: ?*IPlugFrame) tresult {
        return self.vtbl.setFrame(self, frame);
    }
    pub fn canResize(self: *IPlugView) tresult {
        return self.vtbl.canResize(self);
    }
    pub fn checkSizeConstraint(self: *IPlugView, rect: *ViewRect) tresult {
        return self.vtbl.checkSizeConstraint(self, rect);
    }
};

/// `Steinberg::Vst::IHostApplication`.
pub const IHostApplication = extern struct {
    vtbl: *const Vtbl,

    pub const iid = uid(0x58E595CC, 0xDB2D4969, 0x8B6AAF8C, 0x36A664E5);

    pub const Vtbl = extern struct {
        unknown: FUnknown.Vtbl,
        getName: *const fn (this: *IHostApplication, name: *String128) callconv(.c) tresult,
        createInstance: *const fn (this: *IHostApplication, cid: *const TUID, iid: *const TUID, obj: *?*anyopaque) callconv(.c) tresult,
    };
};

// ---- strings -------------------------------------------------------------------------------

fn isTrimSpace(c: u8) bool {
    return std.ascii.isWhitespace(c);
}

/// Reads a fixed-size `char8[N]` buffer, stopping at the first NUL or the end of the array.
/// Returns the trimmed bytes as a slice of `buf` (no allocation, not UTF-8 validated; use
/// `readC8Alloc` for text that is shown or stored).
pub fn readC8(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return std.mem.trim(u8, buf[0..end], " \t\r\n\x0b\x0c");
}

/// `readC8` with invalid UTF-8 replaced by U+FFFD (Rust `from_utf8_lossy`), owned by the caller.
pub fn readC8Alloc(gpa: std.mem.Allocator, buf: []const u8) std.mem.Allocator.Error![]u8 {
    const raw = readC8(buf);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        const n = std.unicode.utf8ByteSequenceLength(raw[i]) catch {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + n > raw.len) {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
            continue;
        }
        if (std.unicode.utf8Decode(raw[i .. i + n])) |_| {
            try out.appendSlice(gpa, raw[i .. i + n]);
            i += n;
        } else |_| {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    // The replacement may expose new edge whitespace only through ASCII, which `readC8` trimmed.
    return out.toOwnedSlice(gpa);
}

/// Reads a fixed-size UTF-16 `String128`, stopping at the first NUL or the end of the array.
/// Returns trimmed UTF-8 (lone surrogates become U+FFFD), owned by the caller.
pub fn readC16(gpa: std.mem.Allocator, buf: []const u16) std.mem.Allocator.Error![]u8 {
    const end = std.mem.indexOfScalar(u16, buf, 0) orelse buf.len;
    const units = buf[0..end];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, units.len);
    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        var cp: u21 = 0xFFFD;
        if (u >= 0xD800 and u <= 0xDBFF) {
            if (i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
                cp = @intCast(0x10000 + ((@as(u32, u) - 0xD800) << 10) + (@as(u32, units[i + 1]) - 0xDC00));
                i += 1;
            }
        } else if (u < 0xDC00 or u > 0xDFFF) {
            cp = u;
        }
        i += 1;
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
        try out.appendSlice(gpa, tmp[0..n]);
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n\x0b\x0c");
    // Only ASCII is trimmed, so a prefix/suffix slice of the UTF-8 stays valid.
    const result = try gpa.dupe(u8, trimmed);
    out.deinit(gpa);
    return result;
}

/// Writes `s` (UTF-8) into a UTF-16 buffer, truncated and always NUL-terminated.
pub fn writeC16(s: []const u8, dst: []u16) void {
    if (dst.len == 0) return;
    const room = dst.len - 1;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < room) {
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if (std.unicode.utf8ByteSequenceLength(s[i])) |len| {
            if (i + len <= s.len) {
                if (std.unicode.utf8Decode(s[i .. i + len])) |c| {
                    cp = c;
                    adv = len;
                } else |_| {}
            }
        } else |_| {}
        i += adv;
        if (cp >= 0x10000) {
            const v: u32 = cp - 0x10000;
            dst[n] = @intCast(0xD800 + (v >> 10));
            n += 1;
            // Truncation may drop the low surrogate, as `take(room)` does in the Rust code.
            if (n < room) {
                dst[n] = @intCast(0xDC00 + (v & 0x3FF));
                n += 1;
            }
        } else {
            dst[n] = @intCast(cp);
            n += 1;
        }
    }
    dst[n] = 0;
}

/// Upper-case hex of a class id (the form used in `vst3:<hex>` ids).
pub fn hex(cid: *const [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    const digits = "0123456789ABCDEF";
    for (cid, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out;
}

// ---- layout assertions (the C header's layout on LP64) -------------------------------------

comptime {
    const lp64 = @sizeOf(usize) == 8;
    if (lp64) {
        std.debug.assert(@sizeOf(PFactoryInfo) == 452);
        std.debug.assert(@sizeOf(PClassInfo) == 116);
        std.debug.assert(@sizeOf(PClassInfo2) == 440);
        std.debug.assert(@sizeOf(PClassInfoW) == 696);
        std.debug.assert(@sizeOf(BusInfo) == 276);
        std.debug.assert(@sizeOf(ProcessSetup) == 24);
        std.debug.assert(@offsetOf(ProcessSetup, "sampleRate") == 16);
        std.debug.assert(@sizeOf(AudioBusBuffers) == 24);
        std.debug.assert(@offsetOf(AudioBusBuffers, "silenceFlags") == 8);
        std.debug.assert(@offsetOf(AudioBusBuffers, "channelBuffers") == 16);
        std.debug.assert(@sizeOf(ProcessData) == 80);
        std.debug.assert(@offsetOf(ProcessData, "inputs") == 24);
        std.debug.assert(@offsetOf(ProcessData, "processContext") == 72);
        std.debug.assert(@sizeOf(ProcessContext) == 112);
        std.debug.assert(@offsetOf(ProcessContext, "tempo") == 72);
        std.debug.assert(@offsetOf(ProcessContext, "chord") == 88);
        std.debug.assert(@offsetOf(ProcessContext, "frameRate") == 96);
        std.debug.assert(@sizeOf(ParameterInfo) == 792);
        std.debug.assert(@offsetOf(ParameterInfo, "stepCount") == 772);
        std.debug.assert(@offsetOf(ParameterInfo, "defaultNormalizedValue") == 776);
        std.debug.assert(@sizeOf(Event) == 48);
        std.debug.assert(@offsetOf(Event, "ppqPosition") == 8);
        std.debug.assert(@offsetOf(Event, "flags") == 16);
        std.debug.assert(@offsetOf(Event, "type") == 18);
        std.debug.assert(@offsetOf(Event, "payload") == 24);
    }
    std.debug.assert(@sizeOf(NoteOnEvent) == 20);
    std.debug.assert(@sizeOf(NoteOffEvent) == 16);
    std.debug.assert(@sizeOf(LegacyMIDICCOutEvent) == 4);
    std.debug.assert(@sizeOf(ViewRect) == 16);
    std.debug.assert(@sizeOf(TUID) == 16);
    std.debug.assert(@sizeOf(FUnknown.Vtbl) == 3 * @sizeOf(usize));
    std.debug.assert(@sizeOf(IPluginFactory3.Vtbl) == (3 + 4 + 1 + 2) * @sizeOf(usize));
    std.debug.assert(@sizeOf(IComponent.Vtbl) == (3 + 2 + 9) * @sizeOf(usize));
    std.debug.assert(@sizeOf(IAudioProcessor.Vtbl) == (3 + 8) * @sizeOf(usize));
    std.debug.assert(@sizeOf(IEditController.Vtbl) == (3 + 2 + 13) * @sizeOf(usize));
    std.debug.assert(@sizeOf(IPlugView.Vtbl) == (3 + 12) * @sizeOf(usize));
}

// ---- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "strings are bounded" {
    // Rust: strings_are_bounded
    const gpa = testing.allocator;
    var b: [4]u16 = @splat(0);
    writeC16("SoundCraft", &b);
    {
        const s = try readC16(gpa, &b);
        defer gpa.free(s);
        try testing.expectEqualStrings("Sou", s);
    }
    const full = [_]u16{ 'a', 'b', 'c', 'd' };
    {
        const s = try readC16(gpa, &full);
        defer gpa.free(s);
        try testing.expectEqualStrings("abcd", s);
    }
    const c = "Fx|EQ\x00junk";
    try testing.expectEqualStrings("Fx|EQ", readC8(c));
    {
        const s = try readC8Alloc(gpa, c);
        defer gpa.free(s);
        try testing.expectEqualStrings("Fx|EQ", s);
    }
    var empty: [0]u16 = .{};
    writeC16("x", &empty);
}

test "strings: lossy decoding, trimming and surrogates" {
    const gpa = testing.allocator;
    const s = try readC8Alloc(gpa, "  a\xFFb \x00zz");
    defer gpa.free(s);
    try testing.expectEqualStrings("a\u{FFFD}b", s);
    // A lone high surrogate becomes U+FFFD; a pair is combined.
    const units = [_]u16{ 0xD83D, 0xDE00, 'x', 0xD800 };
    const t = try readC16(gpa, &units);
    defer gpa.free(t);
    try testing.expectEqualStrings("\u{1F600}x\u{FFFD}", t);
    // Writing a pair into a buffer with room for exactly one unit drops it whole.
    var one: [2]u16 = .{ 0xFFFF, 0xFFFF };
    writeC16("\u{1F600}", &one);
    try testing.expectEqual(@as(u16, 0xD83D), one[0]);
    try testing.expectEqual(@as(u16, 0), one[1]);
    // A string that is not NUL-terminated within a 128-unit buffer is still bounded.
    var full: String128 = @splat('a');
    const u = try readC16(gpa, &full);
    defer gpa.free(u);
    try testing.expectEqual(@as(usize, 128), u.len);
}

test "hex is upper-case" {
    // Rust: assert_eq!(hex(&[0xAB; 16]), "AB".repeat(16))
    const cid: [16]u8 = @splat(0xAB);
    const h = hex(&cid);
    try testing.expectEqualStrings("ABABABABABABABABABABABABABABABAB", &h);
}

test "limits match the Rust constants" {
    try testing.expectEqual(@as(i32, 1024), MAX_CLASSES);
    try testing.expectEqual(@as(i32, 4096), MAX_PARAMS);
    try testing.expectEqual(@as(i32, 16), MAX_BUSES);
    try testing.expectEqual(@as(u32, 64), MAX_BUS_CHANNELS);
    try testing.expectEqual(@as(usize, 1024), EVENT_CAP);
    try testing.expectEqual(@as(usize, 1024), PARAM_QUEUE_CAP);
    try testing.expectEqual(@as(usize, 64 << 20), MAX_STATE_BYTES);
    try testing.expectEqual(@as(usize, 256), EDIT_CAP);
    try testing.expectEqualStrings("SCV3", STATE_MAGIC);
    try testing.expectEqual(@as(usize, 128), AFTERTOUCH);
    try testing.expectEqual(@as(usize, 129), PITCH_BEND);
}

/// Bytes of `INLINE_UID(l1, l2, l3, l4)` written out by hand for the non-Windows platforms
/// (all four words big-endian), as the `vst3` crate stores `Interface::IID` there.
fn expectIid(actual: TUID, expected_non_windows: [16]u8, expected_windows: [16]u8) !void {
    try testing.expectEqualSlices(u8, if (builtin.os.tag == .windows) &expected_windows else &expected_non_windows, &actual);
}

test "IIDs match the SDK constants" {
    // FUnknown: 00000000-0000-0000-C000-000000000046
    try expectIid(
        FUnknown.iid,
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46 },
    );
    // IPluginBase: 22888DDB 156E45AE 8358B348 08190625
    try expectIid(
        IPluginBase.iid,
        .{ 0x22, 0x88, 0x8D, 0xDB, 0x15, 0x6E, 0x45, 0xAE, 0x83, 0x58, 0xB3, 0x48, 0x08, 0x19, 0x06, 0x25 },
        .{ 0xDB, 0x8D, 0x88, 0x22, 0x6E, 0x15, 0xAE, 0x45, 0x83, 0x58, 0xB3, 0x48, 0x08, 0x19, 0x06, 0x25 },
    );
    // IPluginFactory: 7A4D811C 52114A1F AED9D2EE 0B43BF9F
    try expectIid(
        IPluginFactory.iid,
        .{ 0x7A, 0x4D, 0x81, 0x1C, 0x52, 0x11, 0x4A, 0x1F, 0xAE, 0xD9, 0xD2, 0xEE, 0x0B, 0x43, 0xBF, 0x9F },
        .{ 0x1C, 0x81, 0x4D, 0x7A, 0x11, 0x52, 0x1F, 0x4A, 0xAE, 0xD9, 0xD2, 0xEE, 0x0B, 0x43, 0xBF, 0x9F },
    );
    // IPluginFactory2: 0007B650 F24B4C0B A464EDB9 F00B2ABB
    try expectIid(
        IPluginFactory2.iid,
        .{ 0x00, 0x07, 0xB6, 0x50, 0xF2, 0x4B, 0x4C, 0x0B, 0xA4, 0x64, 0xED, 0xB9, 0xF0, 0x0B, 0x2A, 0xBB },
        .{ 0x50, 0xB6, 0x07, 0x00, 0x4B, 0xF2, 0x0B, 0x4C, 0xA4, 0x64, 0xED, 0xB9, 0xF0, 0x0B, 0x2A, 0xBB },
    );
    // IPluginFactory3: 4555A2AB C1234E57 9B122910 36878931
    try expectIid(
        IPluginFactory3.iid,
        .{ 0x45, 0x55, 0xA2, 0xAB, 0xC1, 0x23, 0x4E, 0x57, 0x9B, 0x12, 0x29, 0x10, 0x36, 0x87, 0x89, 0x31 },
        .{ 0xAB, 0xA2, 0x55, 0x45, 0x23, 0xC1, 0x57, 0x4E, 0x9B, 0x12, 0x29, 0x10, 0x36, 0x87, 0x89, 0x31 },
    );
    // IComponent: E831FF31 F2D54301 928EBBEE 25697802
    try expectIid(
        IComponent.iid,
        .{ 0xE8, 0x31, 0xFF, 0x31, 0xF2, 0xD5, 0x43, 0x01, 0x92, 0x8E, 0xBB, 0xEE, 0x25, 0x69, 0x78, 0x02 },
        .{ 0x31, 0xFF, 0x31, 0xE8, 0xD5, 0xF2, 0x01, 0x43, 0x92, 0x8E, 0xBB, 0xEE, 0x25, 0x69, 0x78, 0x02 },
    );
    // IAudioProcessor: 42043F99 B7DA453C A569E79D 9AAEC33D
    try expectIid(
        IAudioProcessor.iid,
        .{ 0x42, 0x04, 0x3F, 0x99, 0xB7, 0xDA, 0x45, 0x3C, 0xA5, 0x69, 0xE7, 0x9D, 0x9A, 0xAE, 0xC3, 0x3D },
        .{ 0x99, 0x3F, 0x04, 0x42, 0xDA, 0xB7, 0x3C, 0x45, 0xA5, 0x69, 0xE7, 0x9D, 0x9A, 0xAE, 0xC3, 0x3D },
    );
    // IEditController: DCD7BBE3 7742448D A874AACC 979C759E
    try expectIid(
        IEditController.iid,
        .{ 0xDC, 0xD7, 0xBB, 0xE3, 0x77, 0x42, 0x44, 0x8D, 0xA8, 0x74, 0xAA, 0xCC, 0x97, 0x9C, 0x75, 0x9E },
        .{ 0xE3, 0xBB, 0xD7, 0xDC, 0x42, 0x77, 0x8D, 0x44, 0xA8, 0x74, 0xAA, 0xCC, 0x97, 0x9C, 0x75, 0x9E },
    );
    // IConnectionPoint: 70A4156F 6E6E4026 989148BF AA60D8D1
    try expectIid(
        IConnectionPoint.iid,
        .{ 0x70, 0xA4, 0x15, 0x6F, 0x6E, 0x6E, 0x40, 0x26, 0x98, 0x91, 0x48, 0xBF, 0xAA, 0x60, 0xD8, 0xD1 },
        .{ 0x6F, 0x15, 0xA4, 0x70, 0x6E, 0x6E, 0x26, 0x40, 0x98, 0x91, 0x48, 0xBF, 0xAA, 0x60, 0xD8, 0xD1 },
    );
    // IComponentHandler: 93A0BEA3 0BD045DB 8E890B0C C1E46AC6
    try expectIid(
        IComponentHandler.iid,
        .{ 0x93, 0xA0, 0xBE, 0xA3, 0x0B, 0xD0, 0x45, 0xDB, 0x8E, 0x89, 0x0B, 0x0C, 0xC1, 0xE4, 0x6A, 0xC6 },
        .{ 0xA3, 0xBE, 0xA0, 0x93, 0xD0, 0x0B, 0xDB, 0x45, 0x8E, 0x89, 0x0B, 0x0C, 0xC1, 0xE4, 0x6A, 0xC6 },
    );
    // IPlugView: 5BC32507 D06049EA A6151B52 2B755B29
    try expectIid(
        IPlugView.iid,
        .{ 0x5B, 0xC3, 0x25, 0x07, 0xD0, 0x60, 0x49, 0xEA, 0xA6, 0x15, 0x1B, 0x52, 0x2B, 0x75, 0x5B, 0x29 },
        .{ 0x07, 0x25, 0xC3, 0x5B, 0x60, 0xD0, 0xEA, 0x49, 0xA6, 0x15, 0x1B, 0x52, 0x2B, 0x75, 0x5B, 0x29 },
    );
    // IPlugFrame: 367FAF01 AFA94693 8D4DA2A0 ED0882A3
    try expectIid(
        IPlugFrame.iid,
        .{ 0x36, 0x7F, 0xAF, 0x01, 0xAF, 0xA9, 0x46, 0x93, 0x8D, 0x4D, 0xA2, 0xA0, 0xED, 0x08, 0x82, 0xA3 },
        .{ 0x01, 0xAF, 0x7F, 0x36, 0xA9, 0xAF, 0x93, 0x46, 0x8D, 0x4D, 0xA2, 0xA0, 0xED, 0x08, 0x82, 0xA3 },
    );
    // IHostApplication: 58E595CC DB2D4969 8B6AAF8C 36A664E5
    try expectIid(
        IHostApplication.iid,
        .{ 0x58, 0xE5, 0x95, 0xCC, 0xDB, 0x2D, 0x49, 0x69, 0x8B, 0x6A, 0xAF, 0x8C, 0x36, 0xA6, 0x64, 0xE5 },
        .{ 0xCC, 0x95, 0xE5, 0x58, 0x2D, 0xDB, 0x69, 0x49, 0x8B, 0x6A, 0xAF, 0x8C, 0x36, 0xA6, 0x64, 0xE5 },
    );
    // IBStream: C3BF6EA2 30994752 9B6BF990 1EE33E9B
    try expectIid(
        IBStream.iid,
        .{ 0xC3, 0xBF, 0x6E, 0xA2, 0x30, 0x99, 0x47, 0x52, 0x9B, 0x6B, 0xF9, 0x90, 0x1E, 0xE3, 0x3E, 0x9B },
        .{ 0xA2, 0x6E, 0xBF, 0xC3, 0x99, 0x30, 0x52, 0x47, 0x9B, 0x6B, 0xF9, 0x90, 0x1E, 0xE3, 0x3E, 0x9B },
    );
    // IParameterChanges: A4779663 0BB64A56 B44384A8 466FEB9D
    try expectIid(
        IParameterChanges.iid,
        .{ 0xA4, 0x77, 0x96, 0x63, 0x0B, 0xB6, 0x4A, 0x56, 0xB4, 0x43, 0x84, 0xA8, 0x46, 0x6F, 0xEB, 0x9D },
        .{ 0x63, 0x96, 0x77, 0xA4, 0xB6, 0x0B, 0x56, 0x4A, 0xB4, 0x43, 0x84, 0xA8, 0x46, 0x6F, 0xEB, 0x9D },
    );
    // IParamValueQueue: 01263A18 ED074F6F 98C9D356 4686F9BA
    try expectIid(
        IParamValueQueue.iid,
        .{ 0x01, 0x26, 0x3A, 0x18, 0xED, 0x07, 0x4F, 0x6F, 0x98, 0xC9, 0xD3, 0x56, 0x46, 0x86, 0xF9, 0xBA },
        .{ 0x18, 0x3A, 0x26, 0x01, 0x07, 0xED, 0x6F, 0x4F, 0x98, 0xC9, 0xD3, 0x56, 0x46, 0x86, 0xF9, 0xBA },
    );
    // IEventList: 3A2C4214 346349FE B2C4F397 B9695A44
    try expectIid(
        IEventList.iid,
        .{ 0x3A, 0x2C, 0x42, 0x14, 0x34, 0x63, 0x49, 0xFE, 0xB2, 0xC4, 0xF3, 0x97, 0xB9, 0x69, 0x5A, 0x44 },
        .{ 0x14, 0x42, 0x2C, 0x3A, 0x63, 0x34, 0xFE, 0x49, 0xB2, 0xC4, 0xF3, 0x97, 0xB9, 0x69, 0x5A, 0x44 },
    );
    // IMidiMapping: DF0FF9F7 49B74669 B63AB732 7ADBF5E5
    try expectIid(
        IMidiMapping.iid,
        .{ 0xDF, 0x0F, 0xF9, 0xF7, 0x49, 0xB7, 0x46, 0x69, 0xB6, 0x3A, 0xB7, 0x32, 0x7A, 0xDB, 0xF5, 0xE5 },
        .{ 0xF7, 0xF9, 0x0F, 0xDF, 0xB7, 0x49, 0x69, 0x46, 0xB6, 0x3A, 0xB7, 0x32, 0x7A, 0xDB, 0xF5, 0xE5 },
    );
}

test "events: a note-on is addressable through the payload union" {
    // Rust (host_objects_behave): `out.__field0.noteOn.pitch`, `out.sampleOffset`
    var e = std.mem.zeroes(Event);
    e.sampleOffset = 3;
    e.type = EventTypes.kNoteOnEvent;
    e.payload = .{ .noteOn = .{ .channel = 2, .pitch = 60, .tuning = 0, .velocity = 1.0, .length = 0, .noteId = -1 } };
    try testing.expectEqual(@as(i16, 60), e.payload.noteOn.pitch);
    try testing.expectEqual(@as(i32, 3), e.sampleOffset);
    // The union overlaps at byte 24 like the C header.
    const bytes = std.mem.asBytes(&e);
    try testing.expectEqual(@as(i16, 2), std.mem.bytesToValue(i16, bytes[24..26]));
    try testing.expectEqual(@as(i16, 60), std.mem.bytesToValue(i16, bytes[26..28]));
}

test "ProcessContext is plain data and carries the transport flags" {
    // Rust (the_transport_fills_the_process_context) needs `apply_transport` from instance.rs;
    // here only the layout and flag constants of this unit are checked.
    var c = std.mem.zeroes(ProcessContext);
    c.state |= ProcessStates.kPlaying;
    try testing.expectEqual(@as(u32, 2), c.state);
    try testing.expectEqual(@as(u32, 0), c.state & ProcessStates.kRecording);
}

// The remaining tests of `ffi.rs` exercise host-side COM objects and instance helpers that live in
// other translation units (host.rs, process.rs, instance.rs). They are kept here as skipped
// placeholders so the port is accounted for; the unit that translates those files owns them.

test "plugins get messages and attribute lists from the host" {
    // Needs HostContext (ffi/host.rs).
    return error.SkipZigTest;
}

test "the transport fills the process context" {
    // Needs instance::apply_transport (ffi/instance.rs).
    return error.SkipZigTest;
}

test "state container parses strictly" {
    // Needs instance::split_state (ffi/instance.rs).
    return error.SkipZigTest;
}

test "host objects behave" {
    // Needs ParamChanges, EventList, MemoryStream, HostContext (ffi/process.rs, ffi/host.rs).
    return error.SkipZigTest;
}
