"""Structural invariants for the resource layout.

Behavioural coverage lives in tests/lua (run with `lua5.4 tests/lua/run.lua`).
These tests check the things a Lua harness cannot see: that the manifest
actually loads every file on disk, that adapters come in matched pairs, and
that config keys referenced in code exist.
"""

import fnmatch
import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = (ROOT / "fxmanifest.lua").read_text()

SECTION = re.compile(r"(\w+)\s*\{([^}]*)\}", re.MULTILINE)
ENTRY = re.compile(r"'([^']+)'")


def manifest_sections():
    return {name: ENTRY.findall(body) for name, body in SECTION.findall(MANIFEST)}


def resource_lua_files():
    return {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.lua")
        if not path.relative_to(ROOT).as_posix().startswith(("tests/", "."))
        and path.name != "fxmanifest.lua"
    }


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.sections = manifest_sections()

    def test_every_lua_file_is_loaded_by_the_manifest(self):
        patterns = [
            entry
            for name in ("shared_scripts", "client_scripts", "server_scripts")
            for entry in self.sections.get(name, [])
        ]
        for path in sorted(resource_lua_files()):
            self.assertTrue(
                any(fnmatch.fnmatch(path, pattern) for pattern in patterns),
                f"{path} exists but no manifest entry loads it",
            )

    def test_manifest_entries_all_resolve_to_files(self):
        for name in ("shared_scripts", "client_scripts", "server_scripts", "files"):
            for entry in self.sections.get(name, []):
                matches = list(ROOT.glob(entry))
                self.assertTrue(matches, f"{name} entry '{entry}' matches nothing on disk")

    def test_client_and_server_code_are_not_cross_loaded(self):
        for entry in self.sections.get("client_scripts", []):
            self.assertNotIn("/server", entry, f"client_scripts loads server code: {entry}")
        for entry in self.sections.get("server_scripts", []):
            self.assertNotIn("/client", entry, f"server_scripts loads client code: {entry}")

    def test_bridge_loads_before_modules_and_entrypoints(self):
        for section, bridge, entrypoint in (
            ("client_scripts", "bridge/client.lua", "client/main.lua"),
            ("server_scripts", "bridge/server.lua", "server/main.lua"),
        ):
            entries = self.sections[section]
            self.assertLess(entries.index(bridge), entries.index(entrypoint))
            self.assertEqual(entries[-1], entrypoint, f"{section} must end with {entrypoint}")

    def test_adapters_load_after_the_dispatcher_that_registers_them(self):
        for section, dispatcher, glob in (
            ("client_scripts", "bridge/client.lua", "bridge/client/*.lua"),
            ("server_scripts", "bridge/server.lua", "bridge/server/*.lua"),
        ):
            entries = self.sections[section]
            self.assertLess(entries.index(dispatcher), entries.index(glob))

    def test_storage_seed_is_a_json_object(self):
        with (ROOT / "data/storage.json").open() as handle:
            self.assertIsInstance(json.load(handle), dict)

    def test_the_storage_file_is_not_exposed_to_clients(self):
        """`files{}` entries are downloaded by every connecting client. The
        store is server-owned and LoadResourceFile does not need the
        declaration, so it must never be listed there."""
        for entry in self.sections.get("files", []):
            self.assertFalse(
                fnmatch.fnmatch("data/storage.json", entry),
                f"files entry '{entry}' would ship the server-side store to clients",
            )


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.client = {path.stem for path in (ROOT / "bridge/client").glob("*.lua")}
        self.server = {path.stem for path in (ROOT / "bridge/server").glob("*.lua")}
        self.shared = (ROOT / "bridge/shared.lua").read_text()
        self.config = (ROOT / "config.lua").read_text()

    def test_every_framework_has_a_client_and_server_adapter(self):
        self.assertEqual(self.client, self.server)

    def test_every_adapter_is_a_known_framework(self):
        block = self.shared[self.shared.index("Bridge.resourceNames = {"):]
        known = set(re.findall(r"^\s{4}(\w+)\s*=", block[: block.index("\n}")], re.MULTILINE))
        self.assertEqual(self.server, known, "adapter files and Bridge.resourceNames disagree")

    def test_every_framework_appears_in_the_detection_priority(self):
        priority = self.config[self.config.index("Config.FrameworkPriority"):]
        priority = set(ENTRY.findall(priority[: priority.index("\n")]))
        self.assertEqual(priority, self.server, "a framework with an adapter is never auto-detected")

    def test_adapters_register_under_their_own_filename(self):
        for name in sorted(self.server):
            for side in ("client", "server"):
                source = (ROOT / f"bridge/{side}/{name}.lua").read_text()
                self.assertIn(
                    f"RegisterAdapter('{name}'",
                    source,
                    f"bridge/{side}/{name}.lua does not register the '{name}' adapter",
                )


class ConventionTests(unittest.TestCase):
    def source_files(self):
        return {path: path.read_text() for path in ROOT.rglob("*.lua") if "tests" not in path.parts}

    def test_config_keys_used_in_code_are_defined(self):
        config = (ROOT / "config.lua").read_text()
        defined = set(re.findall(r"^Config\.(\w+)", config, re.MULTILINE))
        defined |= set(re.findall(r"^\s{4}(\w+)\s*=", config, re.MULTILINE))

        for path, source in self.source_files().items():
            if path.name == "config.lua":
                continue
            for key in re.findall(r"Config\.(\w+)", source):
                self.assertIn(key, defined, f"{path.name} reads undefined Config.{key}")

    def test_internal_events_are_namespaced_through_bridge_event(self):
        """Events this resource owns must be namespaced so two resources built
        from this template can run side by side. Adapter files are exempt:
        subscribing to a framework's own lifecycle events is their job."""
        for path, source in self.source_files().items():
            if path.parent.name in ("client", "server") and path.parents[1].name == "bridge":
                continue
            for event in re.findall(r"(?:RegisterNetEvent|TriggerClientEvent)\(\s*'([^']+)'", source):
                self.assertTrue(
                    event.startswith("chat:"),
                    f"{path.name} uses a hard-coded net event '{event}'; use Bridge.Event()",
                )

    def test_commands_are_not_registered_under_hard_coded_global_names(self):
        """Command names are a global namespace. Two resources built from this
        template must not fight over the same one, so every name is derived
        from the resource name or read from config."""
        for path, source in self.source_files().items():
            for name in re.findall(r"RegisterCommand\(\s*'([^']+)'", source):
                self.fail(f"{path.name} registers the global command '{name}'")

    def test_logging_goes_through_the_bridge_helper(self):
        for path, source in self.source_files().items():
            if path.name == "shared.lua":
                continue
            stripped = re.sub(r"--[^\n]*", "", source)
            self.assertNotRegex(
                stripped,
                r"(?<![.\w])print\s*\(",
                f"{path.name} calls print() directly; use Bridge.Print/Bridge.Debug",
            )


if __name__ == "__main__":
    unittest.main()
