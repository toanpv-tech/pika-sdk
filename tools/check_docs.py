"""Keep the SDK's prose in step with the engine contract.

Checks every Markdown file under docs/, skill/ and libraries/ plus the kit:
  1. every `Global.name` / `obj:name` API mention exists in contract/api.json
     (an invented call in the docs becomes an invented call in generated code);
  2. every function, method, constant and hook in api.json appears in docs/reference/api.md;
  3. key numbers written in prose match contract/constraints.json;
  4. docs/docs.index.json lists every Markdown file under docs/ and nothing else;
  5. every relative Markdown link in the SDK points at a file that exists;
  6. every guide in docs/guides/ opens with the "For / Needs / Result" line of
     docs/templates/_guide-template.md;
  7. every `file.md#anchor` / `#anchor` link resolves to a heading (GitHub slug
     rules, duplicates get -1, -2) or an explicit `<a id="...">` in the target;
  8. every (`key` = N) pair whose key is in constraints.json limits/derived matches it;
  9. docs/guides/ carry no bare limit numbers: a number with a unit (ms, s, px,
     KiB, MiB, KB, MB, bytes, B, fps, Hz) equal to a limit or derived value
     must be written as (`key` = N) or linked;
 10. generated pages (docs/reference/api.md, known-issues.md, the pages rendered
     from contract/pages/, skill/api-contract.md, skill/constraints.md) start
     with the GENERATED header and match what tools/gen_contract.py produces;
 11. sdk.index.json paths exist; skill/skill.index.json, libraries/libs.index.json
     and examples/examples.index.json list exactly what is on disk; versions agree;
 12. every skill/recipes/*.md with a manifest ```json block and ```lua blocks
     runs through tools/smoke.py as a temporary pack without errors.

Opt-outs, per line: `<!-- not-an-api -->` for check 1 (tables that list calls
which do NOT exist, e.g. "Sprite.rotate: no such call"); `<!-- number-ok -->`
for check 9. contract/pages/ are templates (links relative to their output,
{{key}} placeholders) and are only checked through their rendered output.

usage: python tools/check_docs.py        exit 1 on any finding
"""
import json
import os
import re
import sys

SDK = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
SCAN = ["docs", "skill", "libraries", "kit", "README.md", "MAINTAINING.md", "RATIONALE.md"]
OPT_OUT = "<!-- not-an-api -->"
PAGES_SRC = os.path.join(SDK, "contract", "pages")

# (regex over prose, constraint key, human label). Group 1 is the number.
NUMBERS = [
    (r"cooldown[^.\n|]{0,30}?(\d+)\s?ms", "sound_cooldown_ms", "Speaker.play cooldown"),
    (r"(\d+)\s?ms[^.\n|]{0,20}cooldown", "sound_cooldown_ms", "Speaker.play cooldown"),
    (r"watchdog[^.\n|]{0,30}?(\d+(?:\.\d+)?)\s?s\b", "hook_watchdog_s", "hook watchdog (s)"),
    (r"Text[^.\n|]{0,25}?pool[^.\n|]{0,20}?(\d+)", "text_slots", "Text pool"),
    (r"(\d+)\s?(?:px)?\s*\(?`?GAME_TRANSFORM_MAX_PX", "transform_max_px", "transform limit"),
    (r"[≤<]=?\s?(\d+)\s?(?:px|×\s?\d+)[^.\n|]{0,40}(?:scale|rotat)", "transform_max_px", "transform limit"),
]


def load(rel):
    with open(os.path.join(SDK, rel), encoding="utf-8") as f:
        return json.load(f)


def files():
    for top in SCAN:
        p = os.path.join(SDK, top)
        if os.path.isfile(p):
            yield p
            continue
        for d, _, fs in os.walk(p):
            for f in fs:
                if f.endswith((".md", ".lua", ".js", ".html")) and f != "pika-constraints.js":
                    yield os.path.join(d, f)


LINK = re.compile(r"\]\(([^)\s]+)\)")
GUIDE_HEAD = re.compile(r"^> \*\*For:\*\*.+\*\*Result:\*\*", re.M)


def md_files(top):
    for d, dirs, fs in os.walk(top):
        dirs[:] = [x for x in dirs if x not in ("assets", "lua-5.5.0", "node_modules", ".git")
                   and os.path.join(d, x) != PAGES_SRC]
        for f in fs:
            if f.endswith(".md"):
                yield os.path.join(d, f)


