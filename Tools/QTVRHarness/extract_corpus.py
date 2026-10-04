#!/usr/bin/env python3
# One-shot corpus extractor for the QTVR parser harness.
#
# Reads the July 1995 QuickTime VR demo CD image (Apple-copyrighted, so
# it must be supplied separately by the caller) and
# writes every movie into Research/QTVR/corpus/ (gitignored):
#
#   <name>.mov   - the data fork
#   <name>.moov  - the 'moov' resource, ONLY for unflattened movies
#                  (authoring-form files keep their atoms in the
#                  resource fork; chunk offsets index the data fork)
#
# The harness pairs the two automatically. Needs: pip install machfs
import argparse
import os
import re

OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'Research', 'QTVR', 'corpus')
HFS_START, HFS_BLOCKS = 3, 1288192   # from the image's Apple partition map

def safe(name):
    return re.sub(r'[^A-Za-z0-9._-]+', '_', name).strip('_')

def main():
    parser = argparse.ArgumentParser(description='Extract the July 1995 QTVR demo CD corpus.')
    parser.add_argument('cd_image', help='Path to the QuickTime VR 7-95 CD image')
    args = parser.parse_args()
    import machfs
    from macresources import parse_file

    with open(os.path.expanduser(args.cd_image), 'rb') as source:
        raw = source.read()
    os.makedirs(OUT, exist_ok=True)
    vol = machfs.Volume()
    vol.read(raw[HFS_START * 512:(HFS_START + HFS_BLOCKS) * 512])
    count = 0
    def walk(folder, path=''):
        nonlocal count
        for name, obj in folder.items():
            p = f'{path}/{name}'
            if isinstance(obj, machfs.Folder):
                walk(obj, p)
            elif obj.type == b'MooV':
                base = safe(p.strip('/').replace('/', '__'))
                open(os.path.join(OUT, base + '.mov'), 'wb').write(obj.data)
                if obj.rsrc:
                    for res in parse_file(obj.rsrc):
                        if res.type == b'moov':
                            open(os.path.join(OUT, base + '.moov'), 'wb').write(bytes(res.data))
                count += 1
    walk(vol)
    print(f'{count} movies -> {os.path.abspath(OUT)}')

if __name__ == '__main__':
    main()
