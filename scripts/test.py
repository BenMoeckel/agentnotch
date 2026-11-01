#!/usr/bin/env python3
"""Run the native regression suite on macOS with Xcode installed."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
out = root / 'build/tests'
out.mkdir(parents=True, exist_ok=True)
common = sorted((root / 'AgentNotch/Agents').glob('*.swift')) + sorted((root / 'AgentNotch/Integrations').glob('*.swift'))
tests = {
    'ActivityTests': common,
    'DiscoveryTests': common,
    'VSCodeIntegrationTests': common,
    'NativeSessionTests': common,
    'OpenCodeIntegrationTests': common,
    'RoutingTests': common,
    'SessionVisibilityTests': common,
    'LiveDiscoveryTests': common,
    'HerdrProviderTests': common,
    'TmuxIntegrationTests': common,
    'LayoutTests': [root / 'AgentNotch/Window/NotchDetector.swift'],
    'PanelRenderingTests': [root / f'AgentNotch/{path}' for path in ['Window/NotchPanel.swift', 'Window/NotchSpaceManager.swift', 'Window/CGSSpace.swift', 'Views/NotchShape.swift']],
}
for name, sources in tests.items():
    binary = out / name
    subprocess.run(['xcrun', 'swiftc', '-module-cache-path', str(root / 'build/ModuleCache.noindex'), '-o', str(binary),
                    *map(str, sources), str(root / 'tests' / f'{name}.swift')], check=True, cwd=root)
    subprocess.run([str(binary)], check=True, cwd=root)
subprocess.run(['node', '--test', str(root / 'tests/EditorBridgeTests.cjs')], check=True, cwd=root)
