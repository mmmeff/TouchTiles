"""Plan a release from main and publish its verified assets on GitHub."""

import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
from xml.etree import ElementTree as XML


INFO = Path("Resources/Info.plist")
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
SEMVER = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def run(*args):
    subprocess.run(args, check=True)


def version(value):
    match = re.fullmatch(SEMVER, value)
    if not match:
        raise SystemExit(f"Expected a three-part release version, got {value!r}")
    return tuple(map(int, match.groups()))


def next_version(previous, subjects, bodies):
    major, minor, patch = version(previous)
    if (re.search(r"#major\b|^[a-z]+(?:\([^)]+\))?!:", subjects, re.I | re.M)
            or re.search(r"^BREAKING[ -]CHANGE:", bodies, re.M)):
        return f"{major + 1}.0.0"
    if re.search(r"#minor\b|^feat(?:\([^)]+\))?:", subjects, re.I | re.M):
        return f"{major}.{minor + 1}.0"
    return f"{major}.{minor}.{patch + 1}"


def release_records():
    pages = json.loads(output("gh", "api", "--paginate", "--slurp",
                              f"repos/{os.environ['GITHUB_REPOSITORY']}/releases?per_page=100"))
    return [release for page in pages for release in page]


def plan():
    requested = os.getenv("REQUEST_TAG", "")
    automatic = os.getenv("AUTOMATIC") == "true"
    run("git", "fetch", "--quiet", "origin", "main", "--tags")
    source = output("git", "rev-parse", "HEAD")
    if requested:
        if not requested.startswith("v"):
            raise SystemExit("Release tags must use vMAJOR.MINOR.PATCH")
        version(requested[1:])
        if output("git", "rev-parse", "--verify", f"refs/tags/{requested}^{{commit}}") != source:
            raise SystemExit("The checkout differs from the requested tag")
        run("git", "merge-base", "--is-ancestor", source, "origin/main")
    elif output("git", "rev-parse", "origin/main") != source:
        if automatic:
            print("A newer main commit will run the release.")
            return
        raise SystemExit("Select main or an existing release tag")

    subject = output("git", "show", "-s", "--format=%s", "HEAD")
    if automatic and re.search(r"#norelease\b", subject, re.I):
        print("Skipping release for #norelease.")
        return
    info = plistlib.loads(INFO.read_bytes())
    current = info["CFBundleShortVersionString"]
    build = int(info["CFBundleVersion"])
    version(current)
    if requested and requested != "v" + current:
        raise SystemExit(f"{requested} points to an app whose version is {current}")

    stable = [release["tag_name"] for release in release_records()
              if not release["draft"] and not release["prerelease"]
              and re.fullmatch("v" + SEMVER, release["tag_name"])]
    previous = max(stable, key=lambda tag: version(tag[1:]), default=None)
    if previous:
        if output("git", "rev-parse", f"{previous}^{{commit}}") == source:
            print(f"{previous} is already published.")
            return
        run("git", "merge-base", "--is-ancestor", previous, "HEAD")
        if version(current) < version(previous[1:]) or (requested and version(current) <= version(previous[1:])):
            raise SystemExit(f"Refusing an update older than or equal to {previous}")
        previous_info = plistlib.loads(subprocess.check_output(("git", "show", f"{previous}:{INFO}")))
        previous_build = int(previous_info["CFBundleVersion"])
        if current == previous[1:]:
            commits = f"{previous}..HEAD"
            current = next_version(current, output("git", "log", "--no-merges", "--format=%s", commits),
                                   output("git", "log", "--no-merges", "--format=%b", commits))
        if requested and build <= previous_build:
            raise SystemExit("The tagged app must have a higher CFBundleVersion than the installed release")
        build = max(build, previous_build + 1)
    tag = "v" + current
    if info["CFBundleShortVersionString"] != current or info["CFBundleVersion"] != str(build):
        run("plutil", "-replace", "CFBundleShortVersionString", "-string", current, str(INFO))
        run("plutil", "-replace", "CFBundleVersion", "-string", str(build), str(INFO))
        run("git", "add", "--", str(INFO))
        run("git", "commit", "-m", f"chore(release): {tag}")
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as result:
        print(f"tag={tag}\nsource={source}", file=result)
    print(f"Building {tag} ({build}) from {output('git', 'rev-parse', 'HEAD')}")