def check_index():
    docs = os.path.join(SDK, "docs")
    listed = {e["file"] for e in load("docs/docs.index.json")["docs"]}
    present = {os.path.relpath(p, docs).replace(os.sep, "/") for p in md_files(docs)}
    out = ["docs/docs.index.json  lists %s, which does not exist" % f for f in sorted(listed - present)]
    out += ["docs/%s  is not listed in docs/docs.index.json" % f for f in sorted(present - listed)]
    return out


def check_links():
    out = []
    for path in md_files(SDK):
        rel = os.path.relpath(path, SDK)
        text = open(path, encoding="utf-8").read()
        text = re.sub(r"```.*?```", "", text, flags=re.S)
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target) or target.startswith("#"):
                continue
            dest = os.path.normpath(os.path.join(os.path.dirname(path), target.split("#", 1)[0]))
            if not os.path.exists(dest):
                out.append("%s  broken link: %s" % (rel, target))
    return out


def check_guides():
    out = []
    for path in md_files(os.path.join(SDK, "docs", "guides")):
        if not GUIDE_HEAD.search(open(path, encoding="utf-8").read()[:600]):
            out.append("%s  missing the '> **For:** ... **Result:** ...' line (see docs/templates/_guide-template.md)"
                       % os.path.relpath(path, SDK))
    return out


# ------------------------------------------------------------------ 7. anchors
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
EXPLICIT_ID = re.compile(r"""<a\s+(?:id|name)\s*=\s*["']([^"']+)["']""", re.I)
FENCE = re.compile(r"^\s*(```|~~~)")


def prose_lines(text):
    """(line number, line) outside fenced code blocks."""
    fenced = False
    for n, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            yield n, line


def slug(heading):
    """GitHub heading id: drop markup, lowercase, keep letters/digits/space/-/_, spaces to -."""
    t = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)       # [text](link) -> text
    t = re.sub(r"<[^>]+>", "", t)                                # inline HTML
    t = t.strip().lower()
    t = "".join(c for c in t if c.isalnum() or c in " -_")
    return t.replace(" ", "-")


_anchor_cache = {}


def anchors_of(path):
    if path not in _anchor_cache:
        ids, seen = set(), {}
        text = open(path, encoding="utf-8").read()
        for _, line in prose_lines(text):
            ids.update(EXPLICIT_ID.findall(line))
            m = HEADING.match(line)
            if m:
                base = slug(m.group(2))
                k = seen.get(base, 0)
                seen[base] = k + 1
                ids.add(base if k == 0 else "%s-%d" % (base, k))
        _anchor_cache[path] = ids
    return _anchor_cache[path]


def check_anchors():
    out = []
    for path in md_files(SDK):
        rel = os.path.relpath(path, SDK).replace(os.sep, "/")
        text = "\n".join(line for _, line in prose_lines(open(path, encoding="utf-8").read()))
        for target in LINK.findall(text):
            if re.match(r"^[a-z]+:", target) or "#" not in target:
                continue
            file_part, anchor = target.split("#", 1)
            dest = os.path.normpath(os.path.join(os.path.dirname(path), file_part)) if file_part else path
            if not dest.endswith(".md") or not os.path.isfile(dest):
                continue                                         # missing files are check 5
            if anchor not in anchors_of(dest):
                out.append("%s  broken anchor: %s (no heading or <a id> '%s' in %s)"
                           % (rel, target, anchor, os.path.relpath(dest, SDK).replace(os.sep, "/")))
    return out


# ------------------------------------------------------------------ 8. (`key` = N) pairs
PAIR = re.compile(r"`([a-z][a-z0-9_]*)`\s*=\s*(-?\d+(?:\.\d+)?)")


def check_pairs(values):
    out = []
    for path in md_files(SDK):
        rel = os.path.relpath(path, SDK).replace(os.sep, "/")
        for n, line in prose_lines(open(path, encoding="utf-8").read()):
            for key, num in PAIR.findall(line):
                if key in values and isinstance(values[key], (int, float)) and float(num) != float(values[key]):
                    out.append("%s:%d  `%s` = %s, contract says %s" % (rel, n, key, num, values[key]))
    return out


