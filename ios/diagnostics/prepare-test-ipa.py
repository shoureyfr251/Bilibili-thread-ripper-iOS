#!/usr/bin/env python3
"""Prepare a local diagnostic IPA. Existing signatures become invalid; re-sign it.

Uses Python standard library only. Does not decrypt, sign, install or execute apps.
"""
import argparse
import copy
import hashlib
import json
import mmap
import pathlib
import plistlib
import posixpath
import re
import shutil
import stat
import struct
import tempfile
import uuid
import zipfile

SOURCE_BUNDLE = 'tv.danmaku.bilianime'
SOURCE_VERSION = '8.89.0'
SOURCE_SHA256 = 'e48351cb4cfc526236e68e0d7dbb2f46002fa9724ec292849c1f9e12220f0087'
PROBE_NAME = 'BTRProcessProbe.dylib'
LOAD_PATH = '@executable_path/Frameworks/' + PROBE_NAME
AUTHOR_TWEAK_PATH = '@executable_path/Frameworks/BilibiliVideoTools.dylib'
MAX_TOTAL = 2 * 1024 ** 3
MAX_ENTRY = 1024 ** 3

def sha256(path):
    with pathlib.Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def export_with_directory_acl(staged, output):
    """Copy bytes into a normal new sibling so it inherits the output directory ACL."""
    if output.exists():
        raise FileExistsError('Output already exists; use a fresh filename')
    export = output.with_name(f'.{output.name}.{uuid.uuid4().hex}.exporting')
    created = False
    try:
        # Do not move the protected TemporaryDirectory file or copy its metadata.
        with export.open('xb') as dest:
            created = True
            with staged.open('rb') as src:
                shutil.copyfileobj(src, dest, 1024 * 1024)
        # On Windows rename is atomic and refuses an already-existing destination.
        export.rename(output)
    finally:
        if created:
            export.unlink(missing_ok=True)

