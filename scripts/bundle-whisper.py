#!/usr/bin/env python3
"""Relocate an installed whisper.cpp runtime into an existing macOS .app.

No downloads. Includes dynamic GGML backends and publisher license notices.
"""
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
engine = pathlib.Path(sys.argv[2]).resolve()
frameworks = app / 'Contents/Frameworks'
bin_dir = app / 'Contents/Resources/bin'
notices = app / 'Contents/Resources/ThirdPartyNotices'
for directory in (frameworks, bin_dir, notices):
    directory.mkdir(parents=True, exist_ok=True)


def command(*args):
    return subprocess.check_output(args, text=True)


def dependencies(path):
    return [line.strip().split(' (compatibility')[0] for line in command('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]


def rpaths(path):
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset', command('/usr/bin/otool', '-l', str(path)))


def is_system(path):
    return path.startswith(('/usr/lib/', '/System/Library/'))


def resolve(dependency, source):
    if dependency.startswith('/'):
        candidate = pathlib.Path(dependency)
        if candidate.exists():
            return candidate.resolve()
    if dependency.startswith('@loader_path/'):
        candidate = source.parent / dependency[len('@loader_path/'):]
        if candidate.exists():
            return candidate.resolve()
    if dependency.startswith('@rpath/'):
        tail = dependency[len('@rpath/'):]
        for prefix in rpaths(source):
            base = prefix.replace('@loader_path', str(source.parent)).replace('@executable_path', str(engine.parent))
            candidate = pathlib.Path(base) / tail
            if candidate.exists():
                return candidate.resolve()
        for base in (source.parent, source.parent.parent / 'lib', engine.parent.parent / 'lib', pathlib.Path('/opt/homebrew/lib'), pathlib.Path('/usr/local/lib')):
            candidate = base / tail
            if candidate.exists():
                return candidate.resolve()
    raise RuntimeError(f'Cannot resolve {dependency} from {source}')


helper = pathlib.Path(subprocess.check_output([str(pathlib.Path(__file__).with_name("build-live-whisper.sh"))], text=True).strip()).resolve()
pending = [engine, helper]
mapping = {engine: bin_dir / 'whisper-cli-native', helper: bin_dir / 'justwisper-live-native'}
links = {}
backend_sources = set()
while pending:
    source = pending.pop()
    refs = []
    for dependency in dependencies(source):
        if is_system(dependency):
            continue
        resolved = resolve(dependency, source)
        # A dylib lists its own install name in otool -L.
        if resolved == source:
            continue
        destination = frameworks / resolved.name
        if resolved not in mapping:
            if destination in mapping.values():
                raise RuntimeError(f'Duplicate library name: {resolved.name}')
            mapping[resolved] = destination
            pending.append(resolved)
        refs.append((dependency, resolved))
        if resolved.name.startswith('libggml'):
            backend_dir = resolved.parent.parent / 'libexec'
            for backend in backend_dir.glob('libggml-*.so'):
                backend = backend.resolve()
                if backend not in mapping:
                    mapping[backend] = frameworks / backend.name
                    pending.append(backend)
                    backend_sources.add(backend)
    links[source] = refs

for source, destination in mapping.items():
    shutil.copy2(source, destination)
    destination.chmod(0o755)
    # Homebrew hardcodes a default plugin search directory in libggml. Disable
    # that directory so this app loads its own adjacent signed backends even
    # when a different Homebrew ggml happens to be installed on the machine.
    data = destination.read_bytes()
    pattern = rb'/(?:opt/homebrew|usr/local)/Cellar/ggml/[^/\x00]+/libexec\x00'
    def disable_external(match):
        replacement = b'.'
        if len(replacement) >= len(match.group()):
            raise RuntimeError('Unsupported embedded backend directory length')
        return replacement + bytes(len(match.group()) - len(replacement))
    updated = re.sub(pattern, disable_external, data)
    if updated != data:
        destination.write_bytes(updated)
    for old, dependency in links.get(source, []):
        subprocess.run(['/usr/bin/install_name_tool', '-change', old, '@rpath/' + mapping[dependency].name, str(destination)], check=True)
    if source not in (engine, helper):
        subprocess.run(['/usr/bin/install_name_tool', '-id', '@rpath/' + destination.name, str(destination)], check=True)
    for old in rpaths(destination):
        subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', old, str(destination)], check=True)
    relative = '@loader_path/../../Frameworks' if source in (engine, helper) else '@loader_path'
    subprocess.run(['/usr/bin/install_name_tool', '-add_rpath', relative, str(destination)], check=True)

for backend in backend_sources:
    link = bin_dir / backend.name
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to('../../Frameworks/' + backend.name)

# GGML_BACKEND_PATH accepts one backend file, not a directory. Select our own
# signed Metal plugin explicitly; GGML still discovers its optimized CPU plugin
# beside the native executable, and falls back to CPU when Metal is unavailable.
launcher = bin_dir / 'whisper-cli'
launcher.write_text("""#!/bin/sh
JW_BIN_DIR=$(CDPATH= cd -P "$(/usr/bin/dirname "$0")" && pwd)
export GGML_BACKEND_PATH="$JW_BIN_DIR/../../Frameworks/libggml-metal.so"
exec "$JW_BIN_DIR/whisper-cli-native" "$@"
""")
launcher.chmod(0o755)
live_launcher = bin_dir / 'justwisper-live'
live_launcher.write_text(launcher.read_text().replace('whisper-cli-native', 'justwisper-live-native'))
live_launcher.chmod(0o755)

# Every native input must have its own publisher license and unambiguous
# Homebrew package/version provenance. Unknown layouts fail closed.
def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()

components = {}
for source in mapping:
    if source == helper:
        source_file = pathlib.Path(__file__).resolve().parent.parent / 'native/live-whisper.cpp'
        components[source] = {'source_package': 'Cortala', 'source_version': 'live-protocol-1',
                              'input_sha256': sha256(source_file), 'license_files': [], 'first_party': True}
        continue
    root = next((ancestor for ancestor in source.parents
                 if ancestor.parent.parent.name == 'Cellar'), None)
    if root is None:
        raise RuntimeError(f'Runtime input requires a versioned Homebrew package: {source.name}')
    package, version = root.parent.name, root.name
    if not all(re.fullmatch(r'[A-Za-z0-9_.+~-]+', value) for value in (package, version)):
        raise RuntimeError('Invalid publisher package metadata')
    publisher_files = [root / name for name in ('LICENSE', 'LICENSE.TXT', 'LICENSE.txt', 'COPYING')
                       if (root / name).is_file()]
    if not publisher_files:
        raise RuntimeError(f'Missing publisher license for {package} {version}: {source.name}')
    relative_files = []
    for notice in publisher_files + [root / name for name in ('AUTHORS', 'NOTICE', 'NOTICE.txt') if (root / name).is_file()]:
        destination = notices / f'{package}-{version}-{notice.name}.txt'
        shutil.copy2(notice, destination)
        relative_files.append(destination.relative_to(app).as_posix())
    components[source] = {'source_package': package, 'source_version': version,
                          'input_sha256': sha256(source), 'license_files': sorted(relative_files)}
(notices / 'README.txt').write_text(
    'This distribution includes whisper.cpp and GGML under their accompanying licenses.\n'
    'Dynamic library install names, search paths, and the Homebrew-specific plugin directory were adjusted for relocation.\n'
    'Model weights are not included. Download and verify them using the app.\n'
    'The bundled speech runtime payloads are ad hoc signed.\n'
)
for destination in mapping.values():
    unresolved = [value for value in dependencies(destination) if value.startswith('/') and not is_system(value)]
    if unresolved:
        raise RuntimeError(f'Non-relocatable dependencies in {destination}: {unresolved}')
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(destination)], check=True)
manifest_components = []
for source, destination in sorted(mapping.items(), key=lambda item: str(item[1])):
    entry = dict(components[source])
    entry.update(path=destination.relative_to(app).as_posix(), output_sha256=sha256(destination),
                 dependencies=dependencies(destination), rpaths=rpaths(destination))
    manifest_components.append(entry)
license_paths = {name for entry in manifest_components for name in entry['license_files']}
manifest = {'format_version': 1, 'components': manifest_components,
            'license_sha256': {name: sha256(app / name) for name in sorted(license_paths)}}
(app / 'Contents/Resources/runtime-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print(f'Bundled whisper-cli, resident live helper, {len(mapping) - 2} libraries/backends and publisher notices.')
