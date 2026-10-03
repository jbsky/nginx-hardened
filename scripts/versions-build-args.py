#!/usr/bin/env python3
"""versions-build-args.py -- versions.json, seule source des versions du build.

Pourquoi : une version ecrite a deux endroits finit par diverger sans que rien
n'echoue. C'est arrive : varnish construisait 7.7.3 en local (ARG par defaut
jamais mis a jour) pendant que la CI publiait 8.0.0 ; suricata gardait
SURICATA_VERSION=8.0.2 dans .env.example quand versions.json disait 8.0.7.
Le build lit donc ses versions UNIQUEMENT dans versions.json, et ce script est
a la fois le seul chemin de versions.json vers le build et le controle qui le
garantit.

Convention de nommage (cle de versions.json -> ARG du Dockerfile) :
    "suricata"        -> SURICATA_VERSION
    "libhtp_sha256"   -> LIBHTP_SHA256
    "tcc_commit"      -> TCC_COMMIT
    "json-c_tag"      -> JSON_C_TAG          (tag git amont, ex. json-c-0.19-20260627)
    "c-icap"          -> C_ICAP_VERSION        (- et . deviennent _)
    "alpine"          -> aucun ARG : c'est le tag des lignes `FROM alpine:<tag>@sha256:`
                         (la base est epinglee par digest, un ARG n'y changerait rien)
    "php"             -> aucun ARG si le Dockerfile a un `FROM php:<tag>@sha256:` : c'est
                         la BRANCHE de cette image de base (8.5), que le tag doit suivre
                         (8.5.11-fpm-alpine). Cle d'image de base = nom d'une image
                         d'un FROM ; alpine est le cas particulier ou le tag doit etre
                         la valeur exacte.

Usage :
    versions-build-args.py              lignes NOM=valeur (build-args de la CI)
    versions-build-args.py --docker     --build-arg NOM=valeur ... (Makefile)
    versions-build-args.py --check      controle du depot (voir check())

Aucune dependance hors stdlib.
"""
import json
import re
import shlex
import sys
from pathlib import Path

# `_VER` aussi : nginx portait NGINX_VER="" (vide = resolution de la derniere
# version amont au build), invisible tant que seul `_VERSION` etait reconnu.
# `_TAG` : bind9 ecrivait JSONC_TAG=json-c-0.19-20260627 en dur, une version
# que rien ne comparait a versions.json.
VERSION_ARG = re.compile(r"^[A-Z][A-Z0-9_]*_(VERSION|VER|SHA256|COMMIT|TAG)$")
# Une etape produit les build-args si elle appelle ce script, ou l'action
# composite de jbsky/hardened-ci qui l'enveloppe.
GENERATORS = ("versions-build-args.py", "jbsky/hardened-ci/versions@")
SPECIAL_KEYS = {"alpine"}


def key_to_arg(key):
    """Nom d'ARG attendu pour une cle de versions.json (None pour une cle speciale)."""
    if key in SPECIAL_KEYS:
        return None
    name = re.sub(r"[-.]", "_", key).upper()
    if name.endswith(("_SHA256", "_COMMIT", "_TAG")):
        return name
    return name + "_VERSION"


def load_versions(path):
    """versions.json -> dict ; refuse une valeur absente, nulle ou vide."""
    try:
        data = json.loads(Path(path).read_text())
    except (OSError, ValueError) as exc:
        raise SystemExit(f"versions-build-args: {path} illisible : {exc}")
    if not isinstance(data, dict) or not data:
        raise SystemExit(f"versions-build-args: {path} doit etre un objet non vide")
    for key, value in data.items():
        if not isinstance(value, str) or not value.strip():
            raise SystemExit(f"versions-build-args: {path} : .{key} vide, nul ou non textuel ({value!r})")
    return data


def build_args(versions, base_keys=()):
    """[(ARG, valeur)] dans l'ordre de versions.json, cles speciales et cles
    d'image de base exclues (elles ne nourrissent aucun ARG)."""
    return [(key_to_arg(k), v) for k, v in versions.items()
            if key_to_arg(k) and k not in base_keys]


