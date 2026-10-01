#!/usr/bin/env python3
"""Page-by-page Cognos PDF ↔ Sigma Report PDF comparison.

Uses Poppler (pdfinfo, pdftotext, pdftoppm) plus Pillow. A green result still
requires a human check of fonts and pagination against a genuine source PDF.
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from difflib import SequenceMatcher
from io import BytesIO

from PIL import Image, ImageChops, ImageStat


def command(*args):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if p.returncode:
        raise RuntimeError(f"{args[0]} failed: {p.stderr.decode(errors='replace')[:300]}")
    return p.stdout


def info(path):
    raw = command('pdfinfo', path).decode(errors='replace')
    pages = re.search(r'^Pages:\s*(\d+)\s*$', raw, re.M)
    size = re.search(r'^Page size:\s*([\d.]+) x ([\d.]+) pts', raw, re.M)
    if not pages or not size:
        raise ValueError(f'{path}: could not read page count or page size')
    return int(pages[1]), (float(size[1]), float(size[2]))


def page(path, number):
    # stdout single-page PNG: no temp files or potentially sensitive caches.
    return Image.open(BytesIO(command('pdftoppm', '-f', str(number), '-l', str(number),
                                      '-scale-to', '1100', '-singlefile', '-png', path)))


def text(path, number):
    return command('pdftotext', '-f', str(number), '-l', str(number), '-layout', path, '-').decode(errors='replace')


def normal(s):
    return re.sub(r'\s+', ' ', s).strip().lower()


def numeric_tokens(s):
    return Counter(token.replace(',', '') for token in
                   re.findall(r'(?<!\w)-?\d[\d,]*(?:\.\d+)?%?(?!\w)', s))


def ink_fraction(image):
    # Image-only PDFs can be usable, but a blank page is never an oracle.
    histogram = image.convert('L').histogram()
    return sum(histogram[:240]) / (image.width * image.height)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--cognos', required=True, help='rendered source Cognos PDF')
    ap.add_argument('--sigma', required=True, help='exported Sigma Report PDF')
    ap.add_argument('--out', help='JSON verdict output path')
    ap.add_argument('--max-mean-diff', type=float, default=0.08,
                    help='maximum mean pixel diff after sizing pages equally (default: 0.08)')
    ap.add_argument('--min-text-ratio', type=float, default=0.95,
                    help='minimum normalized text similarity (default: 0.95)')
    a = ap.parse_args()
    if not 0 <= a.max_mean_diff <= 1 or not 0 <= a.min_text_ratio <= 1:
        raise ValueError('comparison thresholds must be in [0, 1]')
    n_source, size_source = info(a.cognos)
    n_target, size_target = info(a.sigma)
    pages = []
    for number in range(1, min(n_source, n_target) + 1):
        raw_source_text = text(a.cognos, number)
        raw_target_text = text(a.sigma, number)
        source_text = normal(raw_source_text)
        target_text = normal(raw_target_text)
        source = page(a.cognos, number).convert('RGB')
        target = page(a.sigma, number).convert('RGB').resize(source.size)
        diff = ImageChops.difference(source, target).convert('L')
        mean = ImageStat.Stat(diff).mean[0] / 255.0
        source_ink = ink_fraction(source)
        target_ink = ink_fraction(target)
        blank = source_ink < 0.001 or target_ink < 0.001
        text_ratio = SequenceMatcher(None, source_text, target_text, autojunk=False).ratio() if source_text else None
        numbers_match = numeric_tokens(raw_source_text) == numeric_tokens(raw_target_text) if source_text else True
        pages.append({'page': number, 'mean_pixel_diff': round(mean, 4),
                      'source_text_chars': len(source_text), 'sigma_text_chars': len(target_text),
                      'source_ink_fraction': round(source_ink, 4), 'sigma_ink_fraction': round(target_ink, 4),
                      'text_similarity': round(text_ratio, 4) if text_ratio is not None else None,
                      'numbers_match': numbers_match,
                      'passed': not blank and mean <= a.max_mean_diff and numbers_match
                      and (text_ratio is None or text_ratio >= a.min_text_ratio)})
    verdict = {'passed': bool(pages) and n_source == n_target
               and all(abs(x - y) / x <= 0.02 for x, y in zip(size_source, size_target))
               and all(p['passed'] for p in pages),
               'cognos_pages': n_source, 'sigma_pages': n_target,
               'cognos_size_pts': size_source, 'sigma_size_pts': size_target,
               'pages': pages}
    if a.out:
        with open(a.out, 'w', encoding='utf-8') as f:
            json.dump(verdict, f, indent=2)
    print(json.dumps(verdict, indent=2))
    return 0 if verdict['passed'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, ValueError, FileNotFoundError) as error:
        sys.exit(f'PDF comparison unavailable: {error}')
