import importlib.util
import sys
import tempfile
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

    def test_disc_folder_is_preserved(self) -> None:
        decision = music_manage.target_for_path(
            Path("Metallica - Discography/2008 - Death Magnetic/Disc 2/01. That Was Just Your Life.flac"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(
            decision.target,
            Path("Metallica/Death Magnetic (2008)/Disc 02/01 - That Was Just Your Life.flac"),
        )

    def test_bracket_year_album_pattern(self) -> None:
        decision = music_manage.target_for_path(
            Path("Iron Maiden - Discography/[1995] The X Factor [2 CD]/01. Sign Of The Cross.mp3"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(
            decision.target,
            Path("Iron Maiden/The X Factor (1995)/01 - Sign Of The Cross.mp3"),
        )

    def test_recordings_are_left_untouched(self) -> None:
        decision = music_manage.target_for_path(Path("recordings/session.wav"), include_podcasts=False)

        self.assertIsInstance(decision, music_manage.Skip)
        self.assertEqual(decision.reason, "recordings intentionally left untouched")

    def test_podcasts_skipped_by_default(self) -> None:
        decision = music_manage.target_for_path(
            Path("Podcasts Weekly/Episode 01.mp3"),
            include_podcasts=False,
        )

        self.assertIsInstance(decision, music_manage.Skip)

    def test_lofi_girl_maps_to_various_artists(self) -> None:
        decision = music_manage.target_for_path(Path("lofi-girl/chill hop.mp3"), include_podcasts=False)

        self.assertIsInstance(decision, music_manage.Destination)
        self.assertEqual(decision.target, Path("Various Artists/Lofi Girl/chill hop.mp3"))

    def test_exact_duplicate_is_marked_for_delete(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "a.mp3"
            second = root / "b.mp3"
            payload = b"same-bytes"
            first.write_bytes(payload)
            second.write_bytes(payload)

            destinations = [
                music_manage.Destination(Path("a.mp3"), Path("Artist/Album/01 - Track.mp3"), "audio"),
                music_manage.Destination(Path("b.mp3"), Path("Artist/Album/01 - Track.mp3"), "audio"),
            ]
            unique, deletes, warnings = music_manage.uniquify_destinations(destinations, root)

            self.assertEqual(len(unique), 1)
            self.assertEqual(unique[0].source, Path("a.mp3"))
            self.assertEqual(len(deletes), 1)
            self.assertEqual(deletes[0].source, Path("b.mp3"))
            self.assertTrue(any("exact duplicate" in warning for warning in warnings))

    def test_non_identical_collision_is_renamed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first = root / "a.mp3"
            second = root / "b.mp3"
            first.write_bytes(b"one")
            second.write_bytes(b"two")

            destinations = [
                music_manage.Destination(Path("a.mp3"), Path("Artist/Album/01 - Track.mp3"), "audio"),
                music_manage.Destination(Path("b.mp3"), Path("Artist/Album/01 - Track.mp3"), "audio"),
            ]
            unique, deletes, warnings = music_manage.uniquify_destinations(destinations, root)

            self.assertEqual(len(deletes), 0)
            self.assertEqual(len(unique), 2)
            targets = {item.target for item in unique}
            self.assertIn(Path("Artist/Album/01 - Track.mp3"), targets)
            self.assertIn(Path("Artist/Album/01 - Track_2.mp3"), targets)
            self.assertTrue(any(warning.startswith("collision:") for warning in warnings))

    def test_apply_moves_without_deleting_duplicates_unless_flagged(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "src"
            dest = root / "dst"
            source.mkdir()
            dest.mkdir()
            keep = source / "keep.mp3"
            dup = source / "dup.mp3"
            keep.write_bytes(b"same")
            dup.write_bytes(b"same")

            destinations = [
                music_manage.Destination(Path("keep.mp3"), Path("Artist/Album/01 - Track.mp3"), "audio"),
            ]
            deletes = [music_manage.Delete(Path("dup.mp3"), "exact duplicate of keep.mp3")]

            moved, unchanged, deleted = music_manage.apply_plan(
                source, dest, destinations, deletes, overwrite=False, delete_duplicates=False
            )
            self.assertEqual(moved, 1)
            self.assertEqual(deleted, 0)
            self.assertTrue((dest / "Artist/Album/01 - Track.mp3").is_file())
            self.assertTrue(dup.is_file())

            moved, unchanged, deleted = music_manage.apply_plan(
                source, dest, [], deletes, overwrite=False, delete_duplicates=True
            )
            self.assertEqual(deleted, 1)
            self.assertFalse(dup.exists())

    def test_delete_duplicates_requires_apply(self) -> None:
        with self.assertRaises(SystemExit):
            music_manage.main(["--delete-duplicates"])


if __name__ == "__main__":
    unittest.main()