def image_name(ref):
    """Nom court d'une reference d'image : docker.io/library/php:8.5@sha256:... -> php."""
    name = ref.split("@", 1)[0]
    head, _, last = name.rpartition("/")
    name = (head + "/" if head else "") + last.split(":", 1)[0]
    for prefix in ("docker.io/library/", "docker.io/", "library/"):
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


def base_image_keys(versions, froms):
    """Cles de versions.json qui nomment une image de base d'un FROM (hors alpine)."""
    used = {image_name(ref) for _, ref in froms}
    return {k for k in versions if k not in SPECIAL_KEYS and k in used}


# --------------------------------------------------------------------------
#  Lecture du Dockerfile
# --------------------------------------------------------------------------
def logical_lines(text):
    """(numero de la 1re ligne, ligne logique) : continuations `\\` jointes,
    commentaires et lignes vides ignores."""
    out, buf, start = [], [], None
    for n, raw in enumerate(text.splitlines(), 1):
        stripped = raw.strip()
        if not buf and (not stripped or stripped.startswith("#")):
            continue
        if buf and stripped.startswith("#"):
            continue  # commentaire au milieu d'une instruction continuee
        if start is None:
            start = n
        if raw.rstrip().endswith("\\"):
            buf.append(raw.rstrip()[:-1])
            continue
        buf.append(raw)
        out.append((start, " ".join(s.strip() for s in buf)))
        buf, start = [], None
    if buf:
        out.append((start, " ".join(s.strip() for s in buf)))
    return out


def parse_dockerfile(text):
    """-> (args, from_lines)
    args       : [(ligne, NOM, valeur_par_defaut_ou_None)]
    from_lines : [(ligne, reference_d_image)]"""
    args, froms = [], []
    for n, line in logical_lines(text):
        instr, _, rest = line.partition(" ")
        instr = instr.upper()
        if instr == "ARG":
            for tok in shlex.split(rest, comments=True):
                name, eq, value = tok.partition("=")
                args.append((n, name, value if eq else None))
        elif instr == "FROM":
            toks = [t for t in rest.split() if not t.startswith("--")]
            if toks:
                froms.append((n, toks[0]))
    return args, froms


def has_guard(text, name):
    """Un garde qui fait echouer le build tot si l'ARG est vide :
    `test -n "${NOM}"`, `[ -n "$NOM" ]` ou `${NOM:?...}`."""
    pat = (rf'-n\s+"?\$\{{?{name}\}}?"?'
           rf'|\$\{{{name}:\?')
    return re.search(pat, text) is not None


# --------------------------------------------------------------------------
#  Lecture du workflow (texte : pas de PyYAML, comme les autres scripts)
# --------------------------------------------------------------------------
def workflow_jobs(text):
    """{job: [lignes]} pour les jobs sous `jobs:` (indentation 2)."""
    jobs, current, in_jobs = {}, None, False
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", line):
            in_jobs = False
        if not in_jobs:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            current = m.group(1)
            jobs[current] = []
        elif current:
            jobs[current].append(line)
    return jobs


def steps_of(lines):
    """Decoupe le bloc `steps:` d'un job en etapes (`- ` a l'indentation des steps).

    Seul le bloc `steps:` compte : une `strategy.matrix` declaree avant (liste
    `- name: ...`) etait prise pour les etapes, et les vraies etapes du job
    n'etaient plus examinees -- un build sans build-args passait en vert
    (job build-dockerfile de squid-hardened, 2026-10-03)."""
    start = None
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)steps:\s*$", line)
        if m:
            start, base = i + 1, len(m.group(1))
            break
    if start is None:
        return []
    block = []
    for line in lines[start:]:
        if line.strip() and not line.lstrip().startswith("#") and len(line) - len(line.lstrip()) <= base \
                and not line.lstrip().startswith("- "):
            break  # fin du bloc steps: (cle suivante du job)
        block.append(line)
    steps, cur, indent = [], None, None
    for line in block:
        m = re.match(r"^(\s*)- ", line)
        if m and (indent is None or len(m.group(1)) == indent):
            if indent is None:
                # la premiere puce rencontree apres `steps:` fixe l'indentation
                indent = len(m.group(1))
            if cur is not None:
                steps.append(cur)
            cur = [line]
        elif cur is not None:
            if line.strip() and len(line) - len(line.lstrip()) <= (indent or 0) and not line.lstrip().startswith("- "):
                steps.append(cur)
                cur = None
            else:
                cur.append(line)
    if cur is not None:
        steps.append(cur)
    return steps


