#!/usr/bin/env python3
"""Tests de versions-build-args.py : chaque regle doit attraper SA derive.

Un controle qui passe sur le depot ne prouve rien tant qu'on n'a pas vu qu'il
echoue sur le defaut qu'il pretend empecher. Chaque test part d'un depot
minimal conforme et y injecte un seul defaut.

    python3 -m unittest discover -s scripts -p 'test_versions_build_args.py' -v
"""
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "vba", Path(__file__).with_name("versions-build-args.py"))
vba = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vba)

DIGEST = "sha256:" + "a" * 64

VERSIONS = {"app": "1.2.3", "app_sha256": "f" * 64, "tcc_commit": "abc123", "alpine": "3.24"}

DOCKERFILE = f"""\
ARG APP_VERSION

FROM alpine:3.24@{DIGEST} AS builder
ARG APP_VERSION
ARG APP_SHA256 \\
    TCC_COMMIT
ARG OISF_FPR=B36FDAF2607E10E8FFA89E5E2BA9C98CCDF1E93A
RUN test -n "${{APP_VERSION}}" -a -n "${{APP_SHA256}}" -a -n "${{TCC_COMMIT}}" || exit 1

FROM alpine:3.24@{DIGEST} AS prep
FROM scratch
"""

WORKFLOW = """\
name: build-push
on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: ./scripts/versions-build-args.py --check
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - name: Build-args from versions.json
        id: build-args
        run: |
          { echo 'build-args<<EOF'; ./scripts/versions-build-args.py; echo 'EOF'; } >> "$GITHUB_OUTPUT"
      - name: Build
        uses: docker/build-push-action@v7
        with:
          context: .
          build-args: ${{ steps.build-args.outputs.build-args }}
      - name: Build prep stage
        uses: docker/build-push-action@v7
        with:
          target: prep
          build-args: ${{ steps.build-args.outputs.build-args }}
"""

MAKEFILE = "build:\n\tdocker compose build $(shell ./scripts/versions-build-args.py --docker) app\n"

COMPOSE = """\
services:
  app:
    build:
      context: .
      args:
        APP_VERSION: ${APP_VERSION:-}
"""


