#!/usr/bin/env python3
"""Rewrites the catalogs tango ships in Sources/PaperEngine/Catalogs from their sources.

    python3 -I scripts/update-catalogs.py [lucide-static version]

- lucide.json: every Lucide icon, whole (ISC), from the npm package lucide-static. Each icon
  is a list of shapes, one string each: "p <d>" a path, "c cx cy r" a circle ("C" filled),
  "r x y w h rx ry" a rectangle, "l x1 y1 x2 y2" a line, "e cx cy rx ry" an ellipse,
  "o <points>" a polyline and "g <points>" a polygon, in a 24-point box, stroked 2 wide.
  Its tags are kept for search.
- material-symbols.json: the names, categories and tags of Google's Material Symbols
  (Apache 2.0), six tags each. Only names: each glyph is fetched when used and kept in the document.
- google-fonts.json: every family on Google Fonts with its category, its styles and its
  rank by popularity. Only the list: font files are fetched when used and kept in the
  document.
"""
import io
import json
import os
import sys
import tarfile
import urllib.request

OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "PaperEngine", "Catalogs")


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "tango-catalogs"})
    with urllib.request.urlopen(request) as answer:
        return answer.read()


def google_json(url):
    text = fetch(url).decode("utf-8")
    # Google's metadata starts with a line that keeps it from being run as a script.
    if text.startswith(")]}'"):
        text = text[4:]
    return json.loads(text)


def number(value):
    value = float(value)
    return str(int(value)) if value == int(value) else repr(value)


def lucide(version):
    if version is None:
        version = json.loads(fetch("https://registry.npmjs.org/lucide-static/latest"))["version"]
    archive = tarfile.open(fileobj=io.BytesIO(fetch(
        f"https://registry.npmjs.org/lucide-static/-/lucide-static-{version}.tgz")))
    nodes = json.load(archive.extractfile("package/icon-nodes.json"))
    tags = json.load(archive.extractfile("package/tags.json"))
    licence = archive.extractfile("package/LICENSE").read().decode("utf-8")
    icons = {}
    for name in sorted(nodes):
        shapes = []
        for tag, a in nodes[name]:
            if tag == "path":
                shapes.append("p " + a["d"])
            elif tag == "circle":
                filled = a.get("fill") not in (None, "none")
                shapes.append(("C " if filled else "c ") + " ".join(number(a[k]) for k in ("cx", "cy", "r")))
            elif tag == "rect":
                rx = a.get("rx", a.get("ry", 0))
                ry = a.get("ry", rx)
                shapes.append("r " + " ".join(number(v) for v in (a["x"], a["y"], a["width"], a["height"], rx, ry)))
            elif tag == "line":
                shapes.append("l " + " ".join(number(a[k]) for k in ("x1", "y1", "x2", "y2")))
            elif tag == "ellipse":
                shapes.append("e " + " ".join(number(a[k]) for k in ("cx", "cy", "rx", "ry")))
            elif tag == "polyline":
                shapes.append("o " + a["points"])
            elif tag == "polygon":
                shapes.append("g " + a["points"])
            else:
                raise SystemExit(f"lucide {name}: a shape tango cannot draw: {tag}")
        icons[name] = shapes
    catalog = {
        "version": version,
        "icons": icons,
        "tags": {name: " ".join(tags.get(name, [])) for name in sorted(nodes) if tags.get(name)},
    }
    return catalog, licence


def material():
    data = google_json("https://fonts.google.com/metadata/icons?incomplete=1&key=material_symbols")
    icons = []
    for icon in data["icons"]:
        unsupported = icon.get("unsupported_families", [])
        if "Material Symbols Outlined" in unsupported:
            continue
        icons.append([icon["name"], ",".join(icon.get("categories", [])), " ".join(icon.get("tags", [])[:6]), icon.get("popularity", 0)])
    icons.sort(key=lambda i: -i[3])
    return {"icons": [i[:3] for i in icons]}


def google_fonts():
    data = google_json("https://fonts.google.com/metadata/fonts")
    families = []
    for family in data["familyMetadataList"]:
        if not family.get("isOpenSource", True):
            continue
        styles = sorted(family["fonts"].keys(), key=lambda s: (s.endswith("i"), int(s.rstrip("i"))))
        families.append([family["family"], family["category"], " ".join(styles), family.get("popularity", 9999)])
    families.sort(key=lambda f: f[3])
    return {"families": [f[:3] for f in families]}


def write(name, value):
    with open(os.path.join(OUT, name), "w") as file:
        json.dump(value, file, separators=(",", ":"), ensure_ascii=False)
        file.write("\n")


def main():
    os.makedirs(OUT, exist_ok=True)
    catalog, licence = lucide(sys.argv[1] if len(sys.argv) > 1 else None)
    write("lucide.json", catalog)
    with open(os.path.join(OUT, "LICENSE-lucide.txt"), "w") as file:
        file.write(licence)
    write("material-symbols.json", material())
    write("google-fonts.json", google_fonts())
    for name in sorted(os.listdir(OUT)):
        print(f"{name}: {os.path.getsize(os.path.join(OUT, name)) // 1024} KB")


main()
