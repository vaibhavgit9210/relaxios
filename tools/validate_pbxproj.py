#!/usr/bin/env python3
"""Sanity-checks the hand-written Xcode project without needing Xcode.

Usage: python3 tools/validate_pbxproj.py
Converts project.pbxproj to JSON with plutil, then checks the object graph,
file paths, build phases, build settings, scheme and Info.plist. Exits 1 on
any failure.
"""
import glob
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJ = os.path.join(ROOT, "Relaxios.xcodeproj")
PBX = os.path.join(PROJ, "project.pbxproj")
SCHEME = os.path.join(PROJ, "xcshareddata", "xcschemes", "Relaxios.xcscheme")
INFO = os.path.join(ROOT, "Relaxios", "Info.plist")

failures = []
checks = 0


def check(ok, message):
    global checks
    checks += 1
    if not ok:
        failures.append(message)


def load_pbxproj():
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "project.json")
        subprocess.run(["plutil", "-convert", "json", "-o", out, PBX], check=True)
        with open(out) as f:
            return json.load(f)


def referenced_ids(value, objects):
    """Yields every string in `value` that looks like an object id."""
    if isinstance(value, str):
        if re.fullmatch(r"[0-9A-F]{24}", value):
            yield value
    elif isinstance(value, list):
        for v in value:
            yield from referenced_ids(v, objects)
    elif isinstance(value, dict):
        for k, v in value.items():
            if re.fullmatch(r"[0-9A-F]{24}", k):  # TargetAttributes keys
                yield k
            yield from referenced_ids(v, objects)