def appcast(plist_path, archive_path, signature, destination):
    info = plistlib.loads(Path(plist_path).read_bytes())
    archive = Path(archive_path)
    short = info["CFBundleShortVersionString"]
    version(short)
    base = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/releases"
    XML.register_namespace("sparkle", SPARKLE)
    rss = XML.Element("rss", version="2.0")
    channel = XML.SubElement(rss, "channel")
    XML.SubElement(channel, "title").text = "TouchTiles updates"
    XML.SubElement(channel, "link").text = base
    XML.SubElement(channel, "description").text = "TouchTiles macOS releases"
    item = XML.SubElement(channel, "item")
    XML.SubElement(item, "title").text = f"TouchTiles {short}"
    XML.SubElement(item, "link").text = f"{base}/tag/v{short}"
    XML.SubElement(item, f"{{{SPARKLE}}}version").text = info["CFBundleVersion"]
    XML.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = short
    XML.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    XML.SubElement(item, "enclosure", {
        "url": f"{base}/download/v{short}/{archive.name}",
        "type": "application/octet-stream",
        "length": str(archive.stat().st_size),
        f"{{{SPARKLE}}}edSignature": signature,
    })
    XML.indent(rss)
    XML.ElementTree(rss).write(destination, encoding="utf-8", xml_declaration=True)


def publish(directory):
    tag = os.environ["RELEASE_TAG"]
    version(tag.removeprefix("v"))
    destination = Path(directory)
    basename = f"TouchTiles-{tag[1:]}-universal"
    files = [destination / (basename + ".dmg"), destination / (basename + ".zip"), destination / "appcast.xml"]
    if any(not path.is_file() or not path.stat().st_size for path in files):
        raise SystemExit("A release artifact is missing or empty")
    commit = output("git", "rev-parse", "HEAD")
    if not os.getenv("REQUEST_TAG"):
        run("git", "fetch", "--quiet", "origin", "main")
        published_main = output("git", "rev-parse", "origin/main")
        if published_main != os.environ["SOURCE_SHA"] and published_main != commit:
            print("Main advanced during the build. Its newer release will publish.")
            return
        if commit != published_main:
            run("git", "push", "origin", "HEAD:refs/heads/main")
    refs = output("git", "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    if refs and refs.splitlines()[-1].split()[0] != commit:
        raise SystemExit(f"Existing tag {tag} points to a different commit")
    records = release_records()
    same = [record for record in records if record["tag_name"] == tag]
    if len(same) > 1:
        raise SystemExit(f"Resolve duplicate releases for {tag} before publishing")
    if same:
        if not same[0]["draft"]:
            if not refs:
                raise SystemExit("The published release has no matching tag")
            return
        if same[0]["target_commitish"] != commit:
            raise SystemExit(f"The existing draft for {tag} targets a different commit")
    else:
        run("gh", "release", "create", tag, "--draft", "--target", commit,
            "--title", f"TouchTiles {tag[1:]}", "--generate-notes")
    run("gh", "release", "upload", tag, *(str(path) for path in files), "--clobber")
    assets = json.loads(output("gh", "release", "view", tag, "--json", "assets"))["assets"]
    uploaded = {asset["name"]: asset["size"] for asset in assets}
    if uploaded != {path.name: path.stat().st_size for path in files}:
        raise SystemExit(f"Draft asset names or byte counts for {tag} do not match")
    run("gh", "release", "edit", tag, "--draft=false", "--latest")


if __name__ == "__main__":
    commands = {"plan": plan, "publish": publish, "appcast": appcast}
    commands[sys.argv[1]](*sys.argv[2:])