def parse_macho(data, expected_type):
    """Validate thin ARM64 headers and derive the first file-backed payload byte."""
    if len(data) < 32:
        raise ValueError('Mach-O header is truncated')
    magic, cpu, subtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack_from('<8I', data)
    if magic != 0xfeedfacf or cpu != 0x100000c or subtype != 0:
        raise ValueError('Only thin little-endian ARM64 (not ARM64e) is supported')
    if filetype != expected_type:
        raise ValueError('Unexpected Mach-O file type')
    end = 32 + sizeofcmds
    if end > len(data) or ncmds > sizeofcmds // 8:
        raise ValueError('Load commands are truncated or have invalid count')
    cursor, payload_offsets, encryption, libraries, rpaths = 32, [], [], [], []
    binding_ranges, symbol_table, undefined_range, chained_fixups = {}, None, None, False
    for _ in range(ncmds):
        if cursor + 8 > end:
            raise ValueError('Load-command header exceeds sizeofcmds')
        cmd, size = struct.unpack_from('<II', data, cursor)
        if size < 8 or size % 8 or cursor + size > end:
            raise ValueError('Invalid load-command size or alignment')
        if cmd == 0x19:  # LC_SEGMENT_64
            if size < 72:
                raise ValueError('Truncated segment command')
            segment = struct.unpack_from('<II16s4Q4I', data, cursor)
            fileoff, filesize, sections = segment[5], segment[6], segment[9]
            if size != 72 + sections * 80 or fileoff + filesize > len(data):
                raise ValueError('Invalid segment/section layout')
            if fileoff and filesize:
                payload_offsets.append(fileoff)
            for i in range(sections):
                section = struct.unpack_from('<16s16s2Q8I', data, cursor + 72 + i * 80)
                length, offset, section_type = section[3], section[4], section[8] & 0xff
                if length and section_type not in (1, 0xc, 0x12):  # zero-fill types
                    if not offset or offset + length > len(data):
                        raise ValueError('File-backed section is out of bounds')
                    payload_offsets.append(offset)
        elif cmd in (0x21, 0x2c):
            if size != 24:
                raise ValueError('Unexpected encryption command size')
            cryptoff, cryptsize, cryptid = struct.unpack_from('<3I', data, cursor + 8)
            if cryptoff + cryptsize > len(data):
                raise ValueError('Encryption range is out of bounds')
            if cryptid:
                raise ValueError('Encrypted Mach-O refused; no decryption is performed')
            encryption.append({'cryptoff': cryptoff, 'cryptsize': cryptsize, 'cryptid': cryptid})
            if cryptoff and cryptsize:
                payload_offsets.append(cryptoff)
        elif cmd in (0xc, 0xd, 0x80000018, 0x8000001f, 0x20, 0x80000023):
            if size < 24:
                raise ValueError('Truncated dylib command')
            nameoff = struct.unpack_from('<I', data, cursor + 8)[0]
            if not 24 <= nameoff < size:
                raise ValueError('Invalid dylib name offset')
            raw = bytes(data[cursor + nameoff:cursor + size])
            if b'\0' not in raw:
                raise ValueError('Unterminated dylib name')
            if cmd != 0xd:  # LC_ID_DYLIB is an identity, not a dependency ordinal.
                libraries.append({'command': cmd, 'path': raw.split(b'\0')[0].decode('utf-8', 'strict'),
                                  'ordinal': len(libraries) + 1, 'command_offset': cursor,
                                  'command_size': size, 'name_offset': nameoff})
        elif cmd == 0x8000001c:  # LC_RPATH
            if size < 16:
                raise ValueError('Truncated rpath command')
            nameoff = struct.unpack_from('<I', data, cursor + 8)[0]
            if not 12 <= nameoff < size:
                raise ValueError('Invalid rpath name offset')
            raw = bytes(data[cursor + nameoff:cursor + size])
            if b'\0' not in raw:
                raise ValueError('Unterminated rpath')
            rpaths.append(raw.split(b'\0')[0].decode('utf-8', 'strict'))
        elif cmd in (0x1d, 0x1e, 0x26, 0x29, 0x2b, 0x2e, 0x80000033, 0x80000034):
            if size != 16:
                raise ValueError('Invalid linkedit data command')
            offset, length = struct.unpack_from('<2I', data, cursor + 8)
            if offset + length > len(data):
                raise ValueError('Linkedit payload is out of bounds')
            if offset and length:
                payload_offsets.append(offset)
            if cmd == 0x80000034:
                chained_fixups = True
        elif cmd == 0x2:  # LC_SYMTAB
            if size != 24:
                raise ValueError('Invalid symbol-table command')
            symoff, nsyms, stroff, strsize = struct.unpack_from('<4I', data, cursor + 8)
            symbol_table = (symoff, nsyms, stroff, strsize)
            if symoff + nsyms * 16 > len(data) or stroff + strsize > len(data):
                raise ValueError('Symbol/string table exceeds file')
            payload_offsets.extend(off for off, count in ((symoff, nsyms), (stroff, strsize)) if off and count)
        elif cmd == 0xb:  # LC_DYSYMTAB undefined symbol subrange
            if size != 80:
                raise ValueError('Invalid dynamic symbol-table command')
            undefined_range = struct.unpack_from('<2I', data, cursor + 24)
        elif cmd in (0x22, 0x80000022):
            if size != 48:
                raise ValueError('Invalid dyld-info command')
            values = struct.unpack_from('<10I', data, cursor + 8)
            binding_ranges = {name: values[index:index + 2] for name, index in
                              (('bind', 2), ('weak_bind', 4), ('lazy_bind', 6))}
            for offset, length in zip(values[::2], values[1::2]):
                if offset + length > len(data):
                    raise ValueError('Dyld-info data exceeds file')
                if offset and length:
                    payload_offsets.append(offset)
        cursor += size
    if cursor != end or not payload_offsets or min(payload_offsets) < end:
        raise ValueError('Invalid load-command boundary or no safe payload boundary')
    if expected_type == 2 and not encryption:
        raise ValueError('Expected explicit cryptid=0 encryption command in source executable')
    return {'ncmds': ncmds, 'sizeofcmds': sizeofcmds, 'command_end': end,
            'first_payload_offset': min(payload_offsets), 'encryption': encryption,
            'libraries': libraries, 'rpaths': rpaths, 'cpu': 'ARM64',
            'binding_ranges': binding_ranges, 'symbol_table': symbol_table,
            'undefined_range': undefined_range, 'chained_fixups': chained_fixups}

