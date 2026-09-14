import json
import unittest
from unittest.mock import patch
from scripts.normalize import allowed_ipsw_url, classify
from scripts.organize import all_index, normalize_candidates, merge, index
from scripts.sources import apple, ipswbeta, tss
from scripts.sources.ipswbeta import FILENAME, tracks_for_os
from scripts.sources.beta import url_for_device
from scripts.generate_site import beta_release_order, display_version

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
    def test_beta_pages_follow_release_sequence(self):
        releases=[
            {"version":"27.0", "data":"27.0-rc/24A435.json", "build":"24A435"},
            {"version":"27.0", "data":"27.0-beta-2/24A5370H.json", "build":"24A5370H"},
            {"version":"27.0", "data":"27.0-beta/24A5355Q.json", "build":"24A5355Q"},
        ]
        self.assertEqual([release["data"] for release in sorted(releases, key=beta_release_order)], ["27.0-beta/24A5355Q.json", "27.0-beta-2/24A5370H.json", "27.0-rc/24A435.json"])

class AppleCatalogTests(unittest.TestCase):

    CATALOG = {"iPodSoftwareVersions": {"12": {"FirmwareURL": "https://updates.cdn-apple.com/a.ipsw", "ProductVersion": "1.2", "BuildVersion": "36B10147"}},
               "MobileDeviceSoftwareVersionsByVersion": {"1": {"MobileDeviceSoftwareVersions": {
                   "iPhone18,5": {"23G90": {"Restore": {"FirmwareURL": "https://updates.cdn-apple.com/b.ipsw", "ProductVersion": "26.6.2", "BuildVersion": "23G90", "FirmwareSHA1": "A" * 40}}},
                   "AppleTV5,3": {"23L773": {"Restore": {"FirmwareURL": "https://updates.cdn-apple.com/c.ipsw", "ProductVersion": "26.6", "BuildVersion": "23L773"}}}}}}}
    def rows(self):
        with patch.object(apple, "get_plist", return_value=self.CATALOG): return apple.fetch(1)
    def test_container_key_is_not_a_device(self):
        self.assertNotIn("iPodSoftwareVersions", {row["device"] for row in self.rows()})
    def test_reads_device_build_and_url(self):
        row = next(r for r in self.rows() if r["device"] == "iPhone18,5")
        self.assertEqual((row["version"], row["build"], row["url"]), ("26.6.2", "23G90", "https://updates.cdn-apple.com/b.ipsw"))
        self.assertEqual(row["sha1"], "a" * 40)
    def test_listed_builds_count_as_signed(self):
        self.assertTrue(all(row["signed"] for row in self.rows()))
    def test_leaves_the_marketing_name_to_another_source(self):
        self.assertIsNone(next(iter(self.rows()))["name"])

class ReleaseDateTests(unittest.TestCase):
    FEED = """<rss><channel>
      <item><title>iOS 27.0 (24A437)</title><pubDate>Mon, 14 Sep 2026 10:00:00 PDT</pubDate></item>
      <item><title>iOS 27.0 RC (24A437)</title><pubDate>Fri, 11 Sep 2026 10:00:00 PDT</pubDate></item>
      <item><title>iPadOS 26.6.2 (23G90)</title><pubDate>Tue, 08 Sep 2026 10:00:00 PDT</pubDate></item>
      <item><title>App Store Connect Update</title><pubDate>Tue, 08 Sep 2026 10:00:00 PDT</pubDate></item>
    </channel></rss>"""
    def dates(self):
        class Response:
            def read(inner): return ReleaseDateTests.FEED.encode()
            def __enter__(inner): return inner
            def __exit__(inner, *args): return False
        with patch.object(apple, "urlopen", return_value=Response()): return apple.release_dates(1)
    def test_reads_the_announced_time_in_utc(self):
        self.assertEqual(self.dates()[("27.0", "24A437")], "2026-09-14T17:00:00Z")
    def test_release_day_wins_over_the_earlier_rc(self):
        # The RC carries the same build; a release record is dated by release.
        self.assertNotEqual(self.dates()[("27.0", "24A437")], "2026-09-11T17:00:00Z")
    def test_ignores_items_that_name_no_build(self):
        self.assertEqual(len(self.dates()), 2)

