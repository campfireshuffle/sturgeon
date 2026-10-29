#!/usr/bin/env python3
"""extract.py <dylib> <out.img> <out.syms.json>

Flatten the payload dylib into one contiguous image that can be written at *any* 16K-aligned
base: every section keeps its link-time offset relative to the image base, so all PC-relative
references (adrp/add, b, bl, literal loads) stay correct after relocation.
"""
import json
import struct
import subprocess
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2


def parse(path):
    d = open(path, "rb").read()
    magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags, res = struct.unpack_from("<IiiIIIII", d, 0)
    assert magic == MH_MAGIC_64, hex(magic)
    off = 32
    segs, symtab = [], None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", d, off)
        if cmd == LC_SEGMENT_64:
            name = d[off + 8:off + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, off + 24)
            maxprot, initprot, nsects, sflags = struct.unpack_from("<IIII", d, off + 56)
            sects = []
            so = off + 72
            for _ in range(nsects):
                sname = d[so:so + 16].rstrip(b"\0").decode()
                sseg = d[so + 16:so + 32].rstrip(b"\0").decode()
                addr, size, offset = struct.unpack_from("<QQI", d, so + 32)
                sects.append({"name": sname, "seg": sseg, "addr": addr, "size": size,
                              "offset": offset, "prot": initprot})
                so += 80
            segs.append({"name": name, "vmaddr": vmaddr, "vmsize": vmsize,
                         "fileoff": fileoff, "filesize": filesize, "prot": initprot,
                         "sects": sects})
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", d, off + 8)
        off += cmdsize
    return d, segs, symtab


def main():
    path, out_img, out_syms = sys.argv[1:4]
    d, segs, symtab = parse(path)
    base = min(s["vmaddr"] for s in segs if s["sects"]) if segs else 0
    end = 0
    for s in segs:
        for sec in s["sects"]:
            if sec["size"]:
                end = max(end, sec["addr"] + sec["size"] - base)
    img = bytearray((end + 0x3FFF) & ~0x3FFF)
    ranges = []
    for s in segs:
        if s["name"] == "__PAGEZERO":
            continue
        for sec in s["sects"]:
            if not sec["size"] or sec["name"] in ("__bss", "__common"):
                ranges.append({"name": sec["seg"] + "," + sec["name"],
                               "off": sec["addr"] - base, "size": sec["size"],
                               "prot": sec["prot"], "zero": True})
                continue
            img[sec["addr"] - base:sec["addr"] - base + sec["size"]] = \
                d[sec["offset"]:sec["offset"] + sec["size"]]
            ranges.append({"name": sec["seg"] + "," + sec["name"],
                           "off": sec["addr"] - base, "size": sec["size"],
                           "prot": sec["prot"], "zero": False})
    open(out_img, "wb").write(bytes(img))
    syms = {}
    if symtab:
        symoff, nsyms, stroff, strsize = symtab
        for i in range(nsyms):
            n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBhQ", d, symoff + 16 * i)
            if (n_type & 0x0E) != 0 and (n_type & 0xE0) != 0xE0 and n_value:
                name = d[stroff + n_strx:].split(b"\0")[0].decode(errors="replace")
                if name and n_value >= base:
                    syms[name] = n_value - base
    json.dump({"base": base, "size": len(img), "sections": ranges, "syms": syms},
              open(out_syms, "w"), indent=1)
    # sanity: no absolute internal pointers (would need relocation)
    bad = []
    tlo = min([sec["addr"] for s in segs for sec in s["sects"]
               if sec["name"] == "__text"] or [0x400])
    for s in segs:
        for sec in s["sects"]:
            if sec["size"] and sec["name"] in ("__data", "__const", "__bss", "__common"):
                chunk = img[sec["addr"] - base:sec["addr"] - base + sec["size"]]
                for i in range(0, len(chunk) - 7, 8):
                    v = struct.unpack_from("<Q", chunk, i)[0]
                    if tlo <= v < end and v % 4 == 0:
                        bad.append((sec["name"], hex(sec["addr"] + i), hex(v)))
    print("image %d bytes at link base %#x, %d symbols, %d absolute-internal pointers %s"
          % (len(img), base, len(syms), len(bad), bad[:6]))


if __name__ == "__main__":
    main()
