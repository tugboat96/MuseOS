// MuseOS System Services - Logical URI Name Resolver Daemon
// File: system_services/name_resolver/src/main.zig
//
// Resolves 'media://' URIs to Retrievable Multimedia Objects (RMO)
// and maps them to memory capabilities / storage block locations.

const std = @import("std");
const rmo = @import("rmo_parser.zig");

pub const ResolverError = error{
    InvalidScheme,
    MalformedUri,
    NotFound,
    AccessDenied,
    RmoParseFailed,
    TableFull,
    OutOfMemory,
};

pub const ResolvedObject = struct {
    uri: []const u8,
    object_id: u64,
    media_type: rmo.MediaType,
    block_start: u64,
    size_bytes: u64,
    direct_storage_eligible: bool,
};

pub const NameResolver = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap(ResolvedObject),

    pub fn init(allocator: std.mem.Allocator) NameResolver {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(ResolvedObject).init(allocator),
        };
    }

    pub fn deinit(self: *NameResolver) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit();
    }

    /// Registers a logical 'media://' mapping into the resolver database
    pub fn registerUri(
        self: *NameResolver,
        uri: []const u8,
        header: *const rmo.RmoHeader,
        block_start: u64,
    ) ResolverError!void {
        if (!std.mem.startsWith(u8, uri, "media://")) {
            return ResolverError.InvalidScheme;
        }

        const owned_key = self.allocator.dupe(u8, uri) catch return ResolverError.OutOfMemory;
        errdefer self.allocator.free(owned_key);

        const is_ds = (header.flags & rmo.RmoFlags.DIRECT_STORAGE_ELIGIBLE) != 0;

        const resolved = ResolvedObject{
            .uri = owned_key,
            .object_id = header.content_hash,
            .media_type = header.media_type,
            .block_start = block_start,
            .size_bytes = header.data_size,
            .direct_storage_eligible = is_ds,
        };

        self.entries.put(owned_key, resolved) catch return ResolverError.OutOfMemory;
    }

    /// Resolves a 'media://' URI string to a ResolvedObject metadata structure
    pub fn resolve(self: *const NameResolver, uri: []const u8) ResolverError!ResolvedObject {
        if (!std.mem.startsWith(u8, uri, "media://")) {
            return ResolverError.InvalidScheme;
        }

        if (self.entries.get(uri)) |obj| {
            return obj;
        }

        return ResolverError.NotFound;
    }
};

// Simple daemon entrypoint demonstration & test suite
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resolver = NameResolver.init(allocator);
    defer resolver.deinit();

    // Mock RMO Header setup
    const mock_header = rmo.RmoHeader{
        .magic = rmo.RMO_MAGIC,
        .version = 1,
        .media_type = rmo.MediaType.TextureMap,
        .flags = rmo.RmoFlags.DIRECT_STORAGE_ELIGIBLE | rmo.RmoFlags.COW_PINNED,
        .content_hash = 0xA1B2C3D4E5F67890,
        .data_size = 4096 * 64, // 256 KB
        .width_or_channels = 1024,
        .height_or_sample_rate = 1024,
    };

    const test_uri = "media://textures/environment_skybox.rmo";

    try resolver.registerUri(test_uri, &mock_header, 0x0000000000008000);

    const result = try resolver.resolve(test_uri);
    std.debug.print("Resolved URI '{s}' -> Block: 0x{X}, Size: {d} bytes, DS Eligible: {}\n", .{
        result.uri,
        result.block_start,
        result.size_bytes,
        result.direct_storage_eligible,
    });
}
