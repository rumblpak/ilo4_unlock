import struct, sys, os

# usage: python3 build_patched_280.py <extracted-280-elf.bin> <output-path>
# (produces an elf.bin with both the sig-bypass patch AND the v2 fan-restore
# patch applied; feed the result to ilo4_repack.py as the patched userland)
if len(sys.argv) != 3:
    print(f"usage: {sys.argv[0]} <extracted 2.80 elf.bin> <output path>")
    sys.exit(1)

IN_PATH = sys.argv[1]
OUT_PATH = sys.argv[2]
FAN_BLOCK_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fan_block.bin')

data = bytearray(open(IN_PATH, 'rb').read())

# ---------------------------------------------------------------------------
# 0. sig-bypass (unaffected by anything below -- file offset 0x964dfc is well
#    before every insertion/edit point used here)
# ---------------------------------------------------------------------------
SIGBYPASS_OFFSET = 0x964dfc
old = bytes(data[SIGBYPASS_OFFSET:SIGBYPASS_OFFSET+4])
assert old == bytes.fromhex('1D00000A'), old.hex()
data[SIGBYPASS_OFFSET:SIGBYPASS_OFFSET+4] = bytes.fromhex('1D0000EA')
print(f"sig-bypass applied @0x{SIGBYPASS_OFFSET:x}")

# ---------------------------------------------------------------------------
# parse section header table
# ---------------------------------------------------------------------------
e_shoff = struct.unpack_from('<I', data, 0x20)[0]
e_shentsize = struct.unpack_from('<H', data, 0x2e)[0]
e_shnum = struct.unpack_from('<H', data, 0x30)[0]
shstrtab_idx = struct.unpack_from('<H', data, 0x32)[0]
assert e_shentsize == 40

SHDR_FIELDS = ['sh_name','sh_type','sh_flags','sh_addr','sh_offset','sh_size','sh_link','sh_info','sh_addralign','sh_entsize']

def read_shdr(i):
    off = e_shoff + i*e_shentsize
    return dict(zip(SHDR_FIELDS, struct.unpack_from('<IIIIIIIIII', data, off)))

shdrs = [read_shdr(i) for i in range(e_shnum)]
shstrtab_off = shdrs[shstrtab_idx]['sh_offset']

def name_of(i):
    n = shdrs[i]['sh_name']
    end = data.index(b'\x00', shstrtab_off+n)
    return data[shstrtab_off+n:end].decode('latin1')

boottable_idx = next(i for i in range(e_shnum) if name_of(i) == '.boottable')
secinfo_idx = next(i for i in range(e_shnum) if name_of(i) == '.secinfo')
boottable = shdrs[boottable_idx]
secinfo = shdrs[secinfo_idx]
print(f".boottable idx={boottable_idx} addr=0x{boottable['sh_addr']:x} off=0x{boottable['sh_offset']:x} size=0x{boottable['sh_size']:x}")
print(f".secinfo   idx={secinfo_idx} addr=0x{secinfo['sh_addr']:x} off=0x{secinfo['sh_offset']:x} size=0x{secinfo['sh_size']:x}")

# ---------------------------------------------------------------------------
# 1. read-only lookups against EXISTING content -- no resizing of
#    .boottable/.secinfo happens anywhere in this script. These offsets are
#    specific to the 2.80 build; see elf_patch_summary.md.
# ---------------------------------------------------------------------------
HEALTH_TASKINFO_FOFF = 0x166059c
VIRT_SPACE_SIZE_FOFF = HEALTH_TASKINFO_FOFF + 4
VIRT_SPACE_FOFF = HEALTH_TASKINFO_FOFF + 8

task_type, virt_space_size, virt_space = struct.unpack_from('<III', data, HEALTH_TASKINFO_FOFF)
assert virt_space_size == 63, virt_space_size
print(f"Health TaskInfo: virt_space_size={virt_space_size} virt_space=0x{virt_space:x}")

existing_vr_off = boottable['sh_offset'] + (virt_space - boottable['sh_addr'])
existing_vr_bytes = bytes(data[existing_vr_off:existing_vr_off + 63*0x20])
assert len(existing_vr_bytes) == 63*0x20

LAST_SECINFO_NEXTPTR_FOFF = 0x16ece54
last_next_ptr = struct.unpack_from('<I', data, LAST_SECINFO_NEXTPTR_FOFF)[0]
assert last_next_ptr == 0, hex(last_next_ptr)
NEW_SECINFO_INDEX = 577  # confirmed count of existing secinfo entries
SIZE_INITIAL = 49

# ---------------------------------------------------------------------------
# 2. build the new combined section content: fan code + new SectionInfo
#    entry (struct+name) + new 64-entry Health VirtRange array.
#    All of this lives at a BRAND NEW physical address (0x4000000) that
#    collides with nothing in the firmware's existing address space
#    (confirmed: highest existing true-vaddr use tops out at 0x3e22b18),
#    unlike v1 of this patch, which reused unallocated space inside an
#    EXISTING module's declared VirtRange and turned out to collide with
#    that module's live BSS. See research/ for the post-mortem.
# ---------------------------------------------------------------------------
NEW_PHYS_BASE = 0x4000000
NEW_TASK_LOCAL_BASE = 0x2001000  # Health task-local; existing entries top out at 0x2000000

