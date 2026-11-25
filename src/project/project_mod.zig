//! Project Module
//!
//! Provides session management for the DAW:
//! - Save/Load projects
//! - Project folder structure
//! - State serialization

pub const project = @import("project.zig");
pub const persistence = @import("persistence.zig");
pub const recovery = @import("recovery.zig");

// Re-export main types
pub const Project = project.Project;
pub const ProjectHeader = project.ProjectHeader;
pub const TrackState = project.TrackState;
pub const ClipState = project.ClipState;
pub const EffectsChainState = project.EffectsChainState;
pub const EffectState = project.EffectState;

pub const TRACK_COUNT = project.TRACK_COUNT;
pub const MAX_TRACK_GAIN = project.MAX_TRACK_GAIN;
pub const MAX_EFFECTS = project.MAX_EFFECTS;
pub const MAX_CLIPS = project.MAX_CLIPS;

// Persistence functions
pub const saveProject = persistence.saveProject;
pub const loadProject = persistence.loadProject;
pub const createProjectFolder = persistence.createProjectFolder;
pub const getProjectsDir = persistence.getProjectsDir;

test {
    @import("std").testing.refAllDecls(@This());
}
