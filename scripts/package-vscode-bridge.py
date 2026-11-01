#!/usr/bin/env python3
"""Package the local, dependency-free VS Code bridge without a registry build."""
from pathlib import Path
import json
import zipfile

root = Path(__file__).resolve().parent.parent
source = root / 'integrations/vscode'
package = json.loads((source / 'package.json').read_text())
output = root / 'build' / f"agentnotch-bridge-{package['version']}.vsix"
output.parent.mkdir(parents=True, exist_ok=True)
manifest = f'''<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="bridge" Version="{package['version']}" Publisher="agentnotch"/>
    <DisplayName>AgentNotch Session Bridge</DisplayName>
    <Description xml:space="preserve">Local terminal and conversation navigation for AgentNotch.</Description>
    <Categories>Other</Categories>
    <Properties><Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.95.0"/></Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code"/></Installation>
  <Dependencies/>
  <Assets><Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true"/></Assets>
</PackageManifest>'''
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    archive.writestr('extension.vsixmanifest', manifest)
    archive.writestr('[Content_Types].xml', '''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="json" ContentType="application/json"/><Default Extension="js" ContentType="application/javascript"/><Default Extension="vsixmanifest" ContentType="text/xml"/></Types>''')
    for name in ['package.json', 'extension.js']:
        archive.write(source / name, 'extension/' + name)
print(output)
