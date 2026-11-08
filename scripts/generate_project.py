#!/usr/bin/env python3
"""Regenerates DragWheel.xcodeproj from the files on disk (no xcodegen needed).

Run after adding/removing Swift files:  python3 scripts/generate_project.py
"""
import hashlib, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP, TESTS = "DragWheel", "DragWheelTests"
BUNDLE_ID = "local.dragwheel.DragWheel"


def uid(*parts):
    return hashlib.md5("/".join(parts).encode()).hexdigest()[:24].upper()


RESOURCE_TYPES = {".icns": "image.icns"}


def swift_files(folder, exts=(".swift",)):
    out = []
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, folder)):
        dirnames.sort()
        for f in sorted(filenames):
            if f.endswith(exts):
                out.append(os.path.relpath(os.path.join(dirpath, f), ROOT))
    return out


objects = {}  # id -> (comment, body)


def add(oid, comment, body):
    objects[oid] = (comment, body)


def build_group(folder, sources):
    """Create PBXGroup hierarchy for `folder`; returns group id."""
    def make(path_parts):
        key = "/".join(path_parts)
        gid = uid("group", key)
        children = []
        subdirs = sorted({s.split("/")[len(path_parts)] for s in sources
                          if s.startswith(key + "/") and s.count("/") > len(path_parts)})
        for sd in subdirs:
            children.append(make(path_parts + [sd]))
        for s in sources:
            if os.path.dirname(s) == key:
                fid = uid("fileref", s)
                ext = os.path.splitext(s)[1]
                ftype = RESOURCE_TYPES.get(ext, "sourcecode.swift")
                add(fid, os.path.basename(s),
                    f'isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{os.path.basename(s)}"; sourceTree = "<group>";')
                children.append(fid)
        if len(path_parts) == 1:
            for extra in ("Info.plist",):
                if os.path.exists(os.path.join(ROOT, key, extra)):
                    fid = uid("fileref", key + "/" + extra)
                    add(fid, extra, f'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = "{extra}"; sourceTree = "<group>";')
                    children.append(fid)
        kids = ",\n".join(f"\t\t\t\t{c}" for c in children)
        add(gid, path_parts[-1], f'isa = PBXGroup;\n\t\t\tchildren = (\n{kids}\n\t\t\t);\n\t\t\tpath = "{path_parts[-1]}";\n\t\t\tsourceTree = "<group>";')
        return gid
    return make([folder])


app_sources = swift_files(APP)
app_resources = swift_files(APP, tuple(RESOURCE_TYPES))
test_sources = swift_files(TESTS)
app_group = build_group(APP, sorted(app_sources + app_resources))
test_group = build_group(TESTS, test_sources)

app_product = uid("product", APP)
test_product = uid("product", TESTS)
add(app_product, f"{APP}.app", f'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "{APP}.app"; sourceTree = BUILT_PRODUCTS_DIR;')
add(test_product, f"{TESTS}.xctest", f'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = "{TESTS}.xctest"; sourceTree = BUILT_PRODUCTS_DIR;')

products = uid("group", "Products")
add(products, "Products", f'isa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_product},\n\t\t\t\t{test_product}\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";')
main_group = uid("group", "main")
add(main_group, "", f'isa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{app_group},\n\t\t\t\t{test_group},\n\t\t\t\t{products}\n\t\t\t);\n\t\t\tsourceTree = "<group>";')


