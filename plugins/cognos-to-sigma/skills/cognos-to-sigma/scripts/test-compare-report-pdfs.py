#!/usr/bin/env python3
import importlib.util
import unittest
from unittest.mock import patch
from contextlib import redirect_stdout
from io import StringIO
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

    def test_per_page_geometry_parse(self):
        with patch.object(module, 'command', return_value=b'Page    2 size: 792 x 612 pts (letter)\n'):
            self.assertEqual(module.page_size('synthetic.pdf', 2), (792, 612))

    def test_later_page_geometry_and_self_comparison_cannot_pass(self):
        from PIL import Image
        for identical, wrong_later_size in [(True, False), (False, True), (False, False)]:
            sizes = [(612, 792), (612, 792), (612, 792), (792, 612) if wrong_later_size else (612, 792)]
            with patch('sys.argv', ['compare', '--cognos', 'a.pdf', '--sigma', 'b.pdf']), \
                 patch.object(module, 'digest', side_effect=['a', 'a' if identical else 'b']), \
                 patch.object(module, 'info', return_value=(2, (612, 792))), \
                 patch.object(module, 'page_size', side_effect=sizes), \
                 patch.object(module, 'page', return_value=Image.new('RGB', (20, 20), 'black')), \
                 patch.object(module, 'text', return_value='Value 12'), redirect_stdout(StringIO()):
                self.assertEqual(module.main(), 1 if identical or wrong_later_size else 0)


if __name__ == '__main__':
    unittest.main()
