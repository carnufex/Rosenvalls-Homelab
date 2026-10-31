"""Writes Skolverket's curricula and syllabi as Markdown for Lots' school knowledge sources.

Source: Skolverket's open Syllabus API (https://api.skolverket.se/syllabus, public data). One directory per knowledge source, one
file per syllabus and school form, and every heading says which syllabus it belongs to (GY25 subject grades, GY11 courses, Lgr22),
so a passage and its citation are never ambiguous. Run it again to pick up a new version:  python skolverket.py   (writes ./skola/...)
"""
import html
import json
import re
import sys
import urllib.request
from pathlib import Path

API = "https://api.skolverket.se/syllabus/v1"
OUT = Path(__file__).resolve().parent / "skola"

GY25 = "gymnasieskolan, ämnesbetyg med nivåer (GY25, elever som började från hösten 2025)"
GY11 = "gymnasieskolan, kurser (GY11, elever som började före hösten 2025)"
LGR22 = "grundskolan, kursplan (Lgr22, grundskoleämnen på introduktionsprogrammen)"

# Source id -> [(kind, code, title)]. kind: subject | curriculum.
SOURCES = {
    "skola-styrdokument": [("curriculum", "LGY2025", "Läroplan för gymnasieskolan (Lgy11, lydelse från 2025)")],
    "skola-svenska": [
        ("subject", "SVEN", f"Svenska – {GY25}"),
        ("subject", "SVE", f"Svenska – {GY11}"),
        ("subject", "GRGRSVE01", f"Svenska – {LGR22}"),
    ],
    "skola-svenska-som-andrasprak": [
        ("subject", "SVEA", f"Svenska som andraspråk – {GY25}"),
        ("subject", "SVA", f"Svenska som andraspråk – {GY11}"),
        ("subject", "GRGRSVA01", f"Svenska som andraspråk – {LGR22}"),
    ],
    "skola-historia": [
        ("subject", "HIST", f"Historia – {GY25}"),
        ("subject", "HIS", f"Historia – {GY11}"),
        ("subject", "GRGRHIS01", f"Historia – {LGR22}"),
    ],
}

SYSTEM = {"GRADE_SUBJECT_SYLLABUS": "GY25", "SUBJECT_SYLLABUS": "GY11", "COURSE_SYLLABUS": "Lgr22"}


def get(path):
    with urllib.request.urlopen(f"{API}/{path}", timeout=60) as r:
        return json.loads(r.read().decode("utf-8"))


def inline(fragment, keep_lines=False):
    # Spaces inside an emphasis go outside it ("<strong> viss </strong>" -> " **viss** "); adjacent ones are joined.
    s = re.sub(r"<(strong|b)>(\s*)(.*?)(\s*)</\1>", lambda m: f"{m.group(2)}**{m.group(3)}**{m.group(4)}" if m.group(3) else m.group(2) + m.group(4), fragment, flags=re.S | re.I)
    s = re.sub(r"<(em|i)>(\s*)(.*?)(\s*)</\1>", lambda m: f"{m.group(2)}*{m.group(3)}*{m.group(4)}" if m.group(3) else m.group(2) + m.group(4), s, flags=re.S | re.I)
    s = html.unescape(re.sub(r"<[^>]+>", "", s))
    s = s.replace("****", "")
    return s if keep_lines else re.sub(r"\s+", " ", s).strip()


def strip(fragment):
    return re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", fragment or ""))).strip()


def md(fragment):
    """Skolverket's HTML fragments as Markdown: headings, paragraphs, lists, emphasis."""
    if not fragment:
        return ""
    s = fragment
    for level in range(6, 0, -1):
        s = re.sub(rf"<h{level}[^>]*>(.*?)</h{level}>", lambda m, n=level: "\n\n" + "#" * n + " " + strip(m.group(1)) + "\n\n", s, flags=re.S | re.I)
    s = re.sub(r"<li[^>]*>(.*?)</li>", lambda m: "\n- " + inline(m.group(1)), s, flags=re.S | re.I)
    s = re.sub(r"</?(ul|ol)[^>]*>", "\n", s, flags=re.I)
    s = re.sub(r"<br\s*/?>", "\n", s, flags=re.I)
    s = re.sub(r"</p>", "\n\n", s, flags=re.I)
    s = inline(s, keep_lines=True)
    s = re.sub(r"[ \t]+\n", "\n", s)
    s = re.sub(r"\n[ \t]+", "\n", s)
    s = re.sub(r"\n{3,}", "\n\n", s)
    return s.strip()