def check_workflow(text, label):
    """Chaque etape docker/build-push-action recoit les build-args generes,
    produits dans le meme job par une etape qui appelle ce script."""
    errors = []
    for job, lines in workflow_jobs(text).items():
        block = "\n".join(lines)
        if "docker/build-push-action@" not in block:
            continue
        gen_ids = set()
        for step in steps_of(lines):
            s = "\n".join(step)
            if any(g in s for g in GENERATORS):
                m = re.search(r"^\s*(?:- )?id:\s*([A-Za-z0-9_-]+)", s, re.M)
                if m:
                    gen_ids.add(m.group(1))
        for step in steps_of(lines):
            s = "\n".join(step)
            if "docker/build-push-action@" not in s:
                continue
            name = re.search(r"name:\s*(.+)", s)
            name = name.group(1).strip() if name else "(sans nom)"
            m = re.search(r"build-args:\s*\$\{\{\s*steps\.([A-Za-z0-9_-]+)\.outputs\.build-args\s*\}\}", s)
            if not m:
                errors.append(f"{label} : job {job}, etape « {name} » : build-args ne vient pas de "
                              f"versions-build-args.py (attendu : build-args: ${{{{ steps.<id>.outputs.build-args }}}})")
            elif m.group(1) not in gen_ids:
                errors.append(f"{label} : job {job}, etape « {name} » : steps.{m.group(1)} n'appelle pas "
                              f"versions-build-args.py (ni jbsky/hardened-ci/versions) dans ce job")
    return errors


# --------------------------------------------------------------------------
#  Le controle
# --------------------------------------------------------------------------
ENV_LINE = re.compile(r"^\s*(?:export\s+)?([A-Z][A-Z0-9_]*_(?:VERSION|VER|SHA256|COMMIT|TAG))\s*(?::=|\?=|=|:)\s*(\S+)")


def dockerfiles(root):
    """Le Dockerfile racine ; a defaut, un Dockerfile par sous-repertoire (un
    depot qui publie plusieurs images, comme squid/ c-icap/ clamav/ partageant
    un seul versions.json)."""
    root = Path(root)
    if (root / "Dockerfile").exists():
        return [root / "Dockerfile"]
    found = sorted(root.glob("*/Dockerfile"))
    if not found:
        raise SystemExit("versions-build-args: aucun Dockerfile (ni ./Dockerfile ni */Dockerfile)")
    return found


