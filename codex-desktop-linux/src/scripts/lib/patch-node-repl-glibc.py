#!/usr/bin/env python3
"""Lower the known node_repl x86-64 glibc symbol bindings to a 2.28 floor."""

from __future__ import annotations

import pathlib
import struct
import sys


MAX_GLIBC = (2, 28)
TARGET_VERSION = "GLIBC_2.28"
NODE_REPL_MARKERS = {
    "pidfd_getpid",
    "pidfd_spawnp",
}
SUPPORTED_HIGH_SYMBOLS = {
    ("GLIBC_2.29", "posix_spawn_file_actions_addchdir_np"),
    ("GLIBC_2.29", "pow"),
    ("GLIBC_2.30", "gettid"),
    ("GLIBC_2.32", "pthread_getattr_np"),
    ("GLIBC_2.33", "fstat64"),
    ("GLIBC_2.33", "lstat64"),
    ("GLIBC_2.33", "stat64"),
    ("GLIBC_2.34", "__libc_start_main"),
    ("GLIBC_2.34", "dlsym"),
    ("GLIBC_2.34", "pthread_attr_getguardsize"),
    ("GLIBC_2.34", "pthread_attr_getstack"),
    ("GLIBC_2.34", "pthread_attr_setstacksize"),
    ("GLIBC_2.34", "pthread_create"),
    ("GLIBC_2.34", "pthread_detach"),
    ("GLIBC_2.34", "pthread_join"),
    ("GLIBC_2.34", "pthread_key_create"),
    ("GLIBC_2.34", "pthread_key_delete"),
    ("GLIBC_2.34", "pthread_setname_np"),
    ("GLIBC_2.34", "pthread_setspecific"),
    ("GLIBC_2.39", "pidfd_getpid"),
    ("GLIBC_2.39", "pidfd_spawnp"),
}
WEAK_FALLBACK_SYMBOLS = {
    "gettid",
    "pidfd_getpid",
    "pidfd_spawnp",
    "posix_spawn_file_actions_addchdir_np",
}


def fail(message: str) -> None:
    raise SystemExit(f"node_repl glibc patch: {message}")


def read_cstr(blob: bytes | bytearray, offset: int) -> str:
    if offset < 0 or offset >= len(blob):
        return ""
    end = blob.find(b"\0", offset)
    if end < 0:
        end = len(blob)
    return blob[offset:end].decode("utf-8", "replace")


def elf_hash(name: str) -> int:
    value = 0
    for byte in name.encode("utf-8"):
        value = (value << 4) + byte
        high = value & 0xF0000000
        if high:
            value ^= high >> 24
            value &= ~high
    return value & 0xFFFFFFFF