def verify_unused_ordinal(data, metadata, target):
    """Refuse replacement if any binding action or undefined symbol uses the slot."""
    if metadata['chained_fixups']:
        raise ValueError('Chained imports require separate analysis; slot replacement refused')

    def leb(blob, position):
        value = shift = 0
        while position < len(blob):
            byte = blob[position]
            position += 1
            value |= (byte & 127) << shift
            if not byte & 128:
                return value, position
            shift += 7
            if shift > 63:
                break
        raise ValueError('Invalid or truncated bind LEB128')

    result = {}
    for name, (offset, length) in metadata['binding_ranges'].items():
        blob = bytes(data[offset:offset + length])
        position = ordinal = actions = target_actions = 0
        while position < len(blob):
            byte = blob[position]
            position += 1
            opcode, immediate = byte & 0xf0, byte & 15
            if opcode == 0:
                ordinal = 0  # Lazy bind sequences restart after DONE.
            elif opcode == 0x10:
                ordinal = immediate
            elif opcode == 0x20:
                ordinal, position = leb(blob, position)
            elif opcode == 0x30:
                ordinal = immediate - 16 if immediate else 0
            elif opcode == 0x40:
                position = blob.index(0, position) + 1
            elif opcode == 0x50:
                pass
            elif opcode in (0x60, 0x70, 0x80):
                _, position = leb(blob, position)
            elif opcode in (0x90, 0xa0, 0xb0, 0xc0):
                count = 1
                if opcode == 0xa0:
                    _, position = leb(blob, position)
                elif opcode == 0xc0:
                    count, position = leb(blob, position)
                    _, position = leb(blob, position)
                actions += count
                if ordinal == target:
                    target_actions += count
            else:
                raise ValueError(f'Unsupported bind opcode {hex(byte)}; replacement refused')
        result[name] = {'binding_actions': actions, 'target_bindings': target_actions}
        if target_actions:
            raise ValueError('Author tweak slot has symbol bindings; replacement refused')
    if not metadata['symbol_table'] or not metadata['undefined_range']:
        raise ValueError('Missing symbol tables required to verify the author slot')
    symoff, nsyms, _, _ = metadata['symbol_table']
    first, count = metadata['undefined_range']
    if first + count > nsyms:
        raise ValueError('Invalid undefined symbol range')
    for index in range(first, first + count):
        descriptor = struct.unpack_from('<H', data, symoff + 16 * index + 6)[0]
        if descriptor >> 8 == target:
            raise ValueError('Author tweak slot has undefined symbols; replacement refused')
    result.update(undefined_symbols_checked=count, target_undefined_symbols=0, chained_imports='absent')
    return result

def patch_macho(path):
    with pathlib.Path(path).open('r+b') as stream, mmap.mmap(stream.fileno(), 0) as data:
        before = parse_macho(data, 2)
        if any(lib['path'] == LOAD_PATH for lib in before['libraries']):
            raise ValueError('Probe load command already exists')
        slots = [lib for lib in before['libraries'] if lib['path'] == AUTHOR_TWEAK_PATH]
        if len(slots) != 1:
            raise ValueError('Expected exactly one author tweak load slot')
        slot = slots[0]
        if slot['command'] != 0xc or slot['ordinal'] != 121 or slot['command_size'] != 80:
            raise ValueError('Author tweak slot differs from the verified 8.89.0 sample')
        binding_proof = verify_unused_ordinal(data, before, slot['ordinal'])
        name = LOAD_PATH.encode() + b'\0'
        start = slot['command_offset'] + slot['name_offset']
        finish = slot['command_offset'] + slot['command_size']
        if len(name) > finish - start:
            raise ValueError('Replacement path does not fit the existing command slot')
        data[start:finish] = name.ljust(finish - start, b'\0')
        after = parse_macho(data, 2)
        expected = [dict(lib, path=LOAD_PATH) if lib['path'] == AUTHOR_TWEAK_PATH else lib
                    for lib in before['libraries']]
        if (after['libraries'] != expected or after['ncmds'] != before['ncmds']
                or after['sizeofcmds'] != before['sizeofcmds']):
            raise ValueError('Patched library slots/counts/ordinals changed unexpectedly')
        data.flush()
        return {'strategy': 'replace unused author tweak path in place',
                'removed_load_path': AUTHOR_TWEAK_PATH, 'load_path': LOAD_PATH,
                'preserved_ordinal': slot['ordinal'], 'preserved_command_size': slot['command_size'],
                'library_count_unchanged': len(after['libraries']), 'binding_proof': binding_proof,
                'new_ncmds': after['ncmds'], 'new_sizeofcmds': after['sizeofcmds'],
                'modified_regions': [f'load-command name/padding at offsets {start}..{finish - 1}']}

