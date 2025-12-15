const builtin = @import("builtin");
const std = @import("std");

const print = @import("print.zig");

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

        var maybe_dynamic_program_header: ?std.elf.Elf64_Phdr = null;
        {
            const program_headers_ptr: [*]const std.elf.Elf64_Phdr = @ptrFromInt(start_memory_range + elf_header.e_phoff);
            const program_headers = program_headers_ptr[0..elf_header.e_phnum];

            for (program_headers) |program_header| {
                switch (program_header.p_type) {
                    std.elf.PT_DYNAMIC => maybe_dynamic_program_header = program_header,
                    else => {},
                }
            }
        }

        const dynamic_program_header = maybe_dynamic_program_header orelse return error.MissingDynamicLinkingInformation;

        var maybe_strings: ?[*:0]u8 = null;
        var maybe_syms: ?[*]std.elf.Elf64_Sym = null;
        var maybe_hashtab: ?[*]u32 = null;
        var maybe_gnu_hash: ?*std.elf.gnu_hash.Header = null;

        {
            const dynamic_symbols_count = dynamic_program_header.p_memsz / @sizeOf(std.elf.Elf64_Dyn);
            const dynamic_symbols_ptr: [*]std.elf.Elf64_Dyn = @ptrFromInt(start_memory_range + dynamic_program_header.p_vaddr);
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
        }

        const strings = maybe_strings orelse return error.ElfStringSectionNotFound;
        const syms = maybe_syms orelse return error.ElfSymSectionNotFound;

        if (maybe_hashtab == null and maybe_gnu_hash == null) {
            return error.ElfHashTableNotFound;
        }

        return .{
            .start_memory_range = start_memory_range,
            .end_memory_range = end_memory_range,
            .strings = strings,
            .syms = syms,
            .hash = maybe_hashtab,
            .gnu_hash = maybe_gnu_hash,
        };
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
            const chain_index = gnu_hash_section.buckets[bucket_index] - gnu_hash_header.symoffset;

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
