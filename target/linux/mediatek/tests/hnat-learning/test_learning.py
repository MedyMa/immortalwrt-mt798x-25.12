#!/usr/bin/env python3
"""Exercise the actual patched C functions with bounded host kernel-API fixtures."""
import argparse
from pathlib import Path
import os
import re
import subprocess
import tempfile


def function(source, name):
    match = re.search(r"\b" + re.escape(name) + r"\s*\(", source)
    if not match:
        raise ValueError("Missing function: " + name)
    start = source.rfind("\n\n", 0, match.start()) + 2
    brace = source.index("{", match.end())
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel-tree", type=Path, required=True,
                        help="Prepared kernel after the complete patch series")
    parser.add_argument("--npu-source", type=Path, required=True,
                        help="mtk_npu/src directory")
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    directory = Path(__file__).resolve().parent
    hnat = args.kernel_tree / "drivers/net/ethernet/mediatek/mtk_hnat"
    candidate = (args.npu_source / "inc/npu-nf_hnat/candidate.h").read_text()
    cases = {"candidate": {
        "CANDIDATE": function(candidate, "mtk_npu_tunnel_candidate"),
    }}
    diag = hnat / "hnat_diag.c"
    source = diag.read_text()
    names = ["diag_rows_live", "diag_hint_index", "diag_hint_rebuild",
             "diag_hint_matches", "diag_touch", "diag_ct_key", "same_key",
             "diag_row", "hnat_diag_bind"]
    cases["diagnostics"] = {"FUNCTIONS": "\n".join(function(source, n) for n in names)}
    source = (hnat / "hnat_nf_hook.c").read_text()
    names = ["hnat_flow_entry_free_rcu", "hnat_flow_entry_delete",
             "hnat_flow_entry_search", "hnat_flow_entry_reserve",
             "hnat_flow_entry_store", "hnat_flow_entry_lock_current"]
    cases["shadow"] = {"FUNCTIONS": "\n".join(function(source, n) for n in names)}
    source = (hnat / "hnat_account.c").read_text()
    cases["bulk_clear"] = {"FUNCTION": function(source, "hnat_account_clear_all_bindings")}
    with tempfile.TemporaryDirectory(prefix="mtk-hnat-learning-") as temporary:
        output = Path(temporary)
        for name, replacements in cases.items():
            text = (directory / (name + ".c.in")).read_text()
            for key, value in replacements.items():
                text = text.replace("@" + key + "@", value)
            path = output / (name + ".c")
            path.write_text(text)
            binary = output / name
            subprocess.run([args.cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            "-fsanitize=address,undefined", "-fno-sanitize-recover=undefined",
                            "-fno-omit-frame-pointer",
                            "-g", str(path), "-o", str(binary)], check=True)
            environment = os.environ.copy()
            environment["ASAN_OPTIONS"] = "detect_leaks=1:abort_on_error=1"
            subprocess.run([str(binary)], env=environment, check=True)


if __name__ == "__main__":
    main()
