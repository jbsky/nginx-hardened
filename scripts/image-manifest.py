#!/usr/bin/env python3
"""image-manifest.py -- inventaire verifiable du contenu d'une image durcie.

Pourquoi : rien dans la chaine ne regarde ce qui SORT de l'image.
`audit-hardened-images.sh` greppe le Dockerfile (il verifie qu'une ligne
existe, pas qu'elle a marche), `check-image-closure.sh` ne voit que les
bibliotheques manquantes, Trivy et Grype ne parlent que de paquets -- et dans
une image FROM scratch il n'y en a plus.

Methode : une seule passe en flux sur `docker export`. Pas d'extraction, pas de
conteneur jetable, pas de root, aucune dependance hors stdlib -- les xattr
voyagent dans les en-tetes PAX (SCHILY.xattr.*) que tarfile expose deja.

    image-manifest.py --generate <image> [-o image.manifest]
    image-manifest.py --check    <image> [-m image.manifest]

Le manifeste est commite. Toute derive echoue le job ; sa mise a jour est un
diff relu dans la PR qui la provoque.

AUCUN HASH N'EST STOCKE. La version est deja dans le nom (libz.so.1.3.2), et
la ou le chemin est stable (/usr/local/bin/init) le contenu change a chaque
build -- build-revision.sh y injecte une revision. Un manifeste hashe
produirait un diff a chaque reconstruction, sur des lignes que personne ne peut
evaluer, et finirait regenere sans etre lu : c'est le piege deja paye sur la
regle Grype de PHP epinglee a `version: 8.5.8`. Le sha256 est calcule a la
volee, en memoire, UNIQUEMENT pour trouver deux chemins de meme contenu.
"""

import argparse
import hashlib
import re
import subprocess
import sys
import tarfile

VERSION = "image-manifest v2"

# Repertoires dont chaque entree est listee nominativement, quel que soit son type.
BIN_DIRS = ("bin/", "sbin/", "usr/bin/", "usr/sbin/", "usr/local/bin/", "usr/local/sbin/")

# Seuil de taille pour signaler un doublon : en dessous, c'est du bruit.
DUP_MIN_SIZE = 1024

# Interdits absolus : echec meme si le manifeste les declare.
FORBIDDEN = ("sbin/apk", "usr/bin/apk", "lib/apk/", "libapk.so")

# Injecte par le daemon au `docker create`, pas par le build : ces entrees
# appartiennent au CONTENEUR, pas a l'image. Les inventorier ferait echouer la
# CI sur une difference de version de Docker ou de configuration reseau du
# runner -- un faux positif que personne ne saurait interpreter.
INJECTE = ("etc/hostname", "etc/hosts", "etc/resolv.conf", "etc/mtab", "dev/")

# capability(7) -- seuls les noms utiles a cette flotte sont mappes, le reste
# sort en numero pour rester lisible sans table exhaustive.
CAP_NAMES = {
    0: "chown", 1: "dac_override", 2: "dac_read_search", 3: "fowner", 4: "fsetid",
    5: "kill", 6: "setgid", 7: "setuid", 8: "setpcap", 9: "linux_immutable",
    10: "net_bind_service", 11: "net_broadcast", 12: "net_admin", 13: "net_raw",
    14: "ipc_lock", 17: "sys_chroot", 18: "sys_ptrace", 19: "sys_pacct",
    21: "sys_admin", 22: "sys_boot", 23: "sys_nice", 24: "sys_resource",
    25: "sys_time", 27: "mknod", 28: "lease", 29: "audit_write", 36: "bpf",
    38: "checkpoint_restore",
}


def decode_caps(raw):
    """Decode un xattr security.capability (format VFS_CAP_REVISION_2/3)."""
    if len(raw) < 12:
        return ""
    magic = int.from_bytes(raw[0:4], "little")
    revision = magic & 0xFF000000
    permitted = int.from_bytes(raw[4:8], "little")
    if revision >= 0x02000000 and len(raw) >= 20:
        permitted |= int.from_bytes(raw[12:16], "little") << 32
    noms = []
    for bit in range(64):
        if permitted & (1 << bit):
            noms.append("cap_" + CAP_NAMES.get(bit, str(bit)))
    return ",".join(noms)


