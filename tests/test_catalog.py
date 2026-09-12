import json
import unittest
from unittest.mock import patch
from scripts.normalize import allowed_ipsw_url, classify
from scripts.organize import all_index, normalize_candidates, merge, index
from scripts.sources import ipswbeta
from scripts.sources.ipswbeta import FILENAME, tracks_for_os
from scripts.sources.beta import url_for_device
from scripts.generate_site import display_version

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
    def test_beta_primary_uses_numeric_version(self):
        from unittest.mock import patch
        with patch("scripts.sources.beta.get_text", return_value='ipsw-button-down href="https://updates.cdn-apple.com/a.ipsw"'):
            row=url_for_device(("24A435", "iOS 27.0 RC", "iPhone18,5", "iPhone"), 1)
        self.assertEqual((row["version"], row["label"]), ("27.0", "27.0 RC"))
    def test_beta_tracks_include_historical_versions(self):
        from unittest.mock import patch
        page=' '.join(f'href="/ipados/{major}.x/"' for major in (10, 27, 18, 10))
        with patch("scripts.sources.ipswbeta.get_text", return_value=page):
            self.assertEqual(tracks_for_os("ipados", 1), ["27.x", "18.x", "10.x"])
    def test_beta_all_index_deduplicates_reused_apple_url(self):
        rows=[
            {"device":"iPad13,1","name":"iPad","version":"27.0 beta 1","build":"24A1","url":"https://updates.cdn-apple.com/shared.ipsw","signed":None,"channel":"beta"},
            {"device":"iPad13,1","name":"iPad","version":"27.0 beta 2","build":"24A2","url":"https://updates.cdn-apple.com/shared.ipsw","signed":None,"channel":"beta"},
        ]
        observed,_=normalize_candidates(rows, SETTINGS, "2026-09-12T00:00:00Z")
        document=all_index(merge([], observed, "2026-09-12T00:00:00Z"), "ipados", "beta", "2026-09-12T00:00:00Z")
        self.assertEqual(sum(len(release["firmwares"]) for release in document["releases"]), 1)
    def test_ipswbeta_normal_updates_only_current_tracks(self):
        with patch.dict("os.environ", {"BETA_HISTORY": "0"}, clear=False), \
             patch.object(ipswbeta, "current_tracks", return_value={"ios": "27.x"}), \
             patch.object(ipswbeta, "tracks_for_os") as history, \
             patch.object(ipswbeta, "devices_for_track", return_value=[]):
            self.assertEqual(ipswbeta.fetch(1, {"ios"}), [])
        history.assert_not_called()
    def test_historical_ios_ipad_candidate_keeps_ios_track(self):
        with patch("scripts.sources.ipswbeta.get_text", return_value='<div class="font-bold">10.1 beta</div> data-url="https://updates.cdn-apple.com/iPad3,4_10.1_14B1_Restore.ipsw"'):
            row=ipswbeta.candidates_for_device(("ios", "10.x", "iPad3,4"), 1)[0]
        self.assertEqual(row["os_key"], "ios")
    def test_beta_labels_are_human_readable_on_pages(self):
        self.assertEqual(display_version({"version":"27.0", "data":"27.0-beta-2/24A.json"}), "27.0 Beta 2")
        self.assertEqual(display_version({"version":"27.0", "data":"27.0-rc/24A.json"}), "27.0 RC")