def sources_phase(name, sources):
    pid = uid("sources", name)
    files = []
    for s in sources:
        bid = uid("buildfile", name, s)
        add(bid, f"{os.path.basename(s)} in Sources", f'isa = PBXBuildFile; fileRef = {uid("fileref", s)};')
        files.append(f"\t\t\t\t{bid}")
    add(pid, "Sources", "isa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + ",\n".join(files) + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    return pid


def resources_phase(name, resources):
    pid = uid("resources", name)
    files = []
    for s in resources:
        bid = uid("buildfile", name, s)
        add(bid, f"{os.path.basename(s)} in Resources", f'isa = PBXBuildFile; fileRef = {uid("fileref", s)};')
        files.append(f"\t\t\t\t{bid}")
    add(pid, "Resources", "isa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n" + ",\n".join(files) + "\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    return pid


def frameworks_phase(name):
    pid = uid("frameworks", name)
    add(pid, "Frameworks", "isa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    return pid


def config(name, settings):
    cid = uid("config", name)
    lines = "\n".join(f"\t\t\t\t{k} = {v};" for k, v in sorted(settings.items()))
    add(cid, name.split(":")[-1], f"isa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{lines}\n\t\t\t}};\n\t\t\tname = {name.split(':')[-1]};")
    return cid


def config_list(name, cfgs, comment):
    lid = uid("configlist", name)
    items = ",\n".join(f"\t\t\t\t{c}" for c in cfgs)
    add(lid, comment, f"isa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n{items}\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;")
    return lid


common = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ANALYZER_NONNULL": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CLANG_WARN_BOOL_CONVERSION": "YES",
    "CLANG_WARN_CONSTANT_CONVERSION": "YES",
    "CLANG_WARN_DEPRECATED_OBJC_IMPLEMENTATIONS": "YES",
    "CLANG_WARN_EMPTY_BODY": "YES",
    "CLANG_WARN_ENUM_CONVERSION": "YES",
    "CLANG_WARN_INT_CONVERSION": "YES",
    "CLANG_WARN_UNREACHABLE_CODE": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "5.0",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
}
proj_debug = config("project:Debug", {**common, "COPY_PHASE_STRIP": "NO", "DEBUG_INFORMATION_FORMAT": "dwarf", "ENABLE_TESTABILITY": "YES",
                                      "GCC_OPTIMIZATION_LEVEL": "0", "ONLY_ACTIVE_ARCH": "YES", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
                                      "SWIFT_OPTIMIZATION_LEVEL": '"-Onone"'})
proj_release = config("project:Release", {**common, "COPY_PHASE_STRIP": "NO", "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
                                          "SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": '"-O"'})
proj_list = config_list("project", [proj_debug, proj_release], 'Build configuration list for PBXProject "DragWheel"')

sign = {"CODE_SIGN_STYLE": "Manual", "CODE_SIGN_IDENTITY": '"-"', "ENABLE_HARDENED_RUNTIME": "NO"}
app_settings = {**sign, "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID, "PRODUCT_NAME": '"$(TARGET_NAME)"', "INFOPLIST_FILE": "DragWheel/Info.plist",
                "COMBINE_HIDPI_IMAGES": "YES", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0", "ENABLE_APP_SANDBOX": "NO",
                "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks"'}
app_debug = config("app:Debug", app_settings)
app_release = config("app:Release", app_settings)
app_list = config_list("app", [app_debug, app_release], 'Build configuration list for PBXNativeTarget "DragWheel"')

test_settings = {**sign, "PRODUCT_BUNDLE_IDENTIFIER": BUNDLE_ID + "Tests", "PRODUCT_NAME": '"$(TARGET_NAME)"', "GENERATE_INFOPLIST_FILE": "YES",
                 "TEST_HOST": '"$(BUILT_PRODUCTS_DIR)/DragWheel.app/Contents/MacOS/DragWheel"', "BUNDLE_LOADER": '"$(TEST_HOST)"',
                 "LD_RUNPATH_SEARCH_PATHS": '"$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks"'}
test_debug = config("test:Debug", test_settings)
test_release = config("test:Release", test_settings)
test_list = config_list("test", [test_debug, test_release], 'Build configuration list for PBXNativeTarget "DragWheelTests"')

app_target = uid("target", APP)
test_target = uid("target", TESTS)
proxy = uid("proxy")
dep = uid("dependency")
add(proxy, "PBXContainerItemProxy", f"isa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = {uid('project')};\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = {app_target};\n\t\t\tremoteInfo = {APP};")
add(dep, "PBXTargetDependency", f"isa = PBXTargetDependency;\n\t\t\ttarget = {app_target};\n\t\t\ttargetProxy = {proxy};")

add(app_target, APP, f"isa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {app_list};\n\t\t\tbuildPhases = (\n\t\t\t\t{sources_phase(APP, app_sources)},\n\t\t\t\t{frameworks_phase(APP)},\n\t\t\t\t{resources_phase(APP, app_resources)}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t);\n\t\t\tname = {APP};\n\t\t\tproductName = {APP};\n\t\t\tproductReference = {app_product};\n\t\t\tproductType = \"com.apple.product-type.application\";")
add(test_target, TESTS, f"isa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = {test_list};\n\t\t\tbuildPhases = (\n\t\t\t\t{sources_phase(TESTS, test_sources)},\n\t\t\t\t{frameworks_phase(TESTS)}\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n\t\t\t\t{dep}\n\t\t\t);\n\t\t\tname = {TESTS};\n\t\t\tproductName = {TESTS};\n\t\t\tproductReference = {test_product};\n\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")

project = uid("project")
add(project, "Project object", f"isa = PBXProject;\n\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastSwiftUpdateCheck = 2600;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t}};\n\t\t\tbuildConfigurationList = {proj_list};\n\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase\n\t\t\t);\n\t\t\tmainGroup = {main_group};\n\t\t\tproductRefGroup = {products};\n\t\t\tprojectDirPath = \"\";\n\t\t\tprojectRoot = \"\";\n\t\t\ttargets = (\n\t\t\t\t{app_target},\n\t\t\t\t{test_target}\n\t\t\t);")

order = ["PBXBuildFile", "PBXContainerItemProxy", "PBXFileReference", "PBXGroup", "PBXNativeTarget", "PBXProject", "PBXResourcesBuildPhase", "PBXSourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXTargetDependency", "XCBuildConfiguration", "XCConfigurationList"]
by_isa = {k: [] for k in order}
for oid, (comment, body) in sorted(objects.items()):
    isa = body.split("isa = ")[1].split(";")[0]
    by_isa[isa].append((oid, comment, body))

out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};", "\tobjectVersion = 56;", "\tobjects = {", ""]
for isa in order:
    if not by_isa[isa]:
        continue
    out.append(f"/* Begin {isa} section */")
    for oid, comment, body in by_isa[isa]:
        c = f" /* {comment} */" if comment else ""
        if isa in ("PBXBuildFile", "PBXFileReference"):
            out.append(f"\t\t{oid}{c} = {{{body}}};")
        else:
            out.append(f"\t\t{oid}{c} = {{\n\t\t\t{body}\n\t\t}};")
    out.append(f"/* End {isa} section */\n")
out += ["\t};", f"\trootObject = {project} /* Project object */;", "}", ""]

proj_dir = os.path.join(ROOT, "DragWheel.xcodeproj")
os.makedirs(os.path.join(proj_dir, "xcshareddata/xcschemes"), exist_ok=True)
with open(os.path.join(proj_dir, "project.pbxproj"), "w") as f:
    f.write("\n".join(out))

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{test_target}" BuildableName = "{TESTS}.xctest" BlueprintName = "{TESTS}" ReferencedContainer = "container:{APP}.xcodeproj"/>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{app_target}" BuildableName = "{APP}.app" BlueprintName = "{APP}" ReferencedContainer = "container:{APP}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"/>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
'''
with open(os.path.join(proj_dir, "xcshareddata/xcschemes/DragWheel.xcscheme"), "w") as f:
    f.write(scheme)
print(f"Generated project with {len(app_sources)} app files, {len(app_resources)} resources and {len(test_sources)} test files")