def scan(image):
    """Une passe sur `docker export`. Rend (entrees, doublons, alertes)."""
    r = subprocess.run(["docker", "create", image], capture_output=True, text=True)
    if r.returncode != 0:
        # En CI, une reference d'image fausse doit se lire dans le log, pas se
        # deviner dans une trace Python.
        sys.exit(f"ERREUR : `docker create {image}` a echoue -- "
                 f"{r.stderr.strip().splitlines()[-1] if r.stderr.strip() else 'sans message'}")
    cid = r.stdout.strip()
    entrees, par_hash, alertes = [], {}, []
    try:
        proc = subprocess.Popen(["docker", "export", cid], stdout=subprocess.PIPE)
        with tarfile.open(fileobj=proc.stdout, mode="r|*") as tar:
            for m in tar:
                nom = m.name.lstrip("./")
                if not nom or nom in INJECTE or nom.startswith("dev/"):
                    continue

                if any(f in nom for f in FORBIDDEN):
                    alertes.append(f"gestionnaire de paquets present : {nom}")
                if m.mode & 0o4000:
                    alertes.append(f"setuid : {nom} (mode {m.mode:04o})")
                if m.mode & 0o2000:
                    alertes.append(f"setgid : {nom} (mode {m.mode:04o})")
                if m.isreg() and m.mode & 0o002:
                    alertes.append(f"accessible en ecriture a tous : {nom} (mode {m.mode:04o})")

                brut = m.pax_headers.get("SCHILY.xattr.security.capability")
                caps = decode_caps(brut.encode("utf-8", "surrogateescape")) if brut else ""

                elf = False
                if m.isreg() and m.size >= 4:
                    f = tar.extractfile(m)
                    if f is not None:
                        h = hashlib.sha256()
                        tete = f.read(4)
                        elf = tete == b"\x7fELF"
                        h.update(tete)
                        while True:
                            bloc = f.read(1 << 20)
                            if not bloc:
                                break
                            h.update(bloc)
                        if m.size >= DUP_MIN_SIZE:
                            par_hash.setdefault(h.hexdigest(), []).append((nom, m.size))

                entrees.append({
                    "nom": nom, "mode": m.mode, "uid": m.uid, "gid": m.gid,
                    "type": "l" if m.issym() else "d" if m.isdir() else "f",
                    "cible": m.linkname if m.issym() else "",
                    "elf": elf, "caps": caps, "reg": m.isreg(),
                })
        proc.stdout.close()
        proc.wait()
    finally:
        subprocess.run(["docker", "rm", "-f", cid],
                       capture_output=True, check=False)

    doublons = sorted((sorted(p for p, _ in v), v[0][1])
                      for v in par_hash.values() if len(v) > 1)
    return entrees, doublons, alertes


def nommee(e):
    """Cette entree merite-t-elle une ligne a elle seule ?"""
    n = e["nom"]
    return (e["elf"] or n.endswith(".so") or ".so." in n
            or n.startswith(BIN_DIRS) or e["caps"]
            or (n.startswith("etc/") and e["reg"] and not n.startswith("etc/ssl/certs/")))


def sous_arbres(entrees, listees):
    """Sous-arbres maximaux ne contenant aucune entree listee nominativement.

    Deterministe et stable : un repertoire s'effondre en une ligne `count` si et
    seulement si RIEN dedans n'est liste. Ajouter un fichier dans zoneinfo
    change un nombre, pas la structure du manifeste.
    """
    prefixes = set()
    for e in entrees:
        parts = e["nom"].split("/")
        for i in range(1, len(parts)):
            prefixes.add("/".join(parts[:i]) + "/")

    bloque = set()
    for n in listees:
        parts = n.split("/")
        for i in range(1, len(parts)):
            bloque.add("/".join(parts[:i]) + "/")

    collapsables = prefixes - bloque
    maximaux = {p for p in collapsables
                if "/".join(p.rstrip("/").split("/")[:-1]) + "/" not in collapsables
                or "/" not in p.rstrip("/")}

    comptes = {}
    for e in entrees:
        if e["nom"] in listees:
            continue
        for p in maximaux:
            if e["nom"].startswith(p):
                comptes[p] = comptes.get(p, 0) + 1
                break
    return comptes


