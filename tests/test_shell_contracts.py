"""Windows上でシェル構文と、確認画面からハードウェア変更へ至らない境界を検査する。"""
import unittest
import sys
from pathlib import Path

from tree_sitter import Language, Parser
import tree_sitter_bash

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from pcinfo_build.payload import APPLICATION_FILES


def walk(node):
    yield node
    for child in node.children:
        yield from walk(child)


def command_name(node):
    name = node.child_by_field_name("name") if node.type == "command" else None
    return name.text.decode() if name is not None else None


def ancestor(node, kind):
    parent = node.parent
    while parent is not None and parent.type != kind:
        parent = parent.parent
    return parent


class ShellContractTests(unittest.TestCase):
    def setUp(self):
        self.parser = Parser(Language(tree_sitter_bash.language()))

    def parse(self, path):
        return self.parser.parse((ROOT / path).read_bytes()).root_node

    def sourced_paths(self, path, stack=()):
        self.assertNotIn(path, stack, f"Circular shell source: {path}")
        self.assertTrue((ROOT / path).is_file(), path)
        destinations = {"/" + target: name for name, (target, _) in APPLICATION_FILES.items()}
        for node in self.parse(path).named_children:
            if command_name(node) != ".":
                continue
            destination = node.named_children[1].text.decode()
            self.assertIn(destination, destinations, f"Source is not packaged: {destination}")
            yield from self.sourced_paths(destinations[destination], stack + (path,))
        yield path

    def functions_for(self, path):
        functions = {}
        for source in self.sourced_paths(path):
            for node in self.parse(source).named_children:
                if node.type == "function_definition":
                    functions[node.child_by_field_name("name").text.decode()] = node.child_by_field_name("body")
        return functions

    def test_sourced_libraries_are_present_in_the_packaged_layout(self):
        for path in APPLICATION_FILES:
            if path.endswith(".sh"):
                with self.subTest(path=path):
                    list(self.sourced_paths(path))

    def test_shell_sources_parse_without_errors(self):
        paths = list((ROOT / "src").rglob("*.sh")) + [ROOT / "tools/packaging/overlay/root/.profile"]
        for path in paths:
            with self.subTest(path=str(path.relative_to(ROOT))):
                root = self.parser.parse(path.read_bytes()).root_node
                errors = [(node.type, node.start_point) for node in walk(root)
                          if node.type == "ERROR" or node.is_missing]
                self.assertEqual(errors, [])

    def test_inspection_cannot_load_or_unload_drivers(self):
        functions = self.functions_for("src/menu_gpu.sh")
        pending, seen = ["show_driver_check"], set()
        mutations = {"modprobe", "insmod", "rmmod", "mount", "umount", "reboot", "poweroff"}
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            for node in walk(functions[name]):
                if node.type != "command":
                    continue
                command = node.child_by_field_name("name")
                if command is None:
                    continue
                target = command.text.decode()
                self.assertNotIn(target, mutations, f"Inspection reaches {target} via {name}")
                if target in functions:
                    pending.append(target)
        self.assertIn("show_gpus", seen)

    def test_pcinfo_snapshot_is_collected_before_rendering(self):
        nodes = list(walk(self.parse("src/pcinfo.sh")))
        captures = [node for node in nodes if command_name(node) == "collect_hardware_snapshot"]
        self.assertEqual(len(captures), 1)
        first_section = next(node for node in nodes if command_name(node) == "section")
        self.assertLess(captures[0].end_byte, first_section.start_byte)

    def test_cached_readers_are_read_only_and_do_not_rerun_hardware_commands(self):
        functions = self.functions_for("src/pcinfo.sh")
        for name in ("first_lscpu_value", "first_dmidecode_value"):
            with self.subTest(function=name):
                commands = {command_name(node) for node in walk(functions[name])}
                self.assertTrue(commands.isdisjoint({"lscpu", "dmidecode", "modprobe", "mount", "reboot"}))

    def test_manual_recovery_only_in_r_key_branch(self):
        calls = []
        for node in walk(self.parse("src/menu_gpu.sh")):
            if node.type != "command":
                continue
            command = node.child_by_field_name("name")
            if command is not None and command.text == b"recover_gpu_bindings":
                parent = node.parent
                while parent is not None and parent.type != "case_item":
                    parent = parent.parent
                self.assertIsNotNone(parent, "Recovery call is not gated by a key")
                patterns = []
                for child in parent.children:
                    if child.type == ")":
                        break
                    if child.type != "|":
                        patterns.append(child.text)
                self.assertEqual(patterns, [b"r", b"R"])
                calls.append(node)
        self.assertEqual(len(calls), 1)

    def test_gpu_check_has_no_forced_driver_release(self):
        for node in walk(self.parse("src/menu_gpu.sh")):
            if node.type == "file_redirect":
                self.assertNotIn(b"/unbind", node.text)
                self.assertNotIn(b"drivers_probe", node.text)

    def test_gpu_reports_are_connected_to_the_pager(self):
        targets = {"show_driver_check", "recover_gpu_bindings"}
        found = set()
        for node in walk(self.parse("src/menu_gpu.sh")):
            name = command_name(node)
            if name in targets:
                pipeline = ancestor(node, "pipeline")
                self.assertIsNotNone(pipeline, f"{name} bypasses pagination")
                self.assertEqual(command_name(pipeline.named_children[-1]), "show_paged_blocks")
                found.add(name)
        self.assertEqual(found, targets)

    def test_menu_entry_requires_successful_setup(self):
        nodes = list(walk(self.parse("src/menu.sh")))
        guard = next(node for node in nodes if command_name(node) == "ensure_setup_ready")
        guarded_list = ancestor(guard, "list")
        self.assertIsNotNone(guarded_list)
        self.assertIn(b"||", [child.text for child in guarded_list.children])
        self.assertTrue(any(command_name(node) == "exit" for node in walk(guarded_list)))
        menu = next(node for node in nodes if command_name(node) == "show_menu")
        self.assertLess(guard.end_byte, menu.start_byte)

    def test_setup_cannot_ignore_installation_failure(self):
        nodes = list(walk(self.parse("src/boot/setup.sh")))
        install = next(node for node in nodes if command_name(node) == "apk")
        guarded_list = ancestor(install, "list")
        self.assertIsNotNone(guarded_list)
        self.assertIn(b"||", [child.text for child in guarded_list.children])
        self.assertTrue(any(command_name(node) == "setup_failed" for node in walk(guarded_list)))
        ready = next(node for node in nodes if command_name(node) == "printf" and
                     any(child.text == b"ready" for child in node.named_children))
        self.assertLess(install.end_byte, ready.start_byte)

    def test_memtest_input_and_reboot_failures_have_guards(self):
        nodes = list(walk(self.parse("src/menu_memtest.sh")))
        for target, failure_action in (("read_key", "exit"), ("reboot", "memtest_start_failed")):
            with self.subTest(target=target):
                command = next(node for node in nodes if command_name(node) == target)
                condition = ancestor(command, "if_statement")
                self.assertIsNotNone(condition)
                self.assertEqual(command.parent.type, "negated_command")
                self.assertTrue(any(command_name(node) == failure_action for node in walk(condition)))


if __name__ == "__main__":
    unittest.main()
