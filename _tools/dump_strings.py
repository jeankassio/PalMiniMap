import sys, string

PRINTABLE = set(string.printable.encode()) - set(b'\t\n\r\x0b\x0c')

def scan(path):
    data = open(path, 'rb').read()
    results = []
    i = 0
    n = len(data)
    while i < n - 5:
        ln = int.from_bytes(data[i:i+4], 'little', signed=True)
        if 2 <= ln <= 512 and i + 4 + ln <= n:
            chunk = data[i+4:i+4+ln]
            if chunk[-1] == 0 and all(c in PRINTABLE for c in chunk[:-1]):
                s = chunk[:-1].decode('ascii', 'replace')
                results.append((i, s))
                i += 4 + ln
                continue
        i += 1
    return results

if __name__ == '__main__':
    for path in sys.argv[1:]:
        print(f'===== {path} =====')
        for off, s in scan(path):
            print(f'{off:08x}  {s}')
