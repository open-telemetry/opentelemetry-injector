const builtin = @import("builtin");
const std = @import("std");

const print = @import("print.zig");
const test_util = @import("test_util.zig");

const testing = std.testing;

const ElfError = error{
    ElfHashTableNotFound,
    ElfInvalidClass,
    ElfNot64Bit,
    ElfNotDynamicLibrary,
    ElfStringSectionNotFound,
    ElfSymSectionNotFound,
    MissingDynamicLinkingInformation,
};

/// Provide a minimal support for looking up symbols from the memory location where an ELF binary has been memory-mapped
/// upon load.
///
/// Very loosely modelled after https://codeberg.org/ziglang/zig/src/tag/0.14.1/lib/std/dynamic_library.zig's ElfDynLib,
/// but with a few changes:
/// 1. Only support ELF on 64 bits.
/// 2. Instead of mapping the library's binary to memory, as we would do when loading a library, we are working with
///    already mapped memory regions, which also means no allocations are necessary.
/// 3. Skip the implementation of symbol version checking: we use this facility only to look up the dlsym symbol, which
///    is a function provided by libc that will allow us to look up all other symbols across the entire process. And,
///    between us, if your binary has TWO versions of the dlsym symbol, I would like to hear about it.
/// 4. Compensate for some quirks in the updating (or lack thereof) of dynamic symbol offsets.
pub const ElfDynLib = struct {
    start_memory_range: usize,
    end_memory_range: usize,
    strings: [*:0]u8,
    syms: [*]std.elf.Sym,
    hash: ?[*]u32,
    gnu_hash: ?*std.elf.gnu_hash.Header,
    dynamic: []const std.elf.Elf64_Dyn,

    pub fn open(start_memory_range: usize, end_memory_range: usize) !ElfDynLib {
        const elf_header = @as(*std.elf.Ehdr, @ptrFromInt(start_memory_range));
        if (!std.mem.eql(u8, elf_header.e_ident[0..4], std.elf.MAGIC)) {
            return error.NotElfFile;
        }

        switch (elf_header.e_ident[std.elf.EI_CLASS]) {
            std.elf.ELFCLASS64 => {
                // All good
            },
            std.elf.ELFCLASS32 => return error.ElfNot64Bit,
            else => return error.ElfInvalidClass,
        }

        if (elf_header.e_type != std.elf.ET.DYN) return error.ElfNotDynamicLibrary;

        const program_headers_ptr: [*]const std.elf.Elf64.Phdr = @ptrFromInt(start_memory_range + elf_header.e_phoff);
        const library = try fromProgramHeaders(start_memory_range, end_memory_range, program_headers_ptr[0..elf_header.e_phnum]);
        if (library.hash == null and library.gnu_hash == null) {
            return error.ElfHashTableNotFound;
        }
        return library;
    }

    /// Opens the main executable of the current process, given the location and number of its program headers, as the
    /// kernel reports them in the auxiliary vector (AT_PHDR and AT_PHNUM).
    ///
    /// Unlike open, this does not require the ELF header, and works for executables that are not position-independent
    /// (ET_EXEC). Their symbol values are absolute addresses, which a load bias of zero accounts for. It also accepts
    /// executables without a symbol hash table; these export no symbols as far as exportsSymbol is concerned.
    pub fn openMainExecutable(program_headers_address: usize, program_headers_count: usize) !ElfDynLib {
        if (program_headers_address == 0 or program_headers_count == 0) {
            return error.MissingProgramHeaders;
        }
        const program_headers_ptr: [*]const std.elf.Elf64.Phdr = @ptrFromInt(program_headers_address);
        const program_headers = program_headers_ptr[0..program_headers_count];

        // Derive the load bias the same way the dynamic linker does (see dl_main in glibc's rtld.c and __dls3 in musl's
        // ldso/dynlink.c): the difference between where the program headers actually are and where PT_PHDR says they
        // would be without relocation. An executable without PT_PHDR is treated as not relocated, as glibc does.
        var load_bias: usize = 0;
        var has_phdr_program_header = false;
        for (program_headers) |program_header| {
            if (program_header.type == std.elf.PT.PHDR) {
                load_bias = program_headers_address -% program_header.vaddr;
                has_phdr_program_header = true;
                break;
            }
        }

        // Without PT_PHDR, assuming a load bias of zero is only safe if the program headers actually are where an
        // unrelocated executable would have them, that is, inside one of its PT_LOAD segments. This rules out the case
        // where the program was started by running the dynamic linker directly (for example `/lib/ld-linux-x86-64.so.2
        // ./program`): AT_PHDR then describes the dynamic linker itself, which is position-independent but has no
        // PT_PHDR. Using a load bias of zero for it would dereference the unrelocated virtual address of its dynamic
        // section, which is not mapped, and crash the process with a segmentation fault.
        if (!has_phdr_program_header and !isInsideLoadSegment(program_headers, program_headers_address)) {
            return error.ProgramHeadersOutsideLoadSegments;
        }

        // The end of the memory range is not known here, and nothing needs it.
        return fromProgramHeaders(load_bias, 0, program_headers);
    }

    fn isInsideLoadSegment(program_headers: []const std.elf.Elf64.Phdr, address: usize) bool {
        for (program_headers) |program_header| {
            if (program_header.type == std.elf.PT.LOAD and
                address >= program_header.vaddr and
                address - program_header.vaddr < program_header.memsz)
            {
                return true;
            }
        }
        return false;
    }

    fn fromProgramHeaders(
        start_memory_range: usize,
        end_memory_range: usize,
        program_headers: []const std.elf.Elf64.Phdr,
    ) !ElfDynLib {
        var maybe_dynamic_program_header: ?std.elf.Elf64.Phdr = null;
        for (program_headers) |program_header| {
            switch (program_header.type) {
                std.elf.PT.DYNAMIC => maybe_dynamic_program_header = program_header,
                else => {},
            }
        }

        const dynamic_program_header = maybe_dynamic_program_header orelse return error.MissingDynamicLinkingInformation;

        var maybe_strings: ?[*:0]u8 = null;
        var maybe_syms: ?[*]std.elf.Elf64_Sym = null;
        var maybe_hashtab: ?[*]u32 = null;
        var maybe_gnu_hash: ?*std.elf.gnu_hash.Header = null;

        const dynamic_symbols_count = dynamic_program_header.memsz / @sizeOf(std.elf.Elf64_Dyn);
        const dynamic_symbols_ptr: [*]std.elf.Elf64_Dyn = @ptrFromInt(start_memory_range + dynamic_program_header.vaddr);
        const dynamic_symbols = dynamic_symbols_ptr[0..dynamic_symbols_count];

        for (dynamic_symbols) |dynamic_symbol| {
            var p = dynamic_symbol.d_val;
            if (p < start_memory_range) {
                // Musl libc does not update the dynamic symbol locations to add the start memory offset. GNU libc
                // seems to, except for DT_VERDEF. We compensate for it.
                p += start_memory_range;
            }
            switch (dynamic_symbol.d_tag) {
                std.elf.DT_STRTAB => maybe_strings = @ptrFromInt(p),
                std.elf.DT_SYMTAB => maybe_syms = @ptrFromInt(p),
                std.elf.DT_HASH => maybe_hashtab = @ptrFromInt(p),
                std.elf.DT_GNU_HASH => maybe_gnu_hash = @ptrFromInt(p),
                else => {},
            }
        }

        const strings = maybe_strings orelse return error.ElfStringSectionNotFound;
        const syms = maybe_syms orelse return error.ElfSymSectionNotFound;

        // Without a hash table, no symbol can be looked up, but the object might still be inspected for other reasons
        // (like needsLibraryWithPrefix), so leave it to the caller whether that is an error.
        return .{
            .start_memory_range = start_memory_range,
            .end_memory_range = end_memory_range,
            .strings = strings,
            .syms = syms,
            .hash = maybe_hashtab,
            .gnu_hash = maybe_gnu_hash,
            .dynamic = dynamic_symbols,
        };
    }

    /// Returns true if the ELF object defines and exports a symbol with the given name.
    pub fn exportsSymbol(self: *const ElfDynLib, name: [:0]const u8) bool {
        return self.lookupAddress(name) != null;
    }

    /// Returns true if one of the ELF object's DT_NEEDED entries starts with the given prefix, for example "libnode.so"
    /// matches a dependency on "libnode.so.115".
    pub fn needsLibraryWithPrefix(self: *const ElfDynLib, prefix: []const u8) bool {
        for (self.dynamic) |entry| {
            switch (entry.d_tag) {
                std.elf.DT_NULL => return false,
                // DT_NEEDED holds an offset into the string table, the dynamic linker never relocates it.
                std.elf.DT_NEEDED => {
                    const library_name = std.mem.sliceTo(self.strings + entry.d_val, 0);
                    if (std.mem.startsWith(u8, library_name, prefix)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    pub fn lookup(self: *const ElfDynLib, comptime T: type, name: [:0]const u8) ?T {
        if (self.lookupAddress(name)) |symbol_ptr| {
            return @as(T, @ptrFromInt(symbol_ptr));
        }

        return null;
    }

    const GnuHashSection64 = struct {
        symoffset: u32,
        bloom_shift: u32,
        bloom: []u64,
        buckets: []u32,
        chain: [*]std.elf.gnu_hash.ChainEntry,

        fn fromPtr(header: *std.elf.gnu_hash.Header) @This() {
            const header_offset = @intFromPtr(header);
            const bloom_offset = header_offset + @sizeOf(std.elf.gnu_hash.Header);
            const buckets_offset = bloom_offset + header.bloom_size * @sizeOf(u64);
            const chain_offset = buckets_offset + header.nbuckets * @sizeOf(u32);

            const bloom_ptr: [*]u64 = @ptrFromInt(bloom_offset);
            const buckets_ptr: [*]u32 = @ptrFromInt(buckets_offset);
            const chain_ptr: [*]std.elf.gnu_hash.ChainEntry = @ptrFromInt(chain_offset);

            return .{
                .symoffset = header.symoffset,
                .bloom_shift = header.bloom_shift,
                .bloom = bloom_ptr[0..header.bloom_size],
                .buckets = buckets_ptr[0..header.nbuckets],
                .chain = chain_ptr,
            };
        }
    };

    fn lookupAddress(self: *const ElfDynLib, name: []const u8) ?usize {
        const OK_TYPES = (1 << std.elf.STT_NOTYPE | 1 << std.elf.STT_OBJECT | 1 << std.elf.STT_FUNC | 1 << std.elf.STT_COMMON);
        const OK_BINDS = (1 << std.elf.STB_GLOBAL | 1 << std.elf.STB_WEAK | 1 << std.elf.STB_GNU_UNIQUE);

        if (self.gnu_hash) |gnu_hash_header| {
            const gnu_hash_section: GnuHashSection64 = .fromPtr(gnu_hash_header);
            const hash = std.elf.gnu_hash.calculate(name);

            const bloom_index = (hash / @bitSizeOf(usize)) % gnu_hash_header.bloom_size;
            const bloom_val = gnu_hash_section.bloom[bloom_index];

            const bit_index_0 = hash % @bitSizeOf(usize);
            const bit_index_1 = (hash >> @intCast(gnu_hash_header.bloom_shift)) % @bitSizeOf(usize);

            const one: usize = 1;
            const bit_mask: usize = (one << @intCast(bit_index_0)) | (one << @intCast(bit_index_1));

            if (bloom_val & bit_mask != bit_mask) {
                // Symbol is not in bloom filter, so it definitely isn't here.
                return null;
            }

            const bucket_index = hash % gnu_hash_header.nbuckets;
            const bucket_value = gnu_hash_section.buckets[bucket_index];
            if (bucket_value < gnu_hash_header.symoffset) {
                // Empty bucket (value 0) or any value below symoffset: no symbol in this bucket.
                // Mirrors glibc's dl-lookup check. Without this guard, the subtraction below
                // would underflow as u32 and trigger a ReleaseSafe panic (issue #399).
                return null;
            }
            const chain_index = bucket_value - gnu_hash_header.symoffset;

            const chains = gnu_hash_section.chain;
            const hash_as_entry: std.elf.gnu_hash.ChainEntry = @bitCast(hash);

            var current_index = chain_index;
            var at_end_of_chain = false;
            while (!at_end_of_chain) : (current_index += 1) {
                const current_entry = chains[current_index];
                at_end_of_chain = current_entry.end_of_chain;

                if (current_entry.hash != hash_as_entry.hash) continue;

                // check that symbol matches
                const symbol_index = current_index + gnu_hash_header.symoffset;
                const symbol = self.syms[symbol_index];

                if (0 == (@as(u32, 1) << @as(u5, @intCast(symbol.st_info & 0xf)) & OK_TYPES)) continue;
                if (0 == (@as(u32, 1) << @as(u5, @intCast(symbol.st_info >> 4)) & OK_BINDS)) continue;
                if (0 == symbol.st_shndx) continue;

                const symbol_name = std.mem.sliceTo(self.strings + symbol.st_name, 0);
                if (!std.mem.eql(u8, name, symbol_name)) {
                    continue;
                }

                return self.start_memory_range + symbol.st_value;
            }
        }

        if (self.hash) |hashtab| {
            const symbol_count: usize = @intCast(hashtab[1]);
            var i: usize = 0;
            while (i < symbol_count) : (i += 1) {
                if (0 == (@as(u32, 1) << @as(u5, @intCast(self.syms[i].st_info & 0xf)) & OK_TYPES)) continue;
                if (0 == (@as(u32, 1) << @as(u5, @intCast(self.syms[i].st_info >> 4)) & OK_BINDS)) continue;
                if (0 == self.syms[i].st_shndx) continue;
                const symbol_name = std.mem.sliceTo(self.strings + self.syms[i].st_name, 0);
                if (!std.mem.eql(u8, name, symbol_name)) continue;
                return self.start_memory_range + self.syms[i].st_value;
            }
        }

        return null;
    }
};

test "openMainExecutable: looks up exported symbols and needed libraries" {
    const cases = [_]struct { relocated: bool, absolute_dynamic_entries: bool }{
        // Position-independent executable, glibc relocates the dynamic section in place.
        .{ .relocated = true, .absolute_dynamic_entries = true },
        // Position-independent executable, musl leaves the dynamic section alone.
        .{ .relocated = true, .absolute_dynamic_entries = false },
        // Non-relocatable executable (ET_EXEC), for example the official Node.js builds for glibc.
        .{ .relocated = false, .absolute_dynamic_entries = false },
    };
    for (cases) |case| {
        var image: test_util.ElfTestImage = undefined;
        image.init(.{
            .relocated = case.relocated,
            .absolute_dynamic_entries = case.absolute_dynamic_entries,
            .exported_symbol = "exported_function",
            .needed_library = "libexample.so.42",
        });
        const executable = try ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len);

        const expected_bias: usize = if (case.relocated) @intFromPtr(&image) else 0;
        try testing.expectEqual(expected_bias, executable.start_memory_range);
        try testing.expect(executable.exportsSymbol("exported_function"));
        try testing.expectEqual(
            expected_bias + test_util.ElfTestImage.exported_symbol_value,
            executable.lookupAddress("exported_function").?,
        );
        try testing.expect(!executable.exportsSymbol("exported"));
        try testing.expect(!executable.exportsSymbol("not_exported_function"));

        try testing.expect(executable.needsLibraryWithPrefix("libexample.so"));
        try testing.expect(executable.needsLibraryWithPrefix("libexample.so.42"));
        try testing.expect(!executable.needsLibraryWithPrefix("libother.so"));
        // The image has a stray DT_NEEDED entry after DT_NULL, pointing at "exported_function". It must be ignored.
        try testing.expect(!executable.needsLibraryWithPrefix("exported"));
    }
}

test "openMainExecutable: ignores undefined symbols" {
    var image: test_util.ElfTestImage = undefined;
    image.init(.{ .exported_symbol = "exported_function" });
    // An undefined symbol (st_shndx == SHN_UNDEF) is an import, not an export.
    image.symbols[1].st_shndx = 0;
    const executable = try ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len);
    try testing.expect(!executable.exportsSymbol("exported_function"));
}

test "openMainExecutable: rejects missing program headers" {
    try testing.expectError(error.MissingProgramHeaders, ElfDynLib.openMainExecutable(0, 3));
    var image: test_util.ElfTestImage = undefined;
    image.init(.{});
    try testing.expectError(error.MissingProgramHeaders, ElfDynLib.openMainExecutable(image.programHeadersAddress(), 0));
}

test "openMainExecutable: rejects relocated program headers without PT_PHDR" {
    // This is what the auxiliary vector describes when the dynamic linker is run directly (`ld.so ./program`): a
    // position-independent object without PT_PHDR, whose program headers are not inside a PT_LOAD segment at a load
    // bias of zero.
    var image: test_util.ElfTestImage = undefined;
    image.init(.{ .relocated = true });
    image.program_headers[0].type = std.elf.PT.NULL;
    try testing.expectError(
        error.ProgramHeadersOutsideLoadSegments,
        ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len),
    );
}

test "openMainExecutable: accepts executables without a hash table" {
    var image: test_util.ElfTestImage = undefined;
    image.init(.{ .exported_symbol = "exported_function", .needed_library = "libexample.so.42" });
    // Turn the DT_HASH entry into one that is ignored.
    image.dynamic[0].d_tag = std.elf.DT_DEBUG;
    const executable = try ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len);
    try testing.expect(!executable.exportsSymbol("exported_function"));
    try testing.expect(executable.needsLibraryWithPrefix("libexample.so"));
}

test "openMainExecutable: rejects executables without a dynamic section" {
    var image: test_util.ElfTestImage = undefined;
    image.init(.{});
    image.program_headers[1].type = std.elf.PT.NULL;
    try testing.expectError(
        error.MissingDynamicLinkingInformation,
        ElfDynLib.openMainExecutable(image.programHeadersAddress(), image.program_headers.len),
    );
}
