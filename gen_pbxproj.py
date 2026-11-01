#!/usr/bin/env python3
"""Generates a minimal but valid Xcode 15 project for AgentNotch."""

import os
import uuid
from pathlib import Path
import itertools

BASE = str(Path(__file__).resolve().parent)
_id_sequence = itertools.count()

def uid():
    return uuid.uuid5(uuid.NAMESPACE_URL, f"agentnotch/{next(_id_sequence)}").hex[:24].upper()

# File references
FILES = [
    ("AgentNotchApp.swift",          "AgentNotch/AgentNotchApp.swift"),
    ("AppDelegate.swift",            "AgentNotch/AppDelegate.swift"),
    ("CGSSpace.swift",               "AgentNotch/Window/CGSSpace.swift"),
    ("NotchSpaceManager.swift",      "AgentNotch/Window/NotchSpaceManager.swift"),
    ("NotchDetector.swift",          "AgentNotch/Window/NotchDetector.swift"),
    ("NotchPanel.swift",             "AgentNotch/Window/NotchPanel.swift"),
    ("AgentModel.swift",             "AgentNotch/Agents/AgentModel.swift"),
    ("AgentLocation.swift",          "AgentNotch/Agents/AgentLocation.swift"),
    ("AgentClient.swift",            "AgentNotch/Agents/AgentClient.swift"),
    ("ProcessDiscovery.swift",       "AgentNotch/Agents/ProcessDiscovery.swift"),
    ("SessionNavigator.swift",       "AgentNotch/Agents/SessionNavigator.swift"),
    ("AgentEventStore.swift",        "AgentNotch/Agents/AgentEventStore.swift"),
    ("HerdrProvider.swift",          "AgentNotch/Integrations/HerdrProvider.swift"),
    ("LocalCommand.swift",           "AgentNotch/Integrations/LocalCommand.swift"),
    ("TerminalIntegration.swift",    "AgentNotch/Integrations/TerminalIntegration.swift"),
    ("TmuxIntegration.swift",        "AgentNotch/Integrations/TmuxIntegration.swift"),
    ("VSCodeIntegration.swift",      "AgentNotch/Integrations/VSCodeIntegration.swift"),
    ("EditorBridge.swift",           "AgentNotch/Integrations/EditorBridge.swift"),
    ("LocalRPC.swift",               "AgentNotch/Integrations/LocalRPC.swift"),
    ("NativeSessionIntegration.swift", "AgentNotch/Integrations/NativeSessionIntegration.swift"),
    ("NotchShape.swift",             "AgentNotch/Views/NotchShape.swift"),
    ("AgentIcon.swift",              "AgentNotch/Views/AgentIcon.swift"),
    ("Assets.xcassets",              "AgentNotch/Assets.xcassets"),
    ("AgentRowView.swift",           "AgentNotch/Views/AgentRowView.swift"),
    ("NotchBarView.swift",           "AgentNotch/Views/NotchBarView.swift"),
    ("Info.plist",                   "AgentNotch/Info.plist"),
    ("AgentNotch.entitlements",      "AgentNotch/AgentNotch.entitlements"),
]

swift_files = [n for n, _ in FILES if n.endswith(".swift")]
other_files = ["Assets.xcassets"]

# Assign stable IDs
ids = {name: uid() for name, _ in FILES}
BUILD_IDS = {name: uid() for name, _ in FILES}

TARGET_ID      = uid()
PROJECT_ID     = uid()
GROUP_ROOT     = uid()
GROUP_AGENTNOTCH = uid()
GROUP_WINDOW   = uid()
GROUP_AGENTS   = uid()
GROUP_INTEGRATIONS = uid()
GROUP_VIEWS    = uid()
SOURCES_PHASE  = uid()
RESOURCES_PHASE = uid()
CONF_LIST_PROJ = uid()
CONF_LIST_TGT  = uid()
CONF_DEBUG_PROJ = uid()
CONF_REL_PROJ   = uid()
CONF_DEBUG_TGT  = uid()
CONF_REL_TGT    = uid()
PRODUCTS_GROUP = uid()
APP_FILE_REF   = uid()

pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
"""

for name in swift_files:
    pbx += f"\t\t{BUILD_IDS[name]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ids[name]} /* {name} */; }};\n"
for name in other_files:
    pbx += f"\t\t{BUILD_IDS[name]} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {ids[name]} /* {name} */; }};\n"

pbx += "/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n"

file_map = {n: p for n, p in FILES}
for name, path in FILES:
    if name.endswith(".swift"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n"
    elif name.endswith(".plist"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = {name}; sourceTree = \"<group>\"; }};\n"
    elif name.endswith(".entitlements"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = {name}; sourceTree = \"<group>\"; }};\n"
    elif name.endswith(".xcassets"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {name}; sourceTree = \"<group>\"; }};\n"
    elif name.endswith(".ttf"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = file; path = {name}; sourceTree = \"<group>\"; }};\n"
    elif name.endswith(".svg"):
        pbx += f"\t\t{ids[name]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = file; path = {name}; sourceTree = \"<group>\"; }};\n"

pbx += f"\t\t{APP_FILE_REF} /* AgentNotch.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AgentNotch.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n"

pbx += f"""/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{GROUP_ROOT} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{GROUP_AGENTNOTCH} /* AgentNotch */,
\t\t\t\t{PRODUCTS_GROUP} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{PRODUCTS_GROUP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_FILE_REF} /* AgentNotch.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{GROUP_AGENTNOTCH} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["AgentNotchApp.swift"]} /* AgentNotchApp.swift */,
\t\t\t\t{ids["AppDelegate.swift"]} /* AppDelegate.swift */,
\t\t\t\t{ids["Info.plist"]} /* Info.plist */,
\t\t\t\t{ids["Assets.xcassets"]} /* Assets.xcassets */,
\t\t\t\t{ids["AgentNotch.entitlements"]} /* AgentNotch.entitlements */,
\t\t\t\t{GROUP_WINDOW} /* Window */,
\t\t\t\t{GROUP_AGENTS} /* Agents */,
\t\t\t\t{GROUP_INTEGRATIONS} /* Integrations */,
\t\t\t\t{GROUP_VIEWS} /* Views */,
\t\t\t);
\t\t\tpath = AgentNotch;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{GROUP_WINDOW} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["CGSSpace.swift"]} /* CGSSpace.swift */,
\t\t\t\t{ids["NotchSpaceManager.swift"]} /* NotchSpaceManager.swift */,
\t\t\t\t{ids["NotchDetector.swift"]} /* NotchDetector.swift */,
\t\t\t\t{ids["NotchPanel.swift"]} /* NotchPanel.swift */,
\t\t\t);
\t\t\tpath = Window;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{GROUP_AGENTS} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["AgentClient.swift"]} /* AgentClient.swift */,
\t\t\t\t{ids["AgentEventStore.swift"]} /* AgentEventStore.swift */,
\t\t\t\t{ids["AgentLocation.swift"]} /* AgentLocation.swift */,
\t\t\t\t{ids["AgentModel.swift"]} /* AgentModel.swift */,
\t\t\t\t{ids["ProcessDiscovery.swift"]} /* ProcessDiscovery.swift */,
\t\t\t\t{ids["SessionNavigator.swift"]} /* SessionNavigator.swift */,
\t\t\t);
\t\t\tpath = Agents;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{GROUP_INTEGRATIONS} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["HerdrProvider.swift"]} /* HerdrProvider.swift */,
\t\t\t\t{ids["LocalCommand.swift"]} /* LocalCommand.swift */,
\t\t\t\t{ids["TerminalIntegration.swift"]} /* TerminalIntegration.swift */,
\t\t\t\t{ids["TmuxIntegration.swift"]} /* TmuxIntegration.swift */,
\t\t\t\t{ids["VSCodeIntegration.swift"]} /* VSCodeIntegration.swift */,
\t\t\t\t{ids["EditorBridge.swift"]} /* EditorBridge.swift */,
\t\t\t\t{ids["LocalRPC.swift"]} /* LocalRPC.swift */,
\t\t\t\t{ids["NativeSessionIntegration.swift"]} /* NativeSessionIntegration.swift */,
\t\t\t);
\t\t\tpath = Integrations;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{GROUP_VIEWS} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{ids["NotchShape.swift"]} /* NotchShape.swift */,
\t\t\t\t{ids["AgentRowView.swift"]} /* AgentRowView.swift */,
\t\t\t\t{ids["AgentIcon.swift"]} /* AgentIcon.swift */,
\t\t\t\t{ids["NotchBarView.swift"]} /* NotchBarView.swift */,
\t\t\t);
\t\t\tpath = Views;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{TARGET_ID} /* AgentNotch */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {CONF_LIST_TGT} /* Build configuration list for PBXNativeTarget "AgentNotch" */;
\t\t\tbuildPhases = (
\t\t\t\t{SOURCES_PHASE} /* Sources */,
\t\t\t\t{RESOURCES_PHASE} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = AgentNotch;
\t\t\tproductName = AgentNotch;
\t\t\tproductReference = {APP_FILE_REF} /* AgentNotch.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{PROJECT_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t}};
\t\t\tbuildConfigurationList = {CONF_LIST_PROJ} /* Build configuration list for PBXProject "AgentNotch" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {GROUP_ROOT};
\t\t\tproductRefGroup = {PRODUCTS_GROUP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{TARGET_ID} /* AgentNotch */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{RESOURCES_PHASE} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
"""
for name in other_files:
    pbx += f"\t\t\t\t{BUILD_IDS[name]} /* {name} in Resources */,\n"

pbx += f"""\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{SOURCES_PHASE} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
"""
for name in swift_files:
    pbx += f"\t\t\t\t{BUILD_IDS[name]} /* {name} in Sources */,\n"

pbx += f"""\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{CONF_DEBUG_PROJ} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{CONF_REL_PROJ} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCOPY_PHASE_STRIP = YES;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{CONF_DEBUG_TGT} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tAPP_PRIVACY_BUILT_IN_USAGE_BUNDLE_IDENTIFIER = "com.benmoeckel.agentnotch";
\t\t\t\tCODE_SIGN_ENTITLEMENTS = AgentNotch/AgentNotch.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tINFOPLIST_FILE = AgentNotch/Info.plist;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.benmoeckel.agentnotch";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{CONF_REL_TGT} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tAPP_PRIVACY_BUILT_IN_USAGE_BUNDLE_IDENTIFIER = "com.benmoeckel.agentnotch";
\t\t\t\tCODE_SIGN_ENTITLEMENTS = AgentNotch/AgentNotch.entitlements;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tINFOPLIST_FILE = AgentNotch/Info.plist;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tMARKETING_VERSION = 1.0.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "com.benmoeckel.agentnotch";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tSDKROOT = macosx;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{CONF_LIST_PROJ} /* Build configuration list for PBXProject "AgentNotch" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CONF_DEBUG_PROJ} /* Debug */,
\t\t\t\t{CONF_REL_PROJ} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CONF_LIST_TGT} /* Build configuration list for PBXNativeTarget "AgentNotch" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CONF_DEBUG_TGT} /* Debug */,
\t\t\t\t{CONF_REL_TGT} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {PROJECT_ID} /* Project object */;
}}
"""

out = os.path.join(BASE, "AgentNotch.xcodeproj", "project.pbxproj")
with open(out, "w") as f:
    f.write(pbx)
print(f"Written: {out}")
