const std = @import("std");
const sys = @import("../utils/sys.zig");
const project_mod = @import("project.zig");
const persistence = @import("persistence.zig");
const Project = project_mod.Project;
const TrackState = project_mod.TrackState;
const ClipState = project_mod.ClipState;
const EffectState = project_mod.EffectState;

test "Project Persistence - Deep Integration Test" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // 1. Create a complex project state
    var project = Project.init();
    project.header.setName("Integration Test Symphony");
    project.header.bpm = 127.5;
    project.header.time_sig_num = 3;
    project.header.time_sig_den = 4;
    project.header.master_volume = 0.65;
    project.header.loop_start = 4.0;
    project.header.loop_end = 16.0;
    project.header.loop_enabled = true;

    // Track 0: Drums with multiple clips and an effect
    {
        const t = &project.tracks[0];
        t.setName("Drums (Main)");
        t.volume = 0.85;
        t.pan = 0.1;
        t.muted = false;
        t.solo = true;
        t.instrument_type = 1; // Sample Player
        t.clip_count = 2;

        // Clip 1
        t.clips[0].setName("Kick");
        t.clips[0].setFilePath("Audio/kick.wav");
        t.clips[0].start_time = 0.0;
        t.clips[0].duration = 1.0;
        t.clips[0].color = 0xFF0000;

        // Clip 2
        t.clips[1].setName("Snare");
        t.clips[1].setFilePath("Audio/snare.wav");
        t.clips[1].start_time = 1.0;
        t.clips[1].duration = 0.5;
        t.clips[1].source_offset = 0.1;
        t.clips[1].gain = 0.9;

        // Effect 0: Reverb (Type 1)
        t.effects_chain.count = 1;
        t.effects_chain.effects[0] = .{
            .effect_type = 1,
            .bypassed = false,
            .param_count = 2,
            .params = blk: {
                var p = @as([16]f32, @splat(0.0));
                p[0] = 0.5; // Room Size
                p[1] = 0.3; // Damp
                break :blk p;
            },
        };
    }

    // Track 1: Bass with pan and gain
    {
        const t = &project.tracks[1];
        t.setName("Sub Bass");
        t.volume = 0.7;
        t.pan = -0.2;
        t.armed = true;
        t.instrument_type = 2; // Synth
    }

    // Master effects
    {
        project.master_effects.count = 1;
        project.master_effects.effects[0] = .{
            .effect_type = 3, // Limiter
            .bypassed = true,
            .param_count = 1,
            .params = blk: {
                var p = @as([16]f32, @splat(0.0));
                p[0] = 0.95; // Threshold
                break :blk p;
            },
        };
    }

    // 2. Serialize to folder (using a temporary directory for the test)
    const tmp_dir_name = "persistence_test_tmp";
    try sys.makePath(tmp_dir_name);
    defer std.Io.Dir.cwd().deleteTree(sys.io(), tmp_dir_name) catch {};

    try persistence.saveProject(allocator, &project, tmp_dir_name);

    // 3. Load project back from disk
    var loaded = try persistence.loadProject(allocator, tmp_dir_name);

    // 4. Verify everything is identical

    // Header
    try testing.expectEqualStrings(project.header.getName(), loaded.header.getName());
    try testing.expectApproxEqAbs(project.header.bpm, loaded.header.bpm, 0.001);
    try testing.expectEqual(project.header.time_sig_num, loaded.header.time_sig_num);
    try testing.expectEqual(project.header.time_sig_den, loaded.header.time_sig_den);
    try testing.expectApproxEqAbs(project.header.master_volume, loaded.header.master_volume, 0.001);
    try testing.expectApproxEqAbs(project.header.loop_start, loaded.header.loop_start, 0.001);
    try testing.expectApproxEqAbs(project.header.loop_end, loaded.header.loop_end, 0.001);
    try testing.expectEqual(project.header.loop_enabled, loaded.header.loop_enabled);

    // Track 0
    {
        const t1 = &project.tracks[0];
        const t2 = &loaded.tracks[0];
        try testing.expectEqualStrings(t1.getName(), t2.getName());
        try testing.expectApproxEqAbs(t1.volume, t2.volume, 0.001);
        try testing.expectApproxEqAbs(t1.pan, t2.pan, 0.001);
        try testing.expectEqual(t1.muted, t2.muted);
        try testing.expectEqual(t1.solo, t2.solo);
        try testing.expectEqual(t1.instrument_type, t2.instrument_type);
        try testing.expectEqual(t1.clip_count, t2.clip_count);

        // Clips
        for (0..t1.clip_count) |i| {
            try testing.expectEqualStrings(t1.clips[i].getName(), t2.clips[i].getName());
            try testing.expectEqualStrings(t1.clips[i].getFilePath(), t2.clips[i].getFilePath());
            try testing.expectApproxEqAbs(t1.clips[i].start_time, t2.clips[i].start_time, 0.001);
            try testing.expectApproxEqAbs(t1.clips[i].duration, t2.clips[i].duration, 0.001);
            try testing.expectApproxEqAbs(t1.clips[i].source_offset, t2.clips[i].source_offset, 0.001);
            try testing.expectApproxEqAbs(t1.clips[i].gain, t2.clips[i].gain, 0.001);
            try testing.expectEqual(t1.clips[i].color, t2.clips[i].color);
        }

        // Effects
        try testing.expectEqual(t1.effects_chain.count, t2.effects_chain.count);
        for (0..t1.effects_chain.count) |i| {
            try testing.expectEqual(t1.effects_chain.effects[i].effect_type, t2.effects_chain.effects[i].effect_type);
            try testing.expectEqual(t1.effects_chain.effects[i].bypassed, t2.effects_chain.effects[i].bypassed);
            try testing.expectEqual(t1.effects_chain.effects[i].param_count, t2.effects_chain.effects[i].param_count);
            for (0..t1.effects_chain.effects[i].param_count) |pi| {
                try testing.expectApproxEqAbs(t1.effects_chain.effects[i].params[pi], t2.effects_chain.effects[i].params[pi], 0.001);
            }
        }
    }

    // Track 1
    {
        const t1 = &project.tracks[1];
        const t2 = &loaded.tracks[1];
        try testing.expectEqualStrings(t1.getName(), t2.getName());
        try testing.expectApproxEqAbs(t1.volume, t2.volume, 0.001);
        try testing.expectApproxEqAbs(t1.pan, t2.pan, 0.001);
        try testing.expectEqual(t1.armed, t2.armed);
        try testing.expectEqual(t1.instrument_type, t2.instrument_type);
    }

    // Master effects
    {
        const c1 = &project.master_effects;
        const c2 = &loaded.master_effects;
        try testing.expectEqual(c1.count, c2.count);
        try testing.expectEqual(c1.effects[0].effect_type, c2.effects[0].effect_type);
        try testing.expectEqual(c1.effects[0].bypassed, c2.effects[0].bypassed);
        try testing.expectApproxEqAbs(c1.effects[0].params[0], c2.effects[0].params[0], 0.001);
    }
}