def check(root="."):
    root = Path(root)
    errors = []
    versions = load_versions(root / "versions.json")
    files = [(str(p.relative_to(root)), p.read_text()) for p in dockerfiles(root)]
    parsed = [(label, text, *parse_dockerfile(text)) for label, text in files]
    all_froms = [f for _, _, _, froms in parsed for f in froms]
    base_keys = base_image_keys(versions, all_froms)
    expected = {key_to_arg(k): k for k in versions if key_to_arg(k) and k not in base_keys}
    declared = {}
    for label, text, args, froms in parsed:
        seen = set()
        for n, name, default in args:
            if not VERSION_ARG.match(name):
                continue
            first = name not in seen
            seen.add(name)
            declared.setdefault(name, (label, n))
            if default is not None:
                errors.append(f"{label}:{n} : ARG {name}={default} -- valeur par defaut interdite, "
                              f"la version vient de versions.json")
            if not first:
                continue  # ARG redeclare dans un stage : l'absence de cle est deja signalee
            if name == "ALPINE_VERSION":
                errors.append(f"{label}:{n} : ARG ALPINE_VERSION ne pilote rien (la base est epinglee "
                              f"tag@sha256 sur les FROM, verifies contre .alpine) : le supprimer")
            elif name not in expected:
                errors.append(f"{label}:{n} : ARG {name} sans cle dans versions.json "
                              f"(une version ne s'ecrit que dans versions.json)")
            elif not has_guard(text, name):
                # Le garde se cherche dans le Dockerfile qui consomme l'ARG.
                errors.append(f"{label} : ARG {name} sans garde (test -n \"${{{name}}}\" ou ${{{name}:?}}) : "
                              f"un build sans build-arg doit echouer tot, pas construire avec une valeur vide")
    where = "du Dockerfile" if len(files) == 1 else "d'aucun Dockerfile (" + ", ".join(l for l, _ in files) + ")"
    for arg, key in expected.items():
        if arg not in declared:
            errors.append(f"versions.json : .{key} n'alimente aucun ARG {arg} {where} (cle morte)")

    alpine = versions.get("alpine")
    alpine_froms = [(label, n, ref) for label, _, _, froms in parsed for n, ref in froms if ref.startswith("alpine:")]
    for label, n, ref in alpine_froms:
        m = re.match(r"^alpine:([^@]+)@sha256:[0-9a-f]{64}$", ref)
        if not m:
            errors.append(f"{label}:{n} : FROM {ref} -- alpine doit etre epinglee tag@sha256")
        elif alpine is None:
            errors.append(f"{label}:{n} : FROM {ref} mais versions.json n'a pas de cle .alpine")
        elif m.group(1) != alpine:
            errors.append(f"{label}:{n} : FROM alpine:{m.group(1)} mais versions.json dit .alpine = {alpine}")
    if alpine is not None and not alpine_froms:
        errors.append("versions.json : .alpine mais aucune ligne FROM alpine:<tag>@sha256 (cle morte)")

    # Image de base suivie par branche : `"php": "8.5"` exige que chaque
    # FROM php: soit epingle par digest ET dans la branche 8.5 (8.5.11-fpm-alpine).
    # Un FROM passe en 8.6 pendant que version-watch suit 8.5 serait une 2e source.
    for key in sorted(base_keys):
        branch = versions[key]
        for label, _, _, froms in parsed:
            for n, ref in froms:
                if image_name(ref) != key:
                    continue
                m = re.match(r"^[^@]+:([^@:]+)@sha256:[0-9a-f]{64}$", ref)
                if not m:
                    errors.append(f"{label}:{n} : FROM {ref} -- l'image de base .{key} doit etre epinglee tag@sha256")
                elif not (m.group(1) == branch or m.group(1).startswith((branch + ".", branch + "-"))):
                    errors.append(f"{label}:{n} : FROM {key}:{m.group(1)} hors de la branche "
                                  f".{key} = {branch} de versions.json")

    wf = root / ".github/workflows/build-push.yml"
    if wf.exists():
        errors += check_workflow(wf.read_text(), str(wf.relative_to(root)))

    # Copies a cote : un NOM_VERSION=valeur hors de versions.json est une 2e source.
    for rel in (".env.example", ".env.sample", "docker-compose.yml", "compose.yml", "Makefile"):
        p = root / rel
        if not p.exists():
            continue
        for n, line in enumerate(p.read_text().splitlines(), 1):
            m = ENV_LINE.match(line)
            if m and not m.group(2).startswith(("$", "${")):
                errors.append(f"{rel}:{n} : {m.group(1)}={m.group(2)} -- copie d'une version hors de versions.json")
    mk = root / "Makefile"
    if mk.exists() and expected and "versions-build-args.py" not in mk.read_text():
        errors.append("Makefile : le build local ne passe pas par versions-build-args.py --docker")
    return errors


def main(argv):
    if argv[1:] == ["--check"]:
        errors = check()
        for e in errors:
            print(f"::error::{e}" if "GITHUB_ACTIONS" in __import__("os").environ else e)
        if errors:
            print(f"versions-build-args: {len(errors)} ecart(s) avec la source unique", file=sys.stderr)
            return 1
        print("versions-build-args: versions.json est la seule source des versions du build")
        return 0
    versions = load_versions("versions.json")
    froms = [f for p in dockerfiles(".") for f in parse_dockerfile(p.read_text())[1]]
    base = base_image_keys(versions, froms)
    pairs = build_args(versions, base)
    if argv[1:] == ["--docker"]:
        print(" ".join(shlex.quote(f"--build-arg={a}={v}") for a, v in pairs))
    elif len(argv) == 1:
        for a, v in pairs:
            print(f"{a}={v}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
