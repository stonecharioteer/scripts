import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "homelab" / "jellyfin" / "music_manage.py"
SPEC = importlib.util.spec_from_file_location("music_manage", MODULE_PATH)
assert SPEC is not None
music_manage = importlib.util.module_from_spec(SPEC)
sys.modules["music_manage"] = music_manage
assert SPEC.loader is not None
SPEC.loader.exec_module(music_manage)


class MusicManageTests(unittest.TestCase):
    def test_compilation_folder_moves_under_various_artists(self) -> None:
        decision = music_manage.target_for_path(
            Path("70s Rock Essentials (2021) Mp3 320kbps [PMEDIA]/001. Eagles - Hotel California.mp3"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(
            decision.target,
            Path("Various Artists/70s Rock Essentials (2021)/01 - Eagles - Hotel California.mp3"),
        )

    def test_compilation_cover_art_becomes_folder_image(self) -> None:
        decision = music_manage.target_for_path(
            Path("80s Rock Essentials (2021) Mp3 320kbps [PMEDIA]/cover.jpg"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(decision.target, Path("Various Artists/80s Rock Essentials (2021)/folder.jpg"))

    def test_toc_sidecar_is_skipped_as_junk(self) -> None:
        decision = music_manage.target_for_path(
            Path("Van Halen/1988 - Feels So Good/Van Halen - Feels So Good.toc"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Skip)
        self.assertEqual(decision.reason, "non-library sidecar/junk file")

    def test_unknown_unsupported_file_reports_extension(self) -> None:
        decision = music_manage.target_for_path(Path("music_manage.py"), include_podcasts=False)

        self.assertIsInstance(decision, music_manage.Skip)
        self.assertEqual(decision.reason, "unsupported extension: .py")

    def test_artist_root_image_moves_to_artist_artwork(self) -> None:
        decision = music_manage.target_for_path(
            Path("Van Halen - Discography 1978-2015 [FLAC] 88/Jolly Roger.png"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(decision.target, Path("Van Halen/Artwork/Jolly Roger.png"))
        self.assertEqual(decision.reason, "artist artwork")

    def test_non_artist_two_part_image_is_not_artist_artwork(self) -> None:
        decision = music_manage.target_for_path(Path("docs/gi-select.png"), include_podcasts=False)

        self.assertIsInstance(decision, music_manage.Skip)
        self.assertEqual(decision.reason, "could not infer artist/album or podcast skipped")


if __name__ == "__main__":
    unittest.main()