def heading(text, level):
    return "#" * level + " " + text


def relevel(text, base, suffix=""):
    """Headings of a converted block moved so the highest is at `base`; `suffix` is added to each (what it belongs to)."""
    levels = [len(m.group(1)) for m in re.finditer(r"^(#+) ", text, flags=re.M)]
    if not levels:
        return text
    shift = base - min(levels)
    return re.sub(r"^(#+) (.*)$", lambda m: "#" * max(1, min(6, len(m.group(1)) + shift)) + " " + m.group(2) + suffix, text, flags=re.M)


def without_headings(fragment):
    return re.sub(r"<h\d[^>]*>.*?</h\d>", "", fragment or "", flags=re.S)


def source_line(d, what):
    changed = f", ändrad {d['skolfsAndring']}" if d.get("skolfsAndring") else ""
    return f"Källa: Skolverket, {what} {d['code']}, version {d.get('version', '?')}, gäller från {d.get('startDate', '?')}. SKOLFS {d.get('skolfsGrund') or '–'}{changed}."


def subject(code, title):
    d = get(f"subjects/{code}")["subject"]
    system = SYSTEM.get(d.get("typeOfSyllabus"), "")
    tag = f" – {d['name']} ({system})"
    out = [heading(title, 1), "", source_line(d, "ämnes-/kursplan"), ""]
    if d.get("description"):
        out += [md(d["description"]), ""]
    if d.get("purpose"):
        out += [heading("Ämnets syfte" + tag, 2), "", md(without_headings(d["purpose"])), ""]
    # Grundskolan: central content per year band, then the criteria for the whole subject.
    for cc in d.get("centralContents") or []:
        out += [heading(f"Centralt innehåll årskurs {cc.get('year', '')}{tag}", 2), "", relevel(md(cc.get("text", "")), 3), ""]
    for course in d.get("courses") or []:
        name = strip(course.get("nameHeading") or course.get("name", ""))
        label = f"{d['name']} {name[0].lower()}{name[1:]}" if name.lower().startswith("nivå") else name
        ctag = f" – {label} ({system})"
        out += [heading(f"{label} ({course.get('code', '')}, {system})", 2), ""]
        if strip(course.get("description")):
            out += [md(course["description"]), ""]
        central = course.get("centralContent") or {}
        if central.get("text"):
            out += [heading("Centralt innehåll" + ctag, 3), "", relevel(md(central["text"]), 4), ""]
        reqs = course.get("knowledgeRequirements") or []
        if reqs:
            out += [heading("Betygskriterier" + ctag, 3), ""]
            for r in reqs:
                out += [relevel(md(r.get("text", "")), 4, ctag), ""]
    reqs = d.get("knowledgeRequirements") or []
    if reqs:
        section = "Betygskriterier" if system != "Lgr22" else "Kriterier för bedömning av kunskaper och betygskriterier"
        out += [heading(section + tag, 2), ""]
        intro = md(without_headings(d.get("knowledgeReqsHeading")))
        if intro:
            out += [intro, ""]
        for r in reqs:
            text = md(r.get("text", ""))
            if not text.startswith("#"):
                step = " ".join(x for x in [r.get("gradeStep") and f"Betyget {r['gradeStep']}", r.get("year") and f"årskurs {r['year']}"] if x)
                text = heading(step or section, 3) + "\n\n" + text
            out += [relevel(text, 3, tag), ""]
    return "\n".join(out)


def curriculum(code, title):
    d = get(f"curriculums/{code}")["curriculum"]
    out = [heading(title, 1), "", source_line(d, "läroplan"), ""]
    for section in sorted(d.get("sections") or [], key=lambda x: int(x.get("sortOrder") or 0)):
        out += [heading(strip(section.get("heading", "")), 2), "", relevel(md(section.get("content", "")), 3), ""]
    return "\n".join(out)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def main():
    written = 0
    for source, items in SOURCES.items():
        folder = OUT / source
        folder.mkdir(parents=True, exist_ok=True)
        for old in folder.glob("*.md"):
            old.unlink()
        for kind, code, title in items:
            text = subject(code, title) if kind == "subject" else curriculum(code, title)
            path = folder / f"{slug(code)}.md"
            path.write_text(re.sub(r"\n{3,}", "\n\n", text).rstrip() + "\n", encoding="utf-8")
            written += path.stat().st_size
            print(f"{path.relative_to(OUT)}  {path.stat().st_size // 1024} kB")
    print(f"{written // 1024} kB in all")


if __name__ == "__main__":
    sys.exit(main())
