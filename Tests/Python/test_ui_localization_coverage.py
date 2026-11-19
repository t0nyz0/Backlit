import importlib.util,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('ui_coverage',ROOT/'scripts/check-ui-localizations.py')
checker=importlib.util.module_from_spec(spec);spec.loader.exec_module(checker)
class UIMessageCoverageTests(unittest.TestCase):
 def test_actual_status_and_error_sources_have_catalog_coverage(self):
  self.assertGreater(checker.check(),10)
 def test_new_readable_status_cannot_silently_fallback(self):
  self.assertEqual(checker.missing_from('status = "A new readable status."','TypingInput',{},{}),['A new readable status.'])
 def test_comments_machine_ids_and_opaque_interpolation_are_not_prose(self):
  text='// "Comment only"\nlet id="local.backlit"; let detail="Failure: \\(error)"'
  self.assertEqual(list(checker.readable_literals(text)),[])
 def test_exclusion_is_exact_and_scoped_not_all_errors(self):
  ex={'Invalid request':{'files':['HomeBridge'],'reason':'Protocol response'}}
  self.assertEqual(checker.missing_from('"Invalid request"','HomeBridge',{},ex),[])
  self.assertEqual(checker.missing_from('"Invalid request"','TypingInput',{},ex),['Invalid request'])
  self.assertEqual(checker.missing_from('"New readable error"','HomeBridge',{},ex),['New readable error'])