fan_block = open(FAN_BLOCK_PATH, 'rb').read()
assert len(fan_block) == 15548

secinfo_struct_vaddr = NEW_PHYS_BASE + len(fan_block)
assert secinfo_struct_vaddr % 4 == 0
name_bytes = b'.health.fan_restore\x00'
name_ptr = secinfo_struct_vaddr + 24
new_secinfo_struct = struct.pack('<IIIIII', 0, name_ptr, NEW_PHYS_BASE, len(fan_block), 1, 0) + name_bytes
pad1 = (-len(new_secinfo_struct)) % 4
new_secinfo_struct += b'\x00' * pad1

virtrange_array_vaddr = secinfo_struct_vaddr + len(new_secinfo_struct)
new_health_mod_id = SIZE_INITIAL + NEW_SECINFO_INDEX
new_vr_entry = struct.pack('<IIIIIIII', 1, 5, NEW_TASK_LOCAL_BASE, 0x4000, new_health_mod_id, 0, 0, 0)
new_vr_array = existing_vr_bytes + new_vr_entry
assert len(new_vr_array) == 64*0x20

new_section_content = fan_block + new_secinfo_struct + new_vr_array
new_section_size = len(new_section_content)
print(f"new combined section: size=0x{new_section_size:x} ({new_section_size} bytes)")
print(f"  fan code:        0x{NEW_PHYS_BASE:x} - 0x{NEW_PHYS_BASE+len(fan_block):x}")
print(f"  secinfo struct:  0x{secinfo_struct_vaddr:x} (name @ 0x{name_ptr:x})")
print(f"  virtrange array: 0x{virtrange_array_vaddr:x} (64 entries, new entry mod_id=0x{new_health_mod_id:x})")

# ---------------------------------------------------------------------------
# 3. callsite patch: re-point the fan trampoline's disabled `bl` at the
#    relocated handler's new task-local address (0x2001000). Precomputed for
#    this exact placement -- if NEW_TASK_LOCAL_BASE above ever changes, this
#    byte sequence must be regenerated (see elf_patch_summary.md).
# ---------------------------------------------------------------------------
CALLSITE_FOFF = 0x38e5d8
NEW_BL_BYTES = bytes.fromhex('eb6b7feb')
old_bl = bytes(data[CALLSITE_FOFF:CALLSITE_FOFF+4])
assert old_bl == bytes.fromhex('1e4900eb'), old_bl.hex()
assert CALLSITE_FOFF < boottable['sh_offset']  # unaffected by the append-at-end insertion

# ---------------------------------------------------------------------------
# 4. perform the single insertion: append the new section's content right
#    before the section header table (lowest-impact insertion point --
#    nothing else has a higher file offset, so only e_shoff shifts).
# ---------------------------------------------------------------------------
insertion_offset = e_shoff
maxend = max(s['sh_offset'] + s['sh_size'] for s in shdrs if s['sh_type'] != 8)
assert insertion_offset >= maxend, (hex(insertion_offset), hex(maxend))

new_data = bytearray(data[:insertion_offset]) + bytearray(new_section_content) + bytearray(data[insertion_offset:])
delta = len(new_section_content)

new_data[CALLSITE_FOFF:CALLSITE_FOFF+4] = NEW_BL_BYTES
struct.pack_into('<I', new_data, VIRT_SPACE_FOFF, virtrange_array_vaddr)
struct.pack_into('<I', new_data, VIRT_SPACE_SIZE_FOFF, 64)
struct.pack_into('<I', new_data, LAST_SECINFO_NEXTPTR_FOFF, secinfo_struct_vaddr)

new_e_shoff = e_shoff + delta
struct.pack_into('<I', new_data, 0x20, new_e_shoff)

new_shdr = struct.pack('<IIIIIIIIII',
    0,                      # sh_name (reuse empty name at shstrtab[0])
    1,                      # sh_type = SHT_PROGBITS
    6,                      # sh_flags = ALLOC | EXECINSTR (matches .health.elf.text)
    NEW_PHYS_BASE,          # sh_addr
    insertion_offset,       # sh_offset
    new_section_size,       # sh_size
    0, 0, 0, 0)

new_shdr_table_off = new_e_shoff + e_shnum*e_shentsize
new_data[new_shdr_table_off:new_shdr_table_off+40] = new_shdr
new_e_shnum = e_shnum + 1
struct.pack_into('<H', new_data, 0x30, new_e_shnum)

print(f"\ne_shoff: 0x{e_shoff:x} -> 0x{new_e_shoff:x}")
print(f"e_shnum: {e_shnum} -> {new_e_shnum}")

open(OUT_PATH, 'wb').write(new_data)
print(f"\nWrote {OUT_PATH} ({len(new_data)} bytes, was {len(data)} bytes, grew by {len(new_data)-len(data)})")