class Repo:
    """Depot jetable : fichiers conformes, a modifier un par un."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.write("versions.json", json.dumps(VERSIONS, indent=2))
        self.write("Dockerfile", DOCKERFILE)
        self.write(".github/workflows/build-push.yml", WORKFLOW)
        self.write("Makefile", MAKEFILE)
        self.write("docker-compose.yml", COMPOSE)

    def write(self, rel, text):
        p = self.root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def edit(self, rel, old, new):
        p = self.root / rel
        text = p.read_text()
        assert old in text, f"fixture : {old!r} absent de {rel}"
        p.write_text(text.replace(old, new, 1))

    def errors(self):
        return vba.check(self.root)

    def close(self):
        self.tmp.cleanup()


class CheckTest(unittest.TestCase):
    def setUp(self):
        self.repo = Repo()

    def tearDown(self):
        self.repo.close()

    def assertCaught(self, needle):
        errors = self.repo.errors()
        self.assertTrue(any(needle in e for e in errors),
                        f"attendu une erreur contenant {needle!r}, obtenu : {errors}")

    def test_depot_conforme_passe(self):
        self.assertEqual(self.repo.errors(), [])

    # --- Dockerfile -------------------------------------------------------
    def test_valeur_par_defaut_globale(self):
        self.repo.edit("Dockerfile", "ARG APP_VERSION\n\nFROM", "ARG APP_VERSION=1.2.3\n\nFROM")
        self.assertCaught("ARG APP_VERSION=1.2.3 -- valeur par defaut interdite")

    def test_valeur_par_defaut_dans_un_stage_et_ligne_continuee(self):
        self.repo.edit("Dockerfile", "    TCC_COMMIT\n", "    TCC_COMMIT=abc123\n")
        self.assertCaught("ARG TCC_COMMIT=abc123 -- valeur par defaut interdite")

    def test_suffixe_tag_reconnu(self):
        # Cas bind9 : ARG JSONC_TAG=json-c-0.19-20260627, version ecrite en dur.
        self.repo.edit("Dockerfile", "ARG OISF_FPR", "ARG JSONC_TAG=json-c-0.19-20260627\nARG OISF_FPR")
        self.assertCaught("ARG JSONC_TAG=json-c-0.19-20260627 -- valeur par defaut interdite")
        self.assertCaught("ARG JSONC_TAG sans cle dans versions.json")

    def test_suffixe_ver_vide_reconnu(self):
        # Cas nginx : ARG NGINX_VER="" et resolution amont quand il est vide.
        self.repo.edit("Dockerfile", "ARG OISF_FPR", 'ARG NGINX_VER=""\nARG OISF_FPR')
        self.assertCaught('ARG NGINX_VER= -- valeur par defaut interdite')
        self.assertCaught("ARG NGINX_VER sans cle dans versions.json")

    def test_copie_suffixe_ver_dans_makefile(self):
        self.repo.write("Makefile", "NGINX_VER := 1.30.5\n" + MAKEFILE)
        self.assertCaught("Makefile:1 : NGINX_VER=1.30.5 -- copie")

    def test_version_hors_versions_json(self):
        self.repo.edit("Dockerfile", "ARG OISF_FPR", "ARG LIBFOO_VERSION\nARG OISF_FPR")
        self.assertCaught("ARG LIBFOO_VERSION sans cle dans versions.json")

    def test_cle_morte(self):
        v = dict(VERSIONS, jemalloc="5.3.1")
        self.repo.write("versions.json", json.dumps(v))
        self.assertCaught(".jemalloc n'alimente aucun ARG JEMALLOC_VERSION")

    def test_garde_absent(self):
        self.repo.edit("Dockerfile", ' -a -n "${TCC_COMMIT}"', "")
        self.assertCaught("ARG TCC_COMMIT sans garde")

    def test_arg_alpine_version_refuse(self):
        self.repo.edit("Dockerfile", "ARG APP_VERSION\n\nFROM", "ARG APP_VERSION\nARG ALPINE_VERSION\n\nFROM")
        self.assertCaught("ARG ALPINE_VERSION ne pilote rien")

    def test_tag_alpine_different_de_versions_json(self):
        self.repo.edit("Dockerfile", f"alpine:3.24@{DIGEST} AS prep", f"alpine:3.23@{DIGEST} AS prep")
        self.assertCaught("FROM alpine:3.23 mais versions.json dit .alpine = 3.24")

    def test_alpine_sans_digest(self):
        self.repo.edit("Dockerfile", f"alpine:3.24@{DIGEST} AS prep", "alpine:3.24 AS prep")
        self.assertCaught("alpine doit etre epinglee tag@sha256")

    # --- image de base suivie par branche (php : "php": "8.5") ------------
    def _image_de_base(self, from_ref):
        v = dict(VERSIONS, php="8.5")
        self.repo.write("versions.json", json.dumps(v))
        self.repo.edit("Dockerfile", f"FROM alpine:3.24@{DIGEST} AS builder",
                       f"FROM {from_ref} AS phpbase\nFROM alpine:3.24@{DIGEST} AS builder")

    def test_image_de_base_dans_la_branche_passe(self):
        self._image_de_base(f"php:8.5.11-fpm-alpine@{DIGEST}")
        self.assertEqual(self.repo.errors(), [])

    def test_image_de_base_hors_branche(self):
        self._image_de_base(f"php:8.6.0-fpm-alpine@{DIGEST}")
        self.assertCaught("FROM php:8.6.0-fpm-alpine hors de la branche .php = 8.5")

    def test_image_de_base_prefixe_trompeur(self):
        # 8.50 n'est pas dans la branche 8.5 : la branche se termine par . ou -
        self._image_de_base(f"php:8.50.1-fpm-alpine@{DIGEST}")
        self.assertCaught("hors de la branche .php = 8.5")

    def test_image_de_base_sans_digest(self):
        self._image_de_base("php:8.5.11-fpm-alpine")
        self.assertCaught("l'image de base .php doit etre epinglee tag@sha256")

    def test_cle_sans_image_de_base_reste_morte(self):
        # Sans FROM php:, la cle php redevient une version qui doit nourrir PHP_VERSION.
        v = dict(VERSIONS, php="8.5")
        self.repo.write("versions.json", json.dumps(v))
        self.assertCaught(".php n'alimente aucun ARG PHP_VERSION")

    def test_ancre_de_confiance_non_concernee(self):
        # OISF_FPR (empreinte de cle) n'est pas une version : sa valeur en dur est voulue.
        self.assertFalse(any("OISF_FPR" in e for e in self.repo.errors()))

    # --- Workflow ---------------------------------------------------------
    def test_build_sans_build_args(self):
        self.repo.edit(".github/workflows/build-push.yml",
                       "          context: .\n          build-args: ${{ steps.build-args.outputs.build-args }}\n",
                       "          context: .\n")
        self.assertCaught("etape « Build » : build-args ne vient pas de versions-build-args.py")

    def test_stage_prep_sans_build_args(self):
        self.repo.edit(".github/workflows/build-push.yml",
                       "          target: prep\n          build-args: ${{ steps.build-args.outputs.build-args }}\n",
                       "          target: prep\n          build-args: |\n            APP_VERSION=1.2.3\n")
        self.assertCaught("etape « Build prep stage » : build-args ne vient pas de versions-build-args.py")

    def test_matrice_avant_les_steps(self):
        # Une strategy.matrix (liste de `- name:`) avant `steps:` ne doit pas
        # masquer les vraies etapes du job.
        self.repo.write(".github/workflows/build-push.yml", WORKFLOW + """  build-arm64:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        image:
          - name: app
            context: app/
    steps:
      - uses: actions/checkout@v7
      - name: Build arm64
        uses: docker/build-push-action@v7
        with:
          context: ${{ matrix.image.context }}
