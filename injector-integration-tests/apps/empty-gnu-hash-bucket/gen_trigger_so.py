#!/usr/bin/env python3
"""
Generate a minimal ELF shared library that triggers the integer overflow bug
in ElfDynLib.lookupAddress (issue #399).

The .gnu.hash section is crafted so that:
  - The bloom filter passes (false positive) for "setenv" (hash=0x1b85483a)
  - The corresponding bucket value is 0 (empty)
  - chain_index = bucket_value(0) - symoffset(1)
               = 0 - 1 as u32 → wraps to 0xffffffff → panic in ReleaseSafe

Usage:
  python3 gen_trigger_so.py [--machine <183|62>] <output.so>
  183 = EM_AARCH64 (default), 62 = EM_X86_64
"""

import struct
import sys
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--machine", type=int, default=183,
                    help="ELF e_machine: 183=EM_AARCH64, 62=EM_X86_64")
parser.add_argument("output", help="Output .so path")
args = parser.parse_args()

MACHINE = args.machine
OUTPATH = args.output

# --- GNU hash parameters ---
NBUCKETS    = 1
SYMOFFSET   = 1   # underflow: bucket_val(0) - symoffset(1) wraps as u32
BLOOM_SIZE  = 1
BLOOM_SHIFT = 6

SETENV_HASH = 0x1b85483a  # gnu_hash("setenv")
bit0 = SETENV_HASH & 63
bit1 = (SETENV_HASH >> BLOOM_SHIFT) & 63
bloom_val = (1 << bit0) | (1 << bit1)

# --- Section data ---
dynstr = b"\x00"  # minimal string table

# STN_UNDEF symbol entry (24 bytes): st_name, st_info, st_other, st_shndx, st_value, st_size
dynsym = struct.pack("<IBBHQQ", 0, 0, 0, 0, 0, 0)

gnu_hash_data = (
    struct.pack("<IIII", NBUCKETS, SYMOFFSET, BLOOM_SIZE, BLOOM_SHIFT)  # header
    + struct.pack("<Q", bloom_val)   # bloom[0]: passes for "setenv"
    + struct.pack("<I", 0)           # bucket[0] = 0  ← empty bucket → underflow!
)

# --- Layout ---
ELF_HDR_SZ = 64
PHDR_SZ    = 56
PHDR_CNT   = 2

def align(x, n=8):
    return (x + n - 1) & ~(n - 1)

phdr_off    = ELF_HDR_SZ
data_start  = phdr_off + PHDR_CNT * PHDR_SZ  # 176

dynstr_off  = data_start
dynsym_off  = align(dynstr_off + len(dynstr))
gnuh_off    = align(dynsym_off + len(dynsym))

DT_NULL     = 0
DT_STRTAB   = 5
DT_STRSZ    = 10
DT_SYMTAB   = 6
DT_SYMENT   = 11
DT_GNU_HASH = 0x6ffffef5

dyn_off = align(gnuh_off + len(gnu_hash_data))
dyn_entries = [
    (DT_STRTAB,    dynstr_off),
    (DT_STRSZ,     len(dynstr)),
    (DT_SYMTAB,    dynsym_off),
    (DT_SYMENT,    24),
    (DT_GNU_HASH,  gnuh_off),
    (DT_NULL,      0),
]
dyn_data = b"".join(struct.pack("<QQ", t, v) for t, v in dyn_entries)
total = align(dyn_off + len(dyn_data))

# --- Program headers ---
# PT_LOAD: entire file, R+W so the dynamic linker can read it
phdr_load = struct.pack("<IIQQQQQQ",
    1,      # PT_LOAD
    6,      # PF_R | PF_W
    0,      # offset
    0,      # vaddr
    0,      # paddr
    total,  # filesz
    total,  # memsz
    0x1000) # align

# PT_DYNAMIC
phdr_dyn = struct.pack("<IIQQQQQQ",
    2,             # PT_DYNAMIC
    4,             # PF_R
    dyn_off,       # offset
    dyn_off,       # vaddr
    dyn_off,       # paddr
    len(dyn_data), # filesz
    len(dyn_data), # memsz
    8)             # align

# --- ELF header ---
ELFCLASS64   = 2
ELFDATA2LSB  = 1
EV_CURRENT   = 1
ELFOSABI_NONE = 0
ET_DYN       = 3

elf_hdr = struct.pack("<4sBBBBBxxxxxxx",
    b"\x7fELF", ELFCLASS64, ELFDATA2LSB, EV_CURRENT, ELFOSABI_NONE, 0)
elf_hdr += struct.pack("<HHIQQQIHHHHHH",
    ET_DYN, MACHINE, EV_CURRENT,
    0,         # e_entry
    phdr_off,  # e_phoff
    0,         # e_shoff (no section headers needed)
    0,         # e_flags
    ELF_HDR_SZ, PHDR_SZ, PHDR_CNT,
    64, 0, 0)  # shentsize, shnum, shstrndx

assert len(elf_hdr) == ELF_HDR_SZ, f"ELF header size mismatch: {len(elf_hdr)}"

# --- Assemble ---
buf = bytearray(total)

def put(off, data):
    buf[off:off + len(data)] = data

put(0,           elf_hdr)
put(phdr_off,    phdr_load)
put(phdr_off + PHDR_SZ, phdr_dyn)
put(dynstr_off,  dynstr)
put(dynsym_off,  dynsym)
put(gnuh_off,    gnu_hash_data)
put(dyn_off,     dyn_data)

with open(OUTPATH, "wb") as f:
    f.write(buf)

print(f"Wrote {total} bytes to {OUTPATH}")
print(f"  machine:     {'EM_AARCH64' if MACHINE == 183 else 'EM_X86_64'} ({MACHINE})")
print(f"  setenv hash: 0x{SETENV_HASH:08x}")
print(f"  bloom bit0:  {bit0}  bit1: {bit1}  → bloom[0]=0x{bloom_val:016x}")
print(f"  bucket[0]:   0  symoffset: {SYMOFFSET}")
print(f"  underflow:   0 - {SYMOFFSET} as u32 = 0x{(0 - SYMOFFSET) & 0xFFFFFFFF:08x}")
