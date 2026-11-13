"""Run on macOS: python3 tests/copy_source_media_to_clipboard_macos_test.py.
Uses an isolated named pasteboard, never the user's general clipboard.
"""
import json
from pathlib import Path
import subprocess
import tempfile
import uuid
import unicodedata

SCRIPT = Path(__file__).resolve().parents[1] / 'Tools/JG_Copy_Source_Media_To_Clipboard.lua'

with tempfile.TemporaryDirectory(prefix='jg-clipboard-test-') as directory:
    root = Path(directory)
    paths = []
    for i in range(13):
        source = root / str(i) / f"Source {i % 5} Ä ' $.wav"
        source.parent.mkdir()
        source.write_bytes(b'test')
        paths.append(str(source))
    # A repeated source must be removed, while equal basenames in different folders survive.
    items = ','.join(json.dumps(p, ensure_ascii=False) for p in paths + paths[:1])
    helper = root / 'helper.js'
    driver = root / 'driver.lua'
    driver.write_text('''
local paths = {''' + items + '''}
reaper = {
  defer = function() end, atexit = function() end,
  GetOS = function() return 'OSX64' end,
  CountSelectedMediaItems = function() return #paths end,
  GetSelectedMediaItem = function(_, i) return i + 1 end,
  CountTakes = function() return 1 end,
  GetTake = function(item) return item end,
  GetMediaItemTake_Source = function(take) return take end,
  GetMediaSourceParent = function() return nil end,
  GetMediaSourceFileName = function(source) return paths[source] end,
  ShowMessageBox = function(text) error(text) end,
  ExecProcess = function(_, timeout) assert(timeout == -2); return '' end,
  time_precise = function() return 0 end,
}
os.tmpname = function() return ''' + json.dumps(str(helper)) + ''' end
dofile(''' + json.dumps(str(SCRIPT)) + ''')
''')
    subprocess.run(['lua', str(driver)], check=True)
    original = helper.read_text()
    board_name = 'jg-clipboard-test-' + str(uuid.uuid4())
    isolated = original.replace('$.NSPasteboard.generalPasteboard',
                                '$.NSPasteboard.pasteboardWithName(' + json.dumps(board_name) + ')')
    assert isolated != original
    result_file = Path(str(helper) + '.result')

    def run(code):
        helper.write_text(code)
        result_file.unlink(missing_ok=True)
        subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', str(helper)],
                       check=True, capture_output=True, text=True, timeout=15)
        return unicodedata.normalize('NFC', result_file.read_text())

    try:
        result = run(isolated)
        assert result == 'JG_COPY_OK', result
        print('13 unique source paths: OK')
        anchor = "if (!board.writeObjects(urls)) throw new Error('Could not write files to the clipboard.');"
        assert anchor in isolated
        # Reproduce successful write followed by an incomplete clipboard before verification.
        partial = isolated.replace(anchor, anchor + '''
board.clearContents;
board.writeObjects(urls.subarrayWithRange($.NSMakeRange(0, 11)));
''')
        result = run(partial)
        assert result.startswith('JG_COPY_ERROR:') and '13' in result and '11' in result, result
        assert paths[11] in result and paths[12] in result, result
        print('13 collected / 11 in clipboard is reported as failure: OK')
        delayed = isolated.replace('$.NSThread.sleepForTimeInterval(0.25);', '''
board.clearContents;
board.writeObjects(urls.subarrayWithRange($.NSMakeRange(0, 11)));
''')
        assert delayed != isolated
        result = run(delayed)
        assert result.startswith('JG_COPY_ERROR:') and paths[12] in result, result
        print('Clipboard replacement after the first verification is detected: OK')
        # Same count with a duplicate replacing a missing path must also fail.
        replaced = isolated.replace(anchor, anchor + '''
var wrong = urls.mutableCopy;
wrong.replaceObjectAtIndexWithObject(12, urls.objectAtIndex(0));
board.clearContents;
board.writeObjects(wrong);
''')
        result = run(replaced)
        assert result.startswith('JG_COPY_ERROR:'), result
        print('Equal count with a missing source is reported as failure: OK')
    finally:
        subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e',
                        "ObjC.import('AppKit'); $.NSPasteboard.pasteboardWithName("
                        + json.dumps(board_name) + ').releaseGlobally;'],
                       capture_output=True, timeout=15)