""")
        self.assertCaught("job build-arm64, etape « Build arm64 » : build-args ne vient pas de versions-build-args.py")

    def test_generateur_absent_du_job(self):
        self.repo.edit(".github/workflows/build-push.yml",
                       "{ echo 'build-args<<EOF'; ./scripts/versions-build-args.py; echo 'EOF'; }",
                       "{ echo 'build-args<<EOF'; jq -r . versions.json; echo 'EOF'; }")
        self.assertCaught("steps.build-args n'appelle pas versions-build-args.py (ni jbsky/hardened-ci/versions) dans ce job")

    def test_action_composite_reconnue_comme_generateur(self):
        self.repo.edit(".github/workflows/build-push.yml",
                       """        run: |
          { echo 'build-args<<EOF'; ./scripts/versions-build-args.py; echo 'EOF'; } >> "$GITHUB_OUTPUT"
""",
                       "        uses: jbsky/hardened-ci/versions@0123456789abcdef0123456789abcdef01234567 # v1.0.0\n")
        self.assertEqual(self.repo.errors(), [])

    # --- Copies a cote ----------------------------------------------------
    def test_copie_dans_env_example(self):
        self.repo.write(".env.example", "SURICATA_VERSION=8.0.2\n")
        self.assertCaught(".env.example:1 : SURICATA_VERSION=8.0.2 -- copie")

    def test_copie_dans_compose(self):
        self.repo.edit("docker-compose.yml", "${APP_VERSION:-}", "1.2.3")
        self.assertCaught("docker-compose.yml:6 : APP_VERSION=1.2.3 -- copie")

    def test_copie_dans_makefile(self):
        self.repo.write("Makefile", "APP_VERSION := 1.2.3\n" + MAKEFILE)
        self.assertCaught("Makefile:1 : APP_VERSION=1.2.3 -- copie")

    def test_makefile_sans_generateur(self):
        self.repo.write("Makefile", "build:\n\tdocker compose build app\n")
        self.assertCaught("Makefile : le build local ne passe pas par versions-build-args.py")


MULTI_VERSIONS = {"squid": "7.7", "c-icap": "0.6.5", "c-icap_sha256": "e" * 64, "alpine": "3.24"}


def multi_dockerfile(args):
    """Dockerfile d'une image du depot multi-images : ses ARG + leur garde."""
    decl = "".join(f"ARG {a}\n" for a in args)
    guard = " -a ".join(f'-n "${{{a}}}"' for a in args)
    return f"FROM alpine:3.24@{DIGEST} AS builder\n{decl}RUN test {guard} || exit 1\nFROM scratch\n"


MULTI_WORKFLOW = WORKFLOW.replace("          context: .\n", "          context: ${{ matrix.image }}/\n")


