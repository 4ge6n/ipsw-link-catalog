import json
import unittest
from scripts.normalize import allowed_ipsw_url, classify
from scripts.organize import all_index, normalize_candidates, merge, index
from scripts.sources.ipswbeta import FILENAME

SETTINGS={"allowed_cdn_hosts":["updates.cdn-apple.com"], "include_unknown_beta_signing":True}
class CatalogTests(unittest.TestCase):
    def test_rc_is_beta(self): self.assertEqual(classify("27.0 RC")[0:2], ("beta", "27.0-rc"))
    def test_rejects_unknown_host(self): self.assertFalse(allowed_ipsw_url("https://example.com/a.ipsw", {"updates.cdn-apple.com"}))
    def test_release_latest_excludes_unsigned(self):
        with open("tests/fixtures/candidates.json") as fixture: rows=json.load(fixture)
        observed,_=normalize_candidates(rows, SETTINGS, "2026-09-12T00:00:00Z")
        records=merge([], observed, "2026-09-12T00:00:00Z"); latest=index(records,"ipados","release","2026-09-12T00:00:00Z",True)
        self.assertEqual(latest["firmware_count"], 0)
    def test_release_latest_keeps_only_newest_signed_build_per_device(self):
        rows=[
            {"device":"iPhone12,1","name":"iPhone 11","version":"26.6.1","build":"23G83","url":"https://updates.cdn-apple.com/a.ipsw","signed":True},
            {"device":"iPhone12,1","name":"iPhone 11","version":"26.6.2","build":"23G90","url":"https://updates.cdn-apple.com/b.ipsw","signed":True},
        ]
        observed,_=normalize_candidates(rows, SETTINGS, "2026-09-12T00:00:00Z")
        latest=index(merge([], observed, "2026-09-12T00:00:00Z"), "ios", "release", "2026-09-12T00:00:00Z", True)
        self.assertEqual([release["version"] for release in latest["releases"]], ["26.6.2"])
    def test_ipswbeta_filename_extracts_version_and_build(self):
        found=FILENAME.search("https://updates.cdn-apple.com/path/iPhone18,5_27.0_24A435_Restore.ipsw")
        self.assertEqual(found.groups(), ("27.0", "24A435"))
    def test_beta_all_index_keeps_beta_and_rc(self):
        rows=[
            {"device":"iPhone12,1","name":"iPhone 11","version":"27.0 beta 1","build":"24A1","url":"https://updates.cdn-apple.com/beta.ipsw","signed":None,"channel":"beta"},
            {"device":"iPhone12,1","name":"iPhone 11","version":"27.0 RC","build":"24A2","url":"https://updates.cdn-apple.com/rc.ipsw","signed":None,"channel":"beta"},
        ]
        observed,_=normalize_candidates(rows, SETTINGS, "2026-09-12T00:00:00Z")
        document=all_index(merge([], observed, "2026-09-12T00:00:00Z"), "ios", "beta", "2026-09-12T00:00:00Z")
        self.assertEqual({release["build"] for release in document["releases"]}, {"24A1", "24A2"})