# Une release de bibliotheque : les chiffres qui suivent le soname.
RELEASE = re.compile(r"^[0-9]+(\.[0-9]+)*$")
# Un soname porteur d'ABI : libfoo.so.3, jamais libfoo.so.
SONAME = re.compile(r"\.so\.[0-9]+$")


def sonames(entrees):
    """Rend {chemin reel: chemin affiche} pour les bibliotheques versionnees.

    Une bibliotheque apk s'installe en deux temps : le soname
    (`libpcre2-8.so.0`) est un lien vers le fichier de release
    (`libpcre2-8.so.0.16.0`). Les chiffres de release bougent au rythme
    d'Alpine, et deux constructeurs peuvent lire deux index differents A LA
    MEME MINUTE -- constate le 2026-09-09, le runner de php a resolu 0.16.0
    pendant que celui de suricata resolvait 0.15.0, cache de couches desactive
    des deux cotes. Les enregistrer ferait virer la porte au rouge pour une
    raison sans rapport avec le changement relu.

    On enregistre donc le soname et le FAIT qu'une cible versionnee existe.
    Ce que le manifeste continue d'attraper : une bibliotheque apparue ou
    disparue, un mode, un uid, une capability, un doublon, et une rupture
    d'ABI -- le soname est dans le nom. Ce qu'il ne dit plus : la version.
    C'est le travail du scan CVE du stage `prep`, seul endroit de la chaine
    ou un scanner sait encore lire des paquets.

    La normalisation n'a lieu que si l'image DECLARE elle-meme le soname par
    un lien : pas de lien, pas de collapse (`libpython3.14.so.1.0` reste
    entier).
    """
    table = {}
    for e in entrees:
        if e["type"] != "l" or not e["cible"] or "/" in e["cible"]:
            continue
        base = e["nom"].rsplit("/", 1)[-1]
        rep = e["nom"][: len(e["nom"]) - len(base)]
        # Le lien doit DEJA porter le numero d'ABI (`libfoo.so.3`). Le lien
        # generique `libfoo.so -> libfoo.so.3` ne compte pas : son suffixe
        # n'est pas une release, c'est justement l'ABI qu'on veut garder.
        # Sans cette garde, la chaine a trois maillons de varnish
        # (`libvarnishapi.so` -> `.so.3` -> `.so.3.1.0`) perdait son `3`.
        if not SONAME.search(base):
            continue
        if not e["cible"].startswith(base + "."):
            continue
        if not RELEASE.match(e["cible"][len(base) + 1:]):
            continue
        table[rep + e["cible"]] = rep + base + ".<version>"
    return table


def rendre(image, entrees, doublons):
    listees = {e["nom"] for e in entrees if nommee(e)}
    table = sonames(entrees)

    def aff(chemin):
        return table.get(chemin, chemin)

    lignes = [f"# {VERSION}", f"# image : {image}",
              "# genere par scripts/image-manifest.py -- ne pas editer a la main", ""]

    rendues = []
    for e in (e for e in entrees if e["nom"] in listees):
        if e["type"] == "l":
            base = e["nom"].rsplit("/", 1)[-1]
            rep = e["nom"][: len(e["nom"]) - len(base)]
            cible = e["cible"]
            if "/" not in cible:
                cible = aff(rep + cible)[len(rep):]
            rendues.append((aff(e["nom"]), f"l {aff(e['nom'])} -> {cible}"))
        else:
            suffixe = f" caps={e['caps']}" if e["caps"] else ""
            marque = "elf" if e["elf"] else "-"
            rendues.append((aff(e["nom"]),
                            f"{e['type']} {e['mode']:04o} {e['uid']}:{e['gid']} "
                            f"{marque} {aff(e['nom'])}{suffixe}"))
    lignes.extend(l for _, l in sorted(rendues))

    comptes = sous_arbres(entrees, listees)
    if comptes:
        lignes.append("")
        for p in sorted(comptes):
            lignes.append(f"count {comptes[p]} {p}")

    if doublons:
        lignes.append("")
        for chemins, taille in sorted((sorted(aff(c) for c in ch), t)
                                      for ch, t in doublons):
            lignes.append(f"dup {len(chemins)} {taille} {' '.join(chemins)}")

    return "\n".join(lignes) + "\n"


