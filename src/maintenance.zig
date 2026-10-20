//! Public maintenance namespace.

pub const Error = @import("maintenance/maintenance.zig").Error;
pub const Split = @import("maintenance/maintenance.zig").Split;
pub const CommitGraphOptions = @import("maintenance/maintenance.zig").CommitGraphOptions;
pub const writeCommitGraph = @import("maintenance/maintenance.zig").writeCommitGraph;
pub const MidxOptions = @import("maintenance/maintenance.zig").MidxOptions;
pub const MidxError = @import("maintenance/maintenance.zig").MidxError;
pub const writeMidx = @import("maintenance/maintenance.zig").writeMidx;
pub const expireMidx = @import("maintenance/maintenance.zig").expireMidx;
pub const BitmapOptions = @import("maintenance/maintenance.zig").BitmapOptions;
pub const BitmapError = @import("maintenance/maintenance.zig").BitmapError;
pub const writePackBitmap = @import("maintenance/maintenance.zig").writePackBitmap;
pub const writeMidxBitmap = @import("maintenance/maintenance.zig").writeMidxBitmap;
pub const MidxRepackOptions = @import("maintenance/maintenance.zig").MidxRepackOptions;
pub const repackMidx = @import("maintenance/maintenance.zig").repackMidx;
pub const MaintenanceError = @import("maintenance/maintenance.zig").MaintenanceError;
pub const Maintenance = @import("maintenance/maintenance.zig").Maintenance;
pub const writeConfiguredCommitGraph = @import("maintenance/maintenance.zig").writeConfiguredCommitGraph;
pub const repackRepository = @import("maintenance/maintenance.zig").repackRepository;

pub const BitmapInputs = @import("maintenance/maintenance.zig").BitmapInputs;
pub const MidxBitmapInputs = @import("maintenance/maintenance.zig").MidxBitmapInputs;

pub const GcError = @import("maintenance/gc.zig").Error;
pub const PackRefsOptions = @import("maintenance/gc.zig").PackRefsOptions;
pub const packRefs = @import("maintenance/gc.zig").packRefs;
pub const Expiry = @import("maintenance/gc.zig").Expiry;
pub const expire_all = @import("maintenance/gc.zig").expire_all;
pub const parseExpiry = @import("maintenance/gc.zig").parseExpiry;
pub const ReflogExpireOptions = @import("maintenance/gc.zig").ReflogExpireOptions;
pub const expireReflogs = @import("maintenance/gc.zig").expireReflogs;