def verify_dependency_closure(archive, main_member):
    """Resolve all bundled Mach-O dependencies; system paths are OS-provided assumptions."""
    images = {}
    for entry in archive.infolist():
        if entry.is_dir():
            continue
        with archive.open(entry) as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'):
            continue
        data = archive.read(entry)
        filetype = struct.unpack_from('<I', data, 12)[0]
        images['/' + entry.filename] = parse_macho(data, filetype)
    main = '/' + main_member
    if main not in images:
        raise ValueError('Main executable missing from dependency inventory')
    executable_dir = posixpath.dirname(main)

    def expand(path, owner):
        for token, base in (('@executable_path', executable_dir), ('@loader_path', posixpath.dirname(owner))):
            if path == token or path.startswith(token + '/'):
                return posixpath.normpath(base + path[len(token):])
        if path.startswith('/'):
            return posixpath.normpath(path)
        raise ValueError(f'Unsupported dependency/rpath expression: {path}')

    def system(path):
        return path.startswith('/System/Library/') or path.startswith('/usr/lib/')

    resolved, system_assumptions, visited = [], set(), set()
    main_rpaths = [(main, path) for path in images[main]['rpaths']]
    queue = [(main, [])]
    while queue or len(visited) < len(images):
        if not queue:
            queue.append((next(path for path in images if path not in visited), main_rpaths))
        owner, inherited_rpaths = queue.pop(0)
        if owner in visited:
            continue
        visited.add(owner)
        metadata = images[owner]
        rpaths = [(owner, path) for path in metadata['rpaths']] + inherited_rpaths
        for library in metadata['libraries']:
            path = library['path']
            if 'BilibiliVideoTools' in path or 'ellekit' in path.lower():
                raise ValueError('Removed author tweak/ElleKit dependency remains in package')
            if path.startswith('@rpath/'):
                candidates = [posixpath.normpath(expand(rpath, rpath_owner) + '/' + path[7:])
                              for rpath_owner, rpath in rpaths]
                # Prefer verifiable bundled candidates. Swift runtime candidates in the
                # system runpath are allowed; arbitrary app frameworks there are not.
                target = next((candidate for candidate in candidates if candidate in images), None)
                if target is None:
                    target = next((candidate for candidate in candidates
                                   if candidate.startswith('/usr/lib/swift/')
                                   and re.fullmatch(r'libswift[A-Za-z0-9_]+\.dylib', posixpath.basename(candidate))
                                   and posixpath.dirname(candidate) == '/usr/lib/swift'), None)
            else:
                target = expand(path, owner)
            if target is None or (not system(target) and target not in images):
                raise ValueError(f'Unresolved non-system dependency from {owner}: {path}')
            if target in images:
                resolved.append({'image': owner[1:], 'load_path': path, 'resolved': target[1:]})
                queue.append((target, rpaths))
            else:
                system_assumptions.add(target)
    return {'verified': True, 'mach_o_inventory': [path[1:] for path in images],
            'resolved_bundled_dependencies': resolved, 'missing_non_system_dependencies': [],
            'system_path_assumptions': sorted(system_assumptions),
            'scope': 'Static bundled dependency closure; system library availability and runtime behavior are not device-tested.'}