def lire_manifeste(texte):
    """Reconstruit un inventaire depuis un manifeste ecrit. On repart du fichier
    et non de l'image : `--check` a deja prouve, dans le meme job, que les deux
    coincident. Le rapport ne coute donc ni docker ni export."""
    f, l, cnt, dup = [], [], [], []
    for ligne in texte.splitlines():
        if not ligne.strip() or ligne.startswith("#"):
            continue
        ch = ligne.split()
        if ch[0] in ("f", "d") and len(ch) >= 5:
            caps = ch[5][5:] if len(ch) > 5 and ch[5].startswith("caps=") else ""
            f.append({"mode": ch[1], "own": ch[2], "elf": ch[3] == "elf",
                      "nom": ch[4], "caps": caps})
        elif ch[0] == "l" and len(ch) >= 2:
            l.append({"nom": ch[1], "cible": ch[3] if len(ch) > 3 else ""})
        elif ch[0] == "count" and len(ch) >= 3:
            cnt.append((int(ch[1]), ch[2]))
        elif ch[0] == "dup" and len(ch) >= 4:
            dup.append((int(ch[1]), int(ch[2]), ch[3:]))
    return f, l, cnt, dup


def rapporter(nom_image, texte):
    """Rend en Markdown ce que le manifeste dit de l'image. Destine a
    $GITHUB_STEP_SUMMARY : chaque build montre ce qu'il embarque, sans qu'on ait
    a relire un diff de 150 lignes pour s'en faire une idee."""
    f, l, cnt, dup = lire_manifeste(texte)
    agrege = sum(n for n, _ in cnt)
    total = len(f) + len(l) + agrege
    elf = sum(1 for e in f if e["elf"])
    bins = sorted(e["nom"] for e in f if e["nom"].startswith(BIN_DIRS))
    caps = [(e["nom"], e["caps"]) for e in f if e["caps"]]
    non_root = [e for e in f if e["own"] != "0:0"]
    gachis = sum(t * (n - 1) for n, t, _ in dup)

    modes = {}
    for e in f:
        modes[e["mode"]] = modes.get(e["mode"], 0) + 1

    # Les deux gros blocs de donnees que presque toutes les images portent. Le
    # manifeste agrege a `usr/share/`, pas a `usr/share/zoneinfo/` : on nomme donc
    # les repertoires, pas leur contenu suppose.
    socle = sum(n for n, d in cnt if d in ("usr/share/", "etc/ssl/certs/"))

    o = [f"### Inventaire de `{nom_image}`", ""]
    lien_s = "lien" if len(l) < 2 else "liens"
    o.append(f"**{total}** chemins, dont **{len(f) + len(l)}** nommes "
             f"({len(f)} fichiers / {len(l)} {lien_s}) et **{agrege}** agreges.")
    if socle:
        o.append(f"Dont **{socle}** chemins ({100 * socle // total} %) sous `usr/share/` et "
                 f"`etc/ssl/certs/` -- des donnees, pas du code.")
    o.append("")
    o.append("| | |")
    o.append("|---|---|")
    o.append(f"| Fichiers ELF | {elf} |")
    o.append(f"| Executables | {len(bins)} |")
    o.append(f"| Modes | {', '.join(f'{m} x{n}' for m, n in sorted(modes.items()))} |")
    o.append(f"| Hors `root:root` | {len(non_root) or 'aucun'} |")
    o.append(f"| Capabilities | {', '.join(f'`{n}` {c}' for n, c in caps) or 'aucune'} |")
    o.append(f"| Doublons | {len(dup)} groupe{'s' if len(dup) > 1 else ''}, "
             f"{gachis // 1024} Kio |" if dup else "| Doublons | aucun |")
    o.append("")
    if bins:
        o.append("<details><summary>Executables embarques</summary>", )
        o.append("")
        for b in bins:
            o.append(f"- `{b}`")
        o.append("")
        o.append("</details>")
        o.append("")
    if cnt:
        o.append("<details><summary>Repertoires agreges</summary>")
        o.append("")
        for n, d in sorted(cnt, key=lambda c: -c[0]):
            o.append(f"- `{d}` : {n}")
        o.append("")
        o.append("</details>")
        o.append("")
    return "\n".join(o)