def main():
    project = load_pbxproj()
    objects = project["objects"]
    check(project.get("objectVersion") == "56", "objectVersion should be 56")
    check(project["rootObject"] in objects, "rootObject missing")

    # 1. Every referenced id exists.
    for oid, obj in objects.items():
        for ref in referenced_ids(obj, objects):
            check(ref in objects, f"{oid} ({obj.get('isa')}) references missing object {ref}")

    def of_isa(isa):
        return {k: v for k, v in objects.items() if v.get("isa") == isa}

    # 2. Every file reference resolves on disk, relative to its group chain.
    parent = {}
    for gid, group in of_isa("PBXGroup").items():
        for child in group.get("children", []):
            check(child not in parent, f"{child} has two parent groups")
            parent[child] = gid

    def disk_path(oid):
        obj = objects[oid]
        tree = obj.get("sourceTree")
        path = obj.get("path", "")
        if tree == "<group>":
            base = disk_path(parent[oid]) if oid in parent else ROOT
            return os.path.join(base, path)
        if tree == "SOURCE_ROOT":
            return os.path.join(ROOT, path)
        return None  # BUILT_PRODUCTS_DIR, SDKROOT and friends are not on disk here

    file_refs = of_isa("PBXFileReference")
    for fid, ref in file_refs.items():
        check(fid in parent, f"file reference {ref.get('path')} is not in any group")
        path = disk_path(fid) if fid in parent else None
        if ref.get("sourceTree") == "BUILT_PRODUCTS_DIR":
            continue
        check(path is not None and os.path.exists(path), f"missing on disk: {ref.get('path')} -> {path}")

    # 3. Exactly one app target with the three standard phases.
    targets = of_isa("PBXNativeTarget")
    check(len(targets) == 1, f"expected 1 target, found {len(targets)}")
    target_id, target = next(iter(targets.items()))
    check(target.get("name") == "Relaxios", "target should be named Relaxios")
    check(target.get("productType") == "com.apple.product-type.application", "target is not an app")
    product = objects.get(target.get("productReference"), {})
    check(product.get("path") == "Relaxios.app", "product should be Relaxios.app")
    root = objects[project["rootObject"]]
    check(root.get("targets") == [target_id], "project targets list is wrong")

    phases = {objects[p]["isa"]: objects[p] for p in target["buildPhases"]}
    in_phase = {bf for phase in phases.values() for bf in phase.get("files", [])}
    for bid in of_isa("PBXBuildFile"):
        check(bid in in_phase, f"build file {bid} is not in any build phase")

    def phase_files(isa):
        out = {}
        for bf in phases.get(isa, {}).get("files", []):
            ref = objects[objects[bf]["fileRef"]]
            out[ref.get("path")] = ref
        return out

    sources = phase_files("PBXSourcesBuildPhase")
    resources = phase_files("PBXResourcesBuildPhase")
    on_disk = sorted(os.path.basename(p) for p in glob.glob(os.path.join(ROOT, "Relaxios", "*.swift")))
    check(on_disk, "no Swift sources found")
    for name in on_disk:
        check(name in sources, f"{name} is not in the Sources phase")
    for name in sources:
        check(name in on_disk, f"Sources phase lists {name}, which is not in Relaxios/")
    check("Assets.xcassets" in resources, "Assets.xcassets is not in the Resources phase")
    videos = resources.get("Videos")
    check(videos is not None, "Videos folder is not in the Resources phase")
    if videos:
        check(videos.get("lastKnownFileType") == "folder", "Videos must be a folder reference")
    # The folder reference ships everything in Videos/ (Xcode only strips
    # .DS_Store and VCS dirs), so it must hold exactly the 16 contract files:
    # a stray file, say a leftover .<id>_<variant>.tmp.mp4 from an interrupted
    # render_all.sh, would bloat the app.
    contract = {
        f"{scene}_{orient}_{res}.mp4"
        for scene in ("window", "plains", "sea", "above")
        for orient in ("portrait", "landscape")
        for res in (1080, 720)
    }
    videos_dir = os.path.join(ROOT, "Relaxios", "Videos")
    shipped = set(os.listdir(videos_dir)) - {".DS_Store"} if os.path.isdir(videos_dir) else set()
    for name in sorted(contract - shipped):
        check(False, f"Videos/{name} is missing")
    for name in sorted(shipped - contract):
        check(False, f"Videos/{name} is not a contract file and would ship in the app")
    for name in sorted(contract & shipped):
        check(os.path.getsize(os.path.join(videos_dir, name)) > 0, f"Videos/{name} is empty")
    check("Info.plist" not in resources, "Info.plist must not be copied as a resource")

    # 4. Build settings.
    def configs(list_id):
        return {objects[c]["name"]: objects[c]["buildSettings"] for c in objects[list_id]["buildConfigurations"]}

    project_cfgs = configs(root["buildConfigurationList"])
    target_cfgs = configs(target["buildConfigurationList"])
    for cfgs, label in ((project_cfgs, "project"), (target_cfgs, "target")):
        check(set(cfgs) == {"Debug", "Release"}, f"{label} configs should be Debug and Release, got {sorted(cfgs)}")

    expected = {
        "PRODUCT_BUNDLE_IDENTIFIER": "dev.vaibhavkumar.relaxios",
        "TARGETED_DEVICE_FAMILY": "1",
        "IPHONEOS_DEPLOYMENT_TARGET": "16.0",
        "GENERATE_INFOPLIST_FILE": "NO",
        "INFOPLIST_FILE": "Relaxios/Info.plist",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "",
        "SWIFT_VERSION": "5.0",
    }
    for name, settings in target_cfgs.items():
        merged = {**project_cfgs.get(name, {}), **settings}
        for key, value in expected.items():
            check(merged.get(key) == value, f"{name}: {key} = {merged.get(key)!r}, expected {value!r}")
        check(merged.get("SDKROOT") == "iphoneos", f"{name}: SDKROOT should be iphoneos")
        check(os.path.exists(os.path.join(ROOT, merged.get("INFOPLIST_FILE", ""))), f"{name}: INFOPLIST_FILE missing")

    # 5. Shared scheme points at the target.
    with open(SCHEME) as f:
        scheme = f.read()
    blueprints = set(re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"', scheme))
    check(blueprints == {target_id}, f"scheme BlueprintIdentifier {blueprints} != target {target_id}")
    check('BuildableName = "Relaxios.app"' in scheme, "scheme BuildableName should be Relaxios.app")
    check('container:Relaxios.xcodeproj' in scheme, "scheme container is wrong")

    # 6. Info.plist essentials the app depends on.
    with open(INFO, "rb") as f:
        info = plistlib.load(f)
    manifest = info.get("UIApplicationSceneManifest", {})
    roles = manifest.get("UISceneConfigurations", {}).get("UIWindowSceneSessionRoleApplication", [{}])
    check(roles[0].get("UISceneDelegateClassName") == "$(PRODUCT_MODULE_NAME).SceneDelegate", "scene delegate class not set")
    check(info.get("UILaunchScreen", {}).get("UIColorName") == "LaunchBackground", "launch screen colour not set")
    check(os.path.isdir(os.path.join(ROOT, "Relaxios", "Assets.xcassets", "LaunchBackground.colorset")), "LaunchBackground colour set missing")
    check(info.get("UIStatusBarHidden") is True, "UIStatusBarHidden should be YES")
    check(info.get("UIRequiresFullScreen") is True, "UIRequiresFullScreen should be YES")
    check(info.get("UIUserInterfaceStyle") == "Dark", "UIUserInterfaceStyle should be Dark")
    check(info.get("CFBundleDisplayName") == "Relaxios", "display name should be Relaxios")
    check(set(info.get("UISupportedInterfaceOrientations", [])) == {
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight",
    }, "orientations should be portrait + both landscapes")

    icon = os.path.join(ROOT, "Relaxios", "Assets.xcassets", "AppIcon.appiconset")
    with open(os.path.join(icon, "Contents.json")) as f:
        images = json.load(f)["images"]
    for image in images:
        check(os.path.exists(os.path.join(icon, image.get("filename", ""))), f"icon file missing: {image}")

    if failures:
        print(f"FAIL: {len(failures)} of {checks} checks failed")
        for message in failures:
            print("  - " + message)
        sys.exit(1)
    print(f"OK: {checks} checks passed ({len(objects)} objects, {len(sources)} sources, target {target_id})")


if __name__ == "__main__":
    main()
