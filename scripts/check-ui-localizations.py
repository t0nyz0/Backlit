#!/usr/bin/env python3
"""Guard static prose from scoped GUI-facing status/error producers.

This is not a Swift parser or a claim of universal localization. Interpolated
messages have behavioral/template tests; opaque OS and third-party diagnostics
are never rewritten. Exact protocol/log/key-name exclusions are documented.
"""
from pathlib import Path
import json,re
ROOT=Path(__file__).resolve().parents[1]
SOURCES=["AppModel","FramePausePolicy","TypingInput","HomeBridge","GlobalShortcuts",
 "ShiftBrightnessKeys","AppUpdater","AgentSessionStatus","AutomaticRecoveryStore",
 "ClosedLidLogo","LidSessionIntent","LogoDevice","AmbientAuthorizationFailure",
 "BridgeConnectionSetup","AgentBridge","RuntimeServices","SystemAudio"]
TOKENS=re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"')
def readable_literals(source):
    for match in TOKENS.finditer(source):
        token=match.group()
        if not token.startswith('"'):continue
        text=token[1:-1]
        if "\\(" in text or "\n" in text:continue
        if re.match(r'(?:[A-Z][a-zA-Z]*|macOS) ',text) and len(text.split())>=2:
            yield text

def missing_from(source,name,catalog,exemptions):
    return sorted({text for text in readable_literals(source)
        if text not in catalog and name not in exemptions.get(text,{}).get("files",[])})

def check():
    catalog=json.loads((ROOT/'assets/Localizations/Localizable.xcstrings').read_text())["strings"]
    exclusions=json.loads((ROOT/'Tests/Fixtures/ui-localization-exemptions.json').read_text())
    failures=[]
    for key,entry in exclusions.items():
        if not entry.get('reason') or not entry.get('files'):failures.append('Undocumented exclusion: '+key)
    for name in SOURCES:
        path=ROOT/f'Sources/Backlit/{name}.swift'
        for key in missing_from(path.read_text(),name,catalog,exclusions):failures.append(f'{name}: {key}')
    if failures:raise ValueError('Missing readable UI translations:\n'+'\n'.join(failures))
    return len(SOURCES)
if __name__=='__main__':print(f'Checked static UI prose in {check()} status/error producers; opaque/protocol exclusions are explicit.')
