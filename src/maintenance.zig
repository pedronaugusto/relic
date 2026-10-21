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

pub const BitmapInputs = @import("maintenance/maintenance.zig").BitmapInputs;
pub const MidxBitmapInputs = @import("maintenance/maintenance.zig").MidxBitmapInputs;

pub const HousekeepingError = @import("maintenance/gc.zig").Error;
pub const PackRefsOptions = @import("maintenance/gc.zig").PackRefsOptions;
pub const packRefs = @import("maintenance/gc.zig").packRefs;
pub const Expiry = @import("maintenance/gc.zig").Expiry;
pub const expire_all = @import("maintenance/gc.zig").expire_all;
pub const parseExpiry = @import("maintenance/gc.zig").parseExpiry;
pub const ReflogExpireOptions = @import("maintenance/gc.zig").ReflogExpireOptions;
pub const expireReflogs = @import("maintenance/gc.zig").expireReflogs;

pub const GcError = @import("maintenance/collect.zig").Error;
pub const GcOptions = @import("maintenance/collect.zig").Options;
pub const GcPrune = @import("maintenance/collect.zig").Prune;
pub const GcOutcome = @import("maintenance/collect.zig").Outcome;
pub const GcHolder = @import("maintenance/collect.zig").Holder;
pub const GcReport = @import("maintenance/collect.zig").Report;
pub const gc = @import("maintenance/collect.zig").collect;
pub const parseGcPrune = @import("maintenance/collect.zig").parsePrune;

pub const PruneError = @import("maintenance/prune.zig").Error;
pub const PruneOptions = @import("maintenance/prune.zig").PruneOptions;
pub const PruneReport = @import("maintenance/prune.zig").Report;
pub const prune = @import("maintenance/prune.zig").prune;
pub const pruneExpiry = @import("maintenance/prune.zig").pruneExpiry;
pub const ReachError = @import("maintenance/reach.zig").Error;
pub const ReachOptions = @import("maintenance/reach.zig").ReachOptions;
pub const reachableObjects = @import("maintenance/reach.zig").reachableObjects;
pub const reachableToPack = @import("maintenance/reach.zig").reachableToPack;

pub const RepackError = @import("maintenance/repack.zig").Error;
pub const RepackMode = @import("maintenance/repack.zig").Mode;
pub const RepackOptions = @import("maintenance/repack.zig").Options;
pub const RepackReport = @import("maintenance/repack.zig").Report;
pub const repack = @import("maintenance/repack.zig").repack;
pub const repositoryTips = @import("maintenance/maintenance.zig").repositoryTips;
pub const ServerInfoError = @import("maintenance/server_info.zig").Error;
pub const updateServerInfo = @import("maintenance/server_info.zig").updateServerInfo;