class MultiDockerfileTest(unittest.TestCase):
    """Un depot qui publie plusieurs images (squid/ c-icap/) avec un seul versions.json."""

    def setUp(self):
        self.repo = Repo()
        (self.repo.root / "Dockerfile").unlink()
        self.repo.write("versions.json", json.dumps(MULTI_VERSIONS))
        self.repo.write("squid/Dockerfile", multi_dockerfile(["SQUID_VERSION"]))
        self.repo.write("c-icap/Dockerfile", multi_dockerfile(["C_ICAP_VERSION", "C_ICAP_SHA256"]))
        self.repo.write(".github/workflows/build-push.yml", MULTI_WORKFLOW)

    def tearDown(self):
        self.repo.close()

    def assertCaught(self, needle):
        errors = self.repo.errors()
        self.assertTrue(any(needle in e for e in errors),
                        f"attendu une erreur contenant {needle!r}, obtenu : {errors}")

    def test_depot_multi_images_conforme_passe(self):
        self.assertEqual(self.repo.errors(), [])

    def test_valeur_par_defaut_dans_un_sous_dockerfile(self):
        self.repo.edit("squid/Dockerfile", "ARG SQUID_VERSION\n", "ARG SQUID_VERSION=7.7\n")
        self.assertCaught("squid/Dockerfile:2 : ARG SQUID_VERSION=7.7 -- valeur par defaut interdite")

    def test_cle_consommee_par_aucun_dockerfile(self):
        self.repo.write("versions.json", json.dumps(dict(MULTI_VERSIONS, clamav="1.5.4")))
        self.assertCaught(".clamav n'alimente aucun ARG CLAMAV_VERSION d'aucun Dockerfile")

    def test_garde_cherche_dans_le_dockerfile_qui_consomme(self):
        # Le garde de SQUID_VERSION present dans c-icap/ ne couvre pas squid/.
        self.repo.write("squid/Dockerfile", f"FROM alpine:3.24@{DIGEST}\nARG SQUID_VERSION\nFROM scratch\n")
        self.repo.edit("c-icap/Dockerfile", "|| exit 1", '-a -n "${SQUID_VERSION}" || exit 1')
        self.assertCaught("squid/Dockerfile : ARG SQUID_VERSION sans garde")

    def test_tag_alpine_d_un_sous_dockerfile(self):
        self.repo.edit("c-icap/Dockerfile", "alpine:3.24@", "alpine:3.23@")
        self.assertCaught("c-icap/Dockerfile:1 : FROM alpine:3.23 mais versions.json dit .alpine = 3.24")

    def test_aucun_dockerfile(self):
        (self.repo.root / "squid/Dockerfile").unlink()
        (self.repo.root / "c-icap/Dockerfile").unlink()
        with self.assertRaises(SystemExit):
            self.repo.errors()


class GenerateurTest(unittest.TestCase):
    def test_convention_de_nommage(self):
        self.assertEqual(vba.key_to_arg("suricata"), "SURICATA_VERSION")
        self.assertEqual(vba.key_to_arg("libhtp_sha256"), "LIBHTP_SHA256")
        self.assertEqual(vba.key_to_arg("tcc_commit"), "TCC_COMMIT")
        self.assertEqual(vba.key_to_arg("json-c_tag"), "JSON_C_TAG")
        self.assertEqual(vba.key_to_arg("c-icap"), "C_ICAP_VERSION")
        self.assertEqual(vba.key_to_arg("uptime-kuma"), "UPTIME_KUMA_VERSION")
        self.assertIsNone(vba.key_to_arg("alpine"))

    def test_build_args_sans_alpine(self):
        self.assertEqual(vba.build_args(VERSIONS), [
            ("APP_VERSION", "1.2.3"), ("APP_SHA256", "f" * 64), ("TCC_COMMIT", "abc123")])

    def test_build_args_sans_cle_d_image_de_base(self):
        v = dict(VERSIONS, php="8.5")
        self.assertEqual(vba.build_args(v, {"php"}), vba.build_args(VERSIONS))

    def test_nom_d_image(self):
        for ref, name in ((f"php:8.5.11-fpm-alpine@{DIGEST}", "php"),
                          (f"docker.io/library/php:8.5@{DIGEST}", "php"),
                          ("ghcr.io/jbsky/foo:1.0", "ghcr.io/jbsky/foo"),
                          ("localhost:5000/foo:1", "localhost:5000/foo"),
                          ("scratch", "scratch")):
            with self.subTest(ref=ref):
                self.assertEqual(vba.image_name(ref), name)

    def _load(self, data):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "versions.json"
            p.write_text(json.dumps(data))
            return vba.load_versions(p)

    def test_valeur_vide_nulle_ou_non_textuelle_refusee(self):
        for bad in ("", "  ", None, 8):
            with self.subTest(valeur=bad), self.assertRaises(SystemExit):
                self._load({"app": bad})

    def test_versions_json_vide_refuse(self):
        with self.assertRaises(SystemExit):
            self._load({})


if __name__ == "__main__":
    unittest.main()