def glibc_version_tuple(name: str) -> tuple[int, ...] | None:
    if not name.startswith("GLIBC_"):
        return None
    try:
        return tuple(int(part) for part in name[len("GLIBC_") :].split("."))
    except ValueError:
        return None


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch-node-repl-glibc.py NODE_REPL_ELF")

    path = pathlib.Path(sys.argv[1])
    data = bytearray(path.read_bytes())
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        print("unchanged")
        return
    if struct.unpack_from("<H", data, 18)[0] != 62:
        print("unchanged")
        return

    section_offset = struct.unpack_from("<Q", data, 40)[0]
    section_entry_size = struct.unpack_from("<H", data, 58)[0]
    section_count = struct.unpack_from("<H", data, 60)[0]
    section_names_index = struct.unpack_from("<H", data, 62)[0]
    if (
        section_offset == 0
        or section_entry_size < 64
        or section_count == 0
        or section_names_index >= section_count
        or section_offset + section_count * section_entry_size > len(data)
    ):
        print("unchanged")
        return

    sections = []
    for index in range(section_count):
        fields = struct.unpack_from(
            "<IIQQQQIIQQ", data, section_offset + index * section_entry_size
        )
        sections.append(
            {
                "name_offset": fields[0],
                "offset": fields[4],
                "size": fields[5],
                "entry_size": fields[9],
            }
        )

    section_names = sections[section_names_index]
    section_names_data = data[
        section_names["offset"] : section_names["offset"] + section_names["size"]
    ]
    sections_by_name = {
        read_cstr(section_names_data, section["name_offset"]): section
        for section in sections
    }
    try:
        dynamic_symbols = sections_by_name[".dynsym"]
        dynamic_strings = sections_by_name[".dynstr"]
        version_symbols = sections_by_name[".gnu.version"]
        version_needs = sections_by_name[".gnu.version_r"]
    except KeyError:
        print("unchanged")
        return
    if dynamic_symbols["entry_size"] < 24:
        fail("unsupported dynamic symbol entry size")

    dynamic_string_data = data[
        dynamic_strings["offset"] : dynamic_strings["offset"] + dynamic_strings["size"]
    ]
    target_name_offset = dynamic_string_data.find((TARGET_VERSION + "\0").encode())

    version_names: dict[int, str] = {}
    version_aux_offsets: dict[int, int] = {}
    cursor = version_needs["offset"]
    version_needs_end = cursor + version_needs["size"]
    while cursor and cursor + 16 <= version_needs_end:
        version, count, _file, auxiliary, next_record = struct.unpack_from(
            "<HHIII", data, cursor
        )
        if version == 0 or count == 0:
            break
        auxiliary_cursor = cursor + auxiliary
        for _ in range(count):
            if auxiliary_cursor + 16 > version_needs_end:
                fail("version need auxiliary record is outside section bounds")
            _hash, _flags, other, name_offset, next_auxiliary = struct.unpack_from(
                "<IHHII", data, auxiliary_cursor
            )
            version_names[other] = read_cstr(dynamic_string_data, name_offset)
            version_aux_offsets[other] = auxiliary_cursor
            if next_auxiliary == 0:
                break
            auxiliary_cursor += next_auxiliary
        if next_record == 0:
            break
        cursor += next_record

    symbol_records = []
    all_symbol_names = set()
    symbol_count = dynamic_symbols["size"] // dynamic_symbols["entry_size"]
    for index in range(symbol_count):
        symbol_offset = dynamic_symbols["offset"] + index * dynamic_symbols["entry_size"]
        name_offset, info, _other, section_index = struct.unpack_from(
            "<IBBH", data, symbol_offset
        )
        name = read_cstr(dynamic_string_data, name_offset)
        all_symbol_names.add(name)
        version_offset = version_symbols["offset"] + index * 2
        if version_offset + 2 > version_symbols["offset"] + version_symbols["size"]:
            fail("version symbol entry is outside section bounds")
        raw_version = struct.unpack_from("<H", data, version_offset)[0]
        version_id = raw_version & 0x7FFF
        version_name = version_names.get(version_id, "")
        parsed_version = glibc_version_tuple(version_name)
        if parsed_version is None or parsed_version <= MAX_GLIBC:
            continue
        symbol_records.append(
            {
                "name": name,
                "version": version_name,
                "version_offset": version_offset,
                "binding": info >> 4,
                "section_index": section_index,
            }
        )

    if not NODE_REPL_MARKERS.issubset(all_symbol_names):
        print("unchanged")
        return
    if target_name_offset < 0:
        fail(f"target version string is missing: {TARGET_VERSION}")

    unsupported = sorted(
        (record["version"], record["name"])
        for record in symbol_records
        if (record["version"], record["name"]) not in SUPPORTED_HIGH_SYMBOLS
    )
    if unsupported:
        fail(
            "unsupported references above GLIBC_2.28: "
            + ", ".join(f"{name}@{version}" for version, name in unsupported)
        )

    for record in symbol_records:
        if record["section_index"] != 0:
            fail(f"high-version symbol is not undefined: {record['name']}")
        if record["name"] in WEAK_FALLBACK_SYMBOLS and record["binding"] != 2:
            fail(f"fallback symbol is no longer weak: {record['name']}")
        struct.pack_into("<H", data, record["version_offset"], 1)

    changed_version_record = False
    for version_id, version_name in version_names.items():
        parsed_version = glibc_version_tuple(version_name)
        if parsed_version is None or parsed_version <= MAX_GLIBC:
            continue
        auxiliary_offset = version_aux_offsets[version_id]
        struct.pack_into("<I", data, auxiliary_offset, elf_hash(TARGET_VERSION))
        struct.pack_into("<I", data, auxiliary_offset + 8, target_name_offset)
        changed_version_record = True

    if not symbol_records and not changed_version_record:
        print("unchanged")
        return
    path.write_bytes(data)
    print("patched")


if __name__ == "__main__":
    main()
