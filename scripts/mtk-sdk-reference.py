#!/usr/bin/env python3
"""Read and verify the repository's offline MTK documentation/source references.

This tool never executes document commands, extracts archives, contacts a router,
or changes firmware configuration. It only uses the Python standard library.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import tarfile


REPO = Path(__file__).resolve().parents[1]
REFERENCE = REPO / "package/mtk/pdf"
MAX_MEMBER_BYTES = 2 * 1024 * 1024
SOURCE_SUFFIXES = {".c", ".h", ".cc", ".cpp", ".uc", ".lua", ".sh", ".mk", ".txt"}


def read_json(path):
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def relative_file(root, name):
    candidate = PurePosixPath(name)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise ValueError(f"Invalid relative reference path: {name}")
    path = (root / name).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError(f"Reference escapes its directory: {name}")
    return path


def checked_file(root, record, git_blob=False):
    path = relative_file(root, record["file"])
    data = path.read_bytes()
    if "bytes" in record and len(data) != record["bytes"]:
        raise ValueError(f"Size mismatch: {record['file']}")
    if hashlib.sha256(data).hexdigest() != record["sha256"]:
        raise ValueError(f"SHA-256 mismatch: {record['file']}")
    if git_blob and record.get("upstream_git_blob_sha1"):
        digest = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
        if digest != record["upstream_git_blob_sha1"]:
            raise ValueError(f"Upstream Git blob mismatch: {record['file']}")
    return path


def page_rows(manifest):
    path = relative_file(REFERENCE, manifest["page_index"]["file"])
    with path.open(encoding="utf-8") as stream:
        for line in stream:
            yield json.loads(line)


def verify(manifest):
    documents = {entry["id"]: entry for entry in manifest["documents"]}
    if len(documents) != len(manifest["documents"]):
        raise ValueError("Duplicate document ID")
    for document in documents.values():
        checked_file(REFERENCE, document, git_blob=True)
        note = relative_file(REFERENCE, document["analysis"])
        if not note.is_file() or not note.read_text(encoding="utf-8").strip():
            raise ValueError(f"Missing analysis: {document['id']}")
    for key in ("page_index", "source_map"):
        checked_file(REFERENCE, manifest[key])
    seen, ocr_seen = set(), set()
    for row in page_rows(manifest):
        key = (row["document"], row["page"])
        if key in seen or key[0] not in documents:
            raise ValueError(f"Invalid/duplicate page: {key}")
        if not isinstance(row["native_text"], str):
            raise ValueError(f"Invalid page text: {key}")
        seen.add(key)
        if "ocr_text_unverified" in row:
            if not isinstance(row["ocr_text_unverified"], str):
                raise ValueError(f"Invalid OCR text: {key}")
            ocr_seen.add(key)
    expected = {(name, page) for name, doc in documents.items()
                for page in range(1, doc["pages"] + 1)}
    expected_ocr = {(name, page) for name, doc in documents.items()
                    for page in doc["ocr_pages"]}
    if seen != expected or len(seen) != manifest["page_index"]["pages"]:
        raise ValueError("Page index coverage does not match the PDFs")
    if ocr_seen != expected_ocr or len(ocr_seen) != manifest["page_index"]["ocr_pages"]:
        raise ValueError("OCR coverage does not match the manifest")
    cache = manifest["source_cache"]
    mirrored = [entry for entry in cache["archives"] if entry["mirrored"]]
    for entry in mirrored:
        checked_file(REPO, entry, git_blob=True)
    for entry in cache["preserved_build_inputs"]:
        checked_file(REPO, entry)
    print(f"Verified {len(documents)} PDFs, {len(seen)} physical pages, "
          f"{len(ocr_seen)} OCR supplements, {len(mirrored)} mirrored archives "
          f"and {len(cache['preserved_build_inputs'])} preserved build inputs.")


def search(manifest, args):
    query = args.query.casefold()
    if not query:
        raise ValueError("Search text must not be empty")
    found = 0
    for row in page_rows(manifest):
        if args.doc and row["document"] != args.doc:
            continue
        for field in ("native_text", "ocr_text_unverified"):
            text = row.get(field, "")
            offset = text.casefold().find(query)
            if offset < 0:
                continue
            snippet = " ".join(text[max(0, offset - 100):offset + len(args.query) + 220].split())
            kind = "OCR, verify against original image" if field.startswith("ocr") else "native text"
            print(f"{row['document']} PDF p{row['page']} [{kind}] {snippet}")
            found += 1
            if found >= args.limit:
                return
    if not found:
        print("No matching text; this does not rule out content inside PDF figures.")


def show_page(manifest, args):
    for row in page_rows(manifest):
        if row["document"] == args.doc and row["page"] == args.page:
            print(f"{args.doc}, physical PDF page {args.page}\n")
            print(row["native_text"])
            if row.get("ocr_text_unverified"):
                print("\n--- OCR supplement: verify commands/numbers against the original image ---\n")
                print(row["ocr_text_unverified"])
            return
    raise ValueError("No such physical PDF page")


def archive_record(manifest, name):
    cache = manifest["source_cache"]
    name = name.removeprefix("dl/")
    for entry in cache["archives"] + cache["preserved_build_inputs"]:
        if entry["file"] == "dl/" + name:
            if entry.get("mirrored", True) is False:
                raise ValueError("Archive was intentionally not imported; see knowledge/index.json")
            return entry, checked_file(REPO, entry, git_blob=True)
    raise ValueError("Archive is not in the reference manifest")


def member_text(tar, member):
    name = PurePosixPath(member.name)
    if name.is_absolute() or ".." in name.parts or not member.isfile():
        raise ValueError("Only regular, relative archive members can be read")
    if member.size > MAX_MEMBER_BYTES:
        raise ValueError("Member exceeds the 2 MiB text-view limit")
    with tar.extractfile(member) as stream:
        data = stream.read(MAX_MEMBER_BYTES + 1)
    if len(data) > MAX_MEMBER_BYTES or b"\0" in data or data.startswith(b"\x7fELF"):
        raise ValueError("Binary member cannot be displayed as source text")
    return data.decode("utf-8", errors="replace")


def archive(manifest, args):
    record, path = archive_record(manifest, args.archive)
    print(f"{record['file']} [{record.get('status', 'preserved-current-build-input')}] "
          "archive contents; package patches are not applied\n")
    with tarfile.open(path, "r:*") as tar:
        if args.command == "archive-list":
            matches = (member for member in tar if member.isfile() and
                       (not args.match or args.match.casefold() in member.name.casefold()))
            for index, member in enumerate(matches):
                if index >= args.limit:
                    print("... use --match or a larger --limit for additional members")
                    break
                print(f"{member.size:10d} {member.name}")
        elif args.command == "archive-show":
            member = tar.getmember(args.member)
            lines = member_text(tar, member).splitlines()
            for number in range(args.start, min(len(lines) + 1, args.start + args.lines)):
                print(f"{number}: {lines[number - 1]}")
        else:
            count = 0
            for member in tar:
                name = PurePosixPath(member.name)
                if not member.isfile() or member.size > MAX_MEMBER_BYTES:
                    continue
                if name.suffix not in SOURCE_SUFFIXES and name.name not in {"Makefile", "Kconfig", "CMakeLists.txt"}:
                    continue
                try:
                    lines = member_text(tar, member).splitlines()
                except ValueError:
                    continue
                for number, line in enumerate(lines, 1):
                    if args.query.casefold() in line.casefold():
                        print(f"{member.name}:{number}: {line.strip()[:300]}")
                        count += 1
                        if count >= args.limit:
                            return


def positive(value):
    result = int(value)
    if result < 1:
        raise argparse.ArgumentTypeError("Must be a positive integer")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("verify", help="Check hashes, physical page coverage and source archives")
    find = commands.add_parser("search", help="Search extracted native/OCR reference text")
    find.add_argument("query")
    find.add_argument("--doc")
    find.add_argument("--limit", type=positive, default=10)
    page = commands.add_parser("page", help="Show one physical PDF page")
    page.add_argument("doc")
    page.add_argument("page", type=positive)
    listing = commands.add_parser("archive-list", help="List archive members without extracting")
    listing.add_argument("archive")
    listing.add_argument("--match")
    listing.add_argument("--limit", type=positive, default=40)
    show = commands.add_parser("archive-show", help="Read a bounded text member without extracting")
    show.add_argument("archive")
    show.add_argument("member")
    show.add_argument("--start", type=positive, default=1)
    show.add_argument("--lines", type=positive, default=80)
    find_archive = commands.add_parser("archive-search", help="Find text in source members")
    find_archive.add_argument("archive")
    find_archive.add_argument("query")
    find_archive.add_argument("--limit", type=positive, default=10)
    args = parser.parse_args()
    manifest = read_json(REFERENCE / "knowledge/index.json")
    document = getattr(args, "doc", None)
    if document and document not in {entry["id"] for entry in manifest["documents"]}:
        parser.error("Unknown document ID; see package/mtk/pdf/knowledge/index.json")
    if args.command == "archive-search" and not args.query:
        parser.error("Search text must not be empty")
    if args.command == "verify":
        verify(manifest)
    elif args.command == "search":
        search(manifest, args)
    elif args.command == "page":
        show_page(manifest, args)
    else:
        archive(manifest, args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"Reference error: {error}", file=sys.stderr)
        sys.exit(1)