# ------------------------------------------------------------------ 9. guides number policy
UNIT_NUM = re.compile(r"(?<![\w.`=#-])(\d+(?:\.\d+)?)\s?(ms|s|px|KiB|MiB|KB|MB|bytes|B|fps|Hz)\b")
NUMBER_OK = "<!-- number-ok -->"


def check_guide_numbers(values):
    nums = {}
    for k, v in values.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            nums.setdefault(float(v), []).append(k)
    out = []
    for path in md_files(os.path.join(SDK, "docs", "guides")):
        rel = os.path.relpath(path, SDK).replace(os.sep, "/")
        for n, line in prose_lines(open(path, encoding="utf-8").read()):
            if NUMBER_OK in line:
                continue
            bare = PAIR.sub("", line)
            for num, unit in UNIT_NUM.findall(bare):
                keys = nums.get(float(num))
                if keys:
                    out.append("%s:%d  bare limit number '%s %s' (= %s): write (`%s` = %s) or link the reference, "
                               "or mark the line %s" % (rel, n, num, unit, "/".join(keys), keys[0], num, NUMBER_OK))
    return out


# ------------------------------------------------------------------ 10. generated pages
GENERATED = ["docs/reference/api.md", "docs/reference/known-issues.md", "skill/api-contract.md", "skill/constraints.md"]


def generated_pages():
    pages = list(GENERATED)
    if os.path.isdir(PAGES_SRC):
        pages += ["docs/reference/" + f for f in sorted(os.listdir(PAGES_SRC)) if f.endswith(".md")]
    return pages


def check_generated():
    out = []
    for rel in generated_pages():
        path = os.path.join(SDK, rel)
        if not os.path.isfile(path):
            out.append("%s  generated page is missing (run python tools/gen_contract.py)" % rel)
        elif not open(path, encoding="utf-8").read().startswith("<!-- GENERATED"):
            out.append("%s  does not start with the GENERATED header: it is generated, never edit it by hand" % rel)
    fw = os.path.abspath(os.path.join(SDK, ".."))
    if not os.path.isdir(os.path.join(fw, "head_esp32")):
        return out, "stale check skipped: no firmware checkout next to the SDK"
    sys.path.insert(0, os.path.join(SDK, "tools"))
    try:
        import gen_contract
        files_ = gen_contract.outputs(fw)
    except Exception as e:                                       # a broken contract is a finding, not a crash
        return out + ["tools/gen_contract.py  failed in-process: %s" % e], None
    for path, text in files_.items():
        try:
            cur = open(path, encoding="utf-8").read()
        except FileNotFoundError:
            cur = ""
        if cur != text:
            out.append("%s  stale: differs from what tools/gen_contract.py generates (run it)"
                       % os.path.relpath(path, SDK).replace(os.sep, "/"))
    return out, None