def main():
    ap = argparse.ArgumentParser(description="Inventaire verifiable d'une image durcie.")
    ap.add_argument("--generate", metavar="IMAGE")
    ap.add_argument("--check", metavar="IMAGE")
    ap.add_argument("--report", action="store_true",
                    help="rend le manifeste en Markdown (pour $GITHUB_STEP_SUMMARY)")
    ap.add_argument("--name", metavar="NOM", help="nom affiche dans le rapport")
    ap.add_argument("-o", "--output", default="-")
    ap.add_argument("-m", "--manifest", default="image.manifest")
    a = ap.parse_args()

    if a.report:
        # Le rapport se lit sur le manifeste, jamais sur l'image : aucun docker,
        # aucun export, et il reste vrai puisque --check compare les deux.
        texte = open(a.manifest, encoding="utf-8").read()
        nom = a.name
        if not nom:
            for ligne in texte.splitlines():
                if ligne.startswith("# image :"):
                    nom = ligne.split(":", 1)[1].strip()
                    break
        rendu = rapporter(nom or a.manifest, texte)
        if a.output == "-":
            sys.stdout.write(rendu + "\n")
        else:
            open(a.output, "w", encoding="utf-8").write(rendu + "\n")
        return 0

    image = a.generate or a.check
    if not image:
        ap.error("--generate, --check ou --report est obligatoire")

    entrees, doublons, alertes = scan(image)
    rendu = rendre(image, entrees, doublons)

    if a.generate:
        if a.output == "-":
            sys.stdout.write(rendu)
        else:
            open(a.output, "w", encoding="utf-8").write(rendu)
            print(f"ecrit : {a.output} ({len(rendu.splitlines())} lignes)", file=sys.stderr)
        for al in alertes:
            print(f"  [ALERTE] {al}", file=sys.stderr)
        return 1 if alertes else 0

    attendu = open(a.manifest, encoding="utf-8").read()
    # La ligne "# image :" porte le tag ou le digest teste, qui varie legitimement
    # entre un build de PR et une promotion : elle est ignoree par la comparaison.
    def sans_entete(t):
        return [l for l in t.splitlines() if not l.startswith("# image :")]

    rc = 0
    if sans_entete(attendu) != sans_entete(rendu):
        import difflib
        print(f"ECHEC -- le contenu de {image} ne correspond plus a {a.manifest}")
        for l in difflib.unified_diff(sans_entete(attendu), sans_entete(rendu),
                                      fromfile=a.manifest, tofile="image reelle",
                                      lineterm="", n=1):
            print(l)
        print("\nSi la derive est voulue, regenerer le manifeste DANS LE MEME COMMIT :")
        print(f"  scripts/image-manifest.py --generate {image} -o {a.manifest}")
        rc = 1
    else:
        print(f"OK -- {image} correspond a {a.manifest}")

    for al in alertes:
        print(f"  [ALERTE] {al}")
        rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