class SigningProbeTests(unittest.TestCase):
    MANIFEST = {"BuildIdentities": [{"ApBoardID": "0x04", "ApChipID": "0x8030", "ApSecurityDomain": "0x01",
                                     "UniqueBuildID": b"\x01\x02", "Manifest": {"iBSS": {"Digest": b"\x03", "Info": {"IsFirmwarePayload": True}},
                                                                                "Skipped": {"Digest": b"\x04", "Info": {}}}}]}
    def answer(self, text):
        class Response:
            def read(self): return text.encode()
            def __enter__(self): return self
            def __exit__(self, *args): return False
        with patch.object(tss, "build_manifest", return_value=self.MANIFEST), patch.object(tss, "urlopen", return_value=Response()):
            return tss.signing_status("https://updates.cdn-apple.com/b.ipsw", 1)
    def test_ticket_means_signed(self): self.assertIs(self.answer("STATUS=0&MESSAGE=SUCCESS"), True)
    def test_incomplete_request_still_means_signed(self):
        # Recent silicon answers 69; Apple refuses an unsigned build before that.
        self.assertIs(self.answer("STATUS=69&MESSAGE=This device isn't eligible for the requested build."), True)
    def test_refusal_means_unsigned(self): self.assertIs(self.answer("STATUS=94&MESSAGE=This device isn't eligible for the requested build."), False)
    def test_unknown_status_changes_nothing(self): self.assertIsNone(self.answer("STATUS=8&MESSAGE=An internal error occurred."))
    def test_request_carries_only_firmware_components(self):
        body = tss._request_body(self.MANIFEST["BuildIdentities"][0])
        self.assertIn("iBSS", body)
        self.assertNotIn("Skipped", body)
        self.assertNotIn("Info", body["iBSS"])
    def answers(self, *texts):
        replies=list(texts)
        class Response:
            def __init__(self, text): self.text=text
            def read(self): return self.text.encode()
            def __enter__(self): return self
            def __exit__(self, *args): return False
        with patch.object(tss, "build_manifest", return_value=self.MANIFEST), \
             patch.object(tss, "urlopen", side_effect=lambda *a, **k: Response(replies.pop(0))):
            return tss.signing_status("https://updates.cdn-apple.com/b.ipsw", 1)
    def test_retries_with_the_shorter_nonce_older_silicon_wants(self):
        # A8-era hardware answers 128 to a 32-byte nonce and a verdict to 20.
        self.assertIs(self.answers("STATUS=128&MESSAGE=An internal error occurred.", "STATUS=0&MESSAGE=SUCCESS"), True)
    def test_shorter_nonce_can_also_report_unsigned(self):
        self.assertIs(self.answers("STATUS=128&MESSAGE=An internal error occurred.", "STATUS=94&MESSAGE=no"), False)
    def test_gives_up_when_neither_nonce_is_answered(self):
        self.assertIsNone(self.answers("STATUS=128&MESSAGE=x", "STATUS=8&MESSAGE=y"))
    def test_nonce_length_follows_the_request(self):
        self.assertEqual(len(tss._request_body(self.MANIFEST["BuildIdentities"][0], 20)["ApNonce"]), 20)
        self.assertEqual(len(tss._request_body(self.MANIFEST["BuildIdentities"][0])["ApNonce"]), 32)
    def test_zip64_extra_field_overrides_placeholders(self):
        import struct
        extra = struct.pack("<HH3Q", 0x0001, 24, 9_000_000_000, 8_000_000_000, 5_000_000_000)
        self.assertEqual(tss._zip64_values(extra, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF), (9_000_000_000, 8_000_000_000, 5_000_000_000))