# ------------------------------------------------------------------ 11. index completeness
def _paths(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("path", "index", "file", "entry") and isinstance(v, str):
                yield v
            else:
                yield from _paths(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _paths(v)


def check_indexes():
    out = []
    sdk = load("sdk.index.json")
    for p in _paths(sdk):
        if not os.path.exists(os.path.join(SDK, p)):
            out.append("sdk.index.json  lists %s, which does not exist" % p)

    sk = load("skill/skill.index.json")
    listed = {e["file"] for e in sk.get("files", [])} | {e["file"] for e in sk.get("recipes", {}).get("items", [])}
    for f in sorted(listed):
        if not os.path.isfile(os.path.join(SDK, "skill", f)):
            out.append("skill/skill.index.json  lists %s, which does not exist" % f)
    present = {f for f in os.listdir(os.path.join(SDK, "skill")) if f.endswith(".md")}
    present |= {"recipes/" + f for f in os.listdir(os.path.join(SDK, "skill", "recipes")) if f.endswith(".md")}
    for f in sorted(present - listed):
        out.append("skill/%s  is not listed in skill/skill.index.json" % f)
    for t in sk.get("templates", {}).get("items", []):
        if not os.path.isdir(os.path.join(SDK, "skill", "templates", t["dir"])):
            out.append("skill/skill.index.json  lists template %s, which does not exist" % t["dir"])

    libs = os.path.join(SDK, "libraries")
    listed = {m["file"] for m in load("libraries/libs.index.json")["modules"]}
    present = {os.path.relpath(os.path.join(d, f), libs).replace(os.sep, "/")
               for d, _, fs in os.walk(libs) for f in fs if f.endswith(".lua")}
    out += ["libraries/libs.index.json  lists %s, which does not exist" % f for f in sorted(listed - present)]
    out += ["libraries/%s  is not listed in libraries/libs.index.json" % f for f in sorted(present - listed)]

    ex = os.path.join(SDK, "examples")
    listed = {e["dir"] for e in load("examples/examples.index.json")["examples"]}
    present = {d for d in os.listdir(ex) if os.path.isdir(os.path.join(ex, d))}
    out += ["examples/examples.index.json  lists %s, which does not exist" % d for d in sorted(listed - present)]
    out += ["examples/%s  is not listed in examples/examples.index.json" % d for d in sorted(present - listed)]

    ver = open(os.path.join(SDK, "sdk_version"), encoding="utf-8").read().strip()
    if sdk.get("sdk_version") != ver:
        out.append("sdk.index.json  sdk_version %s, sdk_version file says %s" % (sdk.get("sdk_version"), ver))
    api_min = (sdk.get("engine_api") or {}).get("min")
    for rel in ("skill/skill.index.json", "docs/docs.index.json", "libraries/libs.index.json",
                "examples/examples.index.json"):
        j = load(rel)
        for k in ("sdk_version", "version"):
            if k in j and j[k] != ver:
                out.append("%s  %s %s conflicts with sdk_version %s" % (rel, k, j[k], ver))
        m = (j.get("engine_api") or {}).get("min")
        if m is not None and m != api_min:
            out.append("%s  engine_api.min %s differs from sdk.index.json (%s)"
                       % (rel, m, "engine_api.min " + api_min if api_min else "no engine_api.min"))
    return out


# ------------------------------------------------------------------ 12. recipes run
BLOCK = re.compile(r"^```(json|lua)[^\n]*\n(.*?)^```", re.M | re.S)
LUA_FILE_HEADING = re.compile(r"^#{1,6}\s+`([\w/.-]+\.lua)`\s*$", re.M)
CHECK_STEPS = re.compile(r"""tools/smoke\.py\s+<pack>\s+["']([^"']+)["']""")


def silent_wav(path):
    import wave
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\0\0" * 1600)


def check_recipes():
    import shutil
    import subprocess
    import tempfile
    out, skipped, ran = [], [], 0
    rdir = os.path.join(SDK, "skill", "recipes")
    for fn in sorted(os.listdir(rdir)):
        if not fn.endswith(".md"):
            continue
        rel = "skill/recipes/" + fn
        text = open(os.path.join(rdir, fn), encoding="utf-8").read()
        man, lua, extra = None, [], {}
        for m in BLOCK.finditer(text):
            kind, body = m.group(1), m.group(2)
            if kind == "lua":
                # A block under a "## `libs/x.lua`" heading is that file; the rest is the entry script.
                heads = LUA_FILE_HEADING.findall(text[:m.start()])
                target = heads[-1] if heads else None
                if target and not target.startswith("scripts/"):
                    extra[target] = body
                else:
                    lua.append(body)
            elif man is None:
                try:
                    j = json.loads(body)
                except ValueError:
                    continue
                if isinstance(j, dict) and ("main" in j or "version" in j):
                    man = j
        if man is None or not lua:
            skipped.append(fn)
            continue
        ran += 1
        pack = tempfile.mkdtemp(prefix="pika-recipe-")
        try:
            main = man.get("main", "scripts/main.lua")
            os.makedirs(os.path.dirname(os.path.join(pack, main)), exist_ok=True)
            src = "\n".join(lua)
            with open(os.path.join(pack, main), "w", encoding="utf-8") as f:
                f.write(src)
            for target, body in extra.items():
                os.makedirs(os.path.dirname(os.path.join(pack, target)) or pack, exist_ok=True)
                with open(os.path.join(pack, target), "w", encoding="utf-8") as f:
                    f.write(body)
            with open(os.path.join(pack, "manifest.json"), "w", encoding="utf-8") as f:
                json.dump(man, f)
            # A declared sound must exist or the robot rejects the pack: stand in with silence.
            # Image sizes are unknown, so missing images are left for smoke to report.
            for d in ((man.get("audio") or {}).get("sounds") or {}).values():
                p = d.get("path") if isinstance(d, dict) else None
                if isinstance(p, str) and not os.path.isabs(p) and ".." not in p:
                    silent_wav(os.path.join(pack, p))
            for mod in set(re.findall(r"""require\(\s*["']libs/([\w/]+)["']""", src)):
                lib = os.path.join(SDK, "libraries", mod + ".lua")
                if os.path.isfile(lib) and ("libs/%s.lua" % mod) not in extra:
                    os.makedirs(os.path.dirname(os.path.join(pack, "libs", mod)), exist_ok=True)
                    shutil.copy(lib, os.path.join(pack, "libs", mod + ".lua"))
            cmd = [sys.executable, os.path.join(SDK, "tools", "smoke.py"), pack]
            m = CHECK_STEPS.search(text)
            if m:
                cmd.append(m.group(1))
            r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                               env=dict(os.environ, PYTHONIOENCODING="utf-8"))
            for line in r.stdout.splitlines():
                if line.startswith("ERROR"):
                    out.append("%s  smoke: %s" % (rel, line.replace(pack, "<pack>")))
            if r.returncode == 2:
                out.append("%s  smoke: could not run (%s)" % (rel, (r.stdout + r.stderr).strip().splitlines()[-1:]))
        finally:
            shutil.rmtree(pack, ignore_errors=True)
    summary = "recipes: %d run through smoke, %d skipped without a manifest + lua block%s" % (
        ran, len(skipped), (": " + ", ".join(skipped)) if skipped else "")
    return out, summary


def main():
    api = load("contract/api.json")
    cons = load("contract/constraints.json")
    lim = dict(cons["limits"])
    values = dict(cons["limits"], **cons.get("derived", {}))
    lim["hook_watchdog_s"] = lim["hook_watchdog_ms"] / 1000
    g = api["globals"]
    methods = {m for v in g.values() for m in v["methods"]}
    call = re.compile(r"\b(" + "|".join(sorted(g, key=len, reverse=True)) + r")\.([a-zA-Z_][a-zA-Z0-9_]*)")
    mcall = re.compile(r"\b(?:spr|sprite|t|txt|label|anim|a|s|shape|hud|obj)[:.]([a-z_][a-z0-9_]*)\(")
    findings = []

    for path in files():
        rel = os.path.relpath(path, SDK)
        is_md = path.endswith(".md")
        with open(path, encoding="utf-8") as f:
            for n, line in enumerate(f, 1):
                if OPT_OUT in line:
                    continue
                for glob, name in call.findall(line):
                    v = g[glob]
                    wildcard = name.endswith("_") and any(c.startswith(name) for c in v["constants"])
                    if not wildcard and name not in v["functions"] and name not in v["constants"] and name not in v["methods"]:
                        findings.append("%s:%d  %s.%s is not an engine API" % (rel, n, glob, name))
                if is_md:
                    for name in mcall.findall(line):
                        if name not in methods and name not in ("new",):
                            findings.append("%s:%d  method :%s is not an engine API" % (rel, n, name))
                    for rx, key, label in NUMBERS:
                        for m in re.finditer(rx, line, re.I):
                            val = float(m.group(1))
                            if val != float(lim[key]):
                                findings.append("%s:%d  %s says %s, contract says %s" % (rel, n, label, m.group(1), lim[key]))

    ref_path = os.path.join(SDK, "docs", "reference", "api.md")
    ref = open(ref_path, encoding="utf-8").read() if os.path.isfile(ref_path) else ""
    for glob, v in g.items():
        for name in v["functions"] + v["constants"]:
            if glob + "." + name not in ref:
                findings.append("docs/reference/api.md  missing %s.%s" % (glob, name))
        for name in v["methods"]:
            if ":" + name not in ref:
                findings.append("docs/reference/api.md  missing method %s:%s" % (glob, name))
    for hook in api["hooks"]:
        if hook not in ref:
            findings.append("docs/reference/api.md  missing hook %s" % hook)

    findings += check_index() + check_links() + check_guides()
    findings += check_anchors() + check_pairs(values) + check_guide_numbers(values)
    gen, gen_note = check_generated()
    findings += gen + check_indexes()
    rec, rec_note = check_recipes()
    findings += rec

    for f in findings:
        print(f)
    for note in (gen_note, rec_note):
        if note:
            print(note)
    print("%d finding(s)" % len(findings))
    return 1 if findings else 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