def validate_zip(archive):
    entries, names, total = archive.infolist(), set(), 0
    for entry in entries:
        name = entry.filename
        parts = name.rstrip('/').split('/')
        if (not name or name.startswith('/') or '\\' in name or ':' in name or '\0' in name
                or any(part in ('', '.', '..') for part in parts) or name in names):
            raise ValueError('Unsafe or duplicate ZIP path')
        mode = entry.external_attr >> 16
        if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
            raise ValueError('ZIP symlinks and special files are refused')
        if entry.flag_bits & 1 or entry.file_size > MAX_ENTRY:
            raise ValueError('Encrypted or oversized ZIP member refused')
        names.add(name)
        total += entry.file_size
        if total > MAX_TOTAL:
            raise ValueError('ZIP uncompressed size exceeds 2 GiB limit')
    plists = [name for name in names if re.fullmatch(r'[^/]+\.app/Info\.plist', name)]
    if len(plists) != 1:
        raise ValueError('Expected exactly one top-level .app bundle')
    return entries, plists[0], total

def prepare(args):
    source, probe, output = (pathlib.Path(x).resolve() for x in (args.source_app_zip, args.probe, args.output))
    if output == source or output == probe or output.suffix.lower() != '.ipa':
        raise ValueError('Output must be a distinct .ipa path')
    if output.exists() or output.with_suffix('.inspection.json').exists():
        raise ValueError('Output already exists; use a fresh filename')
    if output.drive.upper() != 'D:':
        raise ValueError('Diagnostic outputs must be on D:')
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id) or args.bundle_id == SOURCE_BUNDLE:
        raise ValueError('Use a distinct, valid diagnostic bundle identifier')
    source_hash = sha256(source)
    if source_hash != SOURCE_SHA256:
        raise ValueError('Source archive does not match the verified author 8.89.0 sample SHA-256')
    with probe.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
        probe_info = parse_macho(data, 6)
    probe_hash = sha256(probe)
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(source) as archive, tempfile.TemporaryDirectory(prefix='btr-ipa-', dir=output.parent) as temp:
        entries, plist_path, total = validate_zip(archive)
        original_plist = archive.read(plist_path)
        info = plistlib.loads(original_plist)
        if info.get('CFBundleIdentifier') != SOURCE_BUNDLE or info.get('CFBundleShortVersionString') != SOURCE_VERSION:
            raise ValueError('Unexpected source bundle identifier/version')
        executable = info.get('CFBundleExecutable')
        if not isinstance(executable, str) or '/' in executable or '\\' in executable or executable in ('', '.', '..'):
            raise ValueError('Invalid bundle executable name')
        app_root = plist_path[:-len('Info.plist')]
        binary_path = app_root + executable
        probe_member = app_root + 'Frameworks/' + PROBE_NAME
        author_member = app_root + 'Frameworks/BilibiliVideoTools.dylib'
        if probe_member in archive.namelist():
            raise ValueError('Source already contains diagnostic probe')
        binary_temp = pathlib.Path(temp) / 'executable'
        with archive.open(binary_path) as src, binary_temp.open('wb') as dest:
            shutil.copyfileobj(src, dest, 1024 * 1024)
        original_binary_hash = sha256(binary_temp)
        patch = patch_macho(binary_temp)
        info.update(CFBundleIdentifier=args.bundle_id, CFBundleDisplayName=args.display_name,
                    BTRProbeEnabled=True, BTRProbeSourceBundleIdentifier=SOURCE_BUNDLE,
                    BTRProbeSourceVersion=SOURCE_VERSION)
        # Report hand-off to the PC receiver (ios/dev/report-receiver.mjs) needs its Bonjour type.
        services = list(info.get('NSBonjourServices') or [])
        if '_btrreport._tcp' not in services: services.append('_btrreport._tcp')
        info['NSBonjourServices'] = services
        plist_data = plistlib.dumps(info, fmt=plistlib.FMT_BINARY if original_plist.startswith(b'bplist') else plistlib.FMT_XML, sort_keys=False)
        staged = pathlib.Path(temp) / 'prepared.ipa'
        preserved, skipped, removed = 0, 0, 0
        with zipfile.ZipFile(staged, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=3, allowZip64=True) as dest:
            dest.comment = b'BTR diagnostic package: signatures invalid. Must be re-signed before installation.'
            for entry in entries:
                if not entry.filename.startswith(app_root):
                    skipped += 1  # __MACOSX packaging metadata is not app payload
                    continue
                if entry.filename == author_member:
                    removed += 1
                    continue
                renamed = copy.copy(entry)
                renamed.filename = 'Payload/' + entry.filename
                renamed._compresslevel = 3
                if entry.filename == plist_path:
                    dest.writestr(renamed, plist_data)
                elif entry.filename == binary_path:
                    with binary_temp.open('rb') as src, dest.open(renamed, 'w', force_zip64=True) as dst:
                        shutil.copyfileobj(src, dst, 1024 * 1024)
                else:
                    with archive.open(entry) as src, dest.open(renamed, 'w', force_zip64=True) as dst:
                        shutil.copyfileobj(src, dst, 1024 * 1024)
                    preserved += 1
            probe_entry = zipfile.ZipInfo('Payload/' + probe_member)
            probe_entry.compress_type = zipfile.ZIP_DEFLATED
            probe_entry._compresslevel = 3
            probe_entry.external_attr = (stat.S_IFREG | 0o755) << 16
            with probe.open('rb') as src, dest.open(probe_entry, 'w', force_zip64=True) as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
        with zipfile.ZipFile(staged) as check:
            if removed != 1 or 'Payload/' + author_member in check.namelist():
                raise ValueError('Author tweak file removal verification failed')
            read_info = plistlib.loads(check.read('Payload/' + plist_path))
            if any(read_info.get(k) != info[k] for k in ('CFBundleIdentifier', 'BTRProbeEnabled', 'BTRProbeSourceBundleIdentifier', 'BTRProbeSourceVersion')):
                raise ValueError('Output plist validation failed')
            with check.open('Payload/' + probe_member) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != probe_hash:
                    raise ValueError('Packaged probe SHA-256 mismatch')
            with check.open('Payload/' + binary_path) as src, binary_temp.open('wb') as dst:
                shutil.copyfileobj(src, dst, 1024 * 1024)
            with binary_temp.open('rb') as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                read_binary = parse_macho(data, 2)
                if (sum(lib['path'] == LOAD_PATH and lib['command'] == 0xc and lib['ordinal'] == 121
                        for lib in read_binary['libraries']) != 1
                        or read_binary['ncmds'] != patch['new_ncmds']
                        or read_binary['sizeofcmds'] != patch['new_sizeofcmds']
                        or len(read_binary['libraries']) != patch['library_count_unchanged']):
                    raise ValueError('Output Mach-O probe load-command verification failed')
            dependencies = verify_dependency_closure(check, 'Payload/' + binary_path)
        report = {'source_archive': str(source), 'source_sha256': source_hash,
                  'source_bundle': SOURCE_BUNDLE, 'source_version': SOURCE_VERSION,
                  'original_executable_sha256': original_binary_hash,
                  'packaged_executable_sha256': sha256(binary_temp),
                  'probe': str(probe), 'probe_sha256': probe_hash, 'probe_cpu': probe_info['cpu'],
                  'output': str(output), 'output_sha256': sha256(staged), 'diagnostic_bundle': args.bundle_id,
                  'zip_uncompressed_input_bytes': total, 'preserved_app_entries': preserved,
                  'skipped_non_payload_metadata_entries': skipped, 'macho_patch': patch,
                  'removed_author_tweak': author_member, 'dependency_closure': dependencies,
                  'readback_verified': True, 'requires_resigning': True,
                  'limitations': ['Existing embedded signatures are invalid and are preserved, not forged.',
                                  'No signing, installation, execution or device verification performed.',
                                  'URL schemes, account state and original entitlements were not edited.',
                                  'Author BilibiliVideoTools tweak and its additional features were removed.',
                                  'Changed bundle ID may break app features; functional compatibility is unverified.']}
        export_with_directory_acl(staged, output)
        report_path = output.with_suffix('.inspection.json')
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps({'output': str(output), 'report': str(report_path), 'requires_resigning': True, 'readback_verified': True}, ensure_ascii=False))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-app-zip', required=True)
    parser.add_argument('--probe', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--bundle-id', default='local.btr.bilibili-probe')
    parser.add_argument('--display-name', default='B站接入诊断')
    args = parser.parse_args()
    try:
        prepare(args)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, struct.error) as error:
        parser.exit(1, f'Preparation refused: {error}\n')

if __name__ == '__main__':
    main()
