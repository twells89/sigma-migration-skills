#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path

FILE = Path(__file__).with_name('compare-report-pdfs.py')
spec = importlib.util.spec_from_file_location('compare_report_pdfs', FILE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PdfComparisonTests(unittest.TestCase):
    def test_normalize_extractable_text(self):
        self.assertEqual(module.normal(' A\n   B\tC '), 'a b c')

    def test_reject_empty_pdf(self):
        with self.assertRaises((FileNotFoundError, RuntimeError)):
            module.info('/nonexistent/cognos.pdf')

    def test_extract_number_tokens_and_blank_page(self):
        self.assertEqual(module.numeric_tokens('Revenue 1,200.50 20%'),
                         module.numeric_tokens('Revenue 1200.50 20%'))
        from PIL import Image
        self.assertEqual(module.ink_fraction(Image.new('RGB', (50, 50), 'white')), 0)


if __name__ == '__main__':
    unittest.main()
